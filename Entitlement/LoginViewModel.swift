//
//  LoginViewModel.swift
//  Entitlement
//
//  Created by s s on 2025/3/15.
//

import SwiftUI
import StosSign

@MainActor
final class LoginViewModel: ObservableObject {
    static let shared = LoginViewModel()

    @Published var appleID = ""
    @Published var password = ""
    @Published var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var isLoginInProgress = false
    @Published var isSessionRefreshInProgress = false
    @Published var logs = ""

    private var verificationCodeHandler: ((String?) -> Void)?
    private var refreshTimer: Timer?
    private var hasBootstrappedFromKeychain = false

    private struct PersistedAuthState: Codable {
        let appleID: String
        let teamIdentifier: String?
        let anisetteServerURL: String
        let lastSuccessfulAuthAt: TimeInterval
    }

    private init() {
        restoreCredentialsIntoFields()
        startSessionMonitor()

        Task {
            await bootstrapFromKeychainIfPossible()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func restoreCredentialsIntoFields() {
        appleID = Keychain.shared.appleIDEmailAddress ?? ""
        password = Keychain.shared.appleIDPassword ?? ""
    }

    func submitVerficationCode() {
        verificationCodeHandler?(verificationCode)
    }

    func authenticate() async throws -> Bool {
        let trimmedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPassword = password

        guard !trimmedAppleID.isEmpty else {
            throw "Apple ID is required."
        }

        guard !currentPassword.isEmpty else {
            throw "Password is required."
        }

        return try await performAuthentication(
            appleID: trimmedAppleID,
            password: currentPassword,
            allowsInteractiveVerification: true,
            persistCredentials: true,
            logPrefix: "Interactive sign in"
        )
    }

    func ensureAuthenticated(interactive: Bool = false) async throws -> Bool {
        if DataManager.shared.model.isLogin,
           DataManager.shared.model.account != nil,
           DataManager.shared.model.session != nil,
           DataManager.shared.model.team != nil {
            return true
        }

        if interactive {
            return try await authenticate()
        }

        return try await reauthenticateWithStoredCredentials(
            allowsInteractiveVerification: false,
            logPrefix: "Ensure authenticated"
        )
    }

    func bootstrapFromKeychainIfPossible() async {
        guard !hasBootstrappedFromKeychain else { return }
        hasBootstrappedFromKeychain = true

        restoreCredentialsIntoFields()

        guard Keychain.shared.appleIDEmailAddress != nil,
              Keychain.shared.appleIDPassword != nil else {
            return
        }

        do {
            _ = try await reauthenticateWithStoredCredentials(
                allowsInteractiveVerification: false,
                logPrefix: "Launch restore"
            )
        } catch {
            appendLog("Launch restore failed: \(error.localizedDescription)")
        }
    }

    func handleAnisetteServerURLChange() async {
        DataManager.shared.model.applyAnisetteServerURL()
        clearLiveSessionOnly()
        appendLog("Anisette server changed. Live session cleared.")
        do {
            _ = try await reauthenticateWithStoredCredentials(
                allowsInteractiveVerification: false,
                logPrefix: "Anisette URL change"
            )
        } catch {
            appendLog("Reauth after anisette URL change failed: \(error.localizedDescription)")
        }
    }

    func refreshSessionIfNeeded(reason: String = "1 minute monitor") async {
        guard !isLoginInProgress, !isSessionRefreshInProgress else {
            return
        }

        guard Keychain.shared.appleIDEmailAddress != nil,
              Keychain.shared.appleIDPassword != nil else {
            return
        }

        isSessionRefreshInProgress = true
        defer { isSessionRefreshInProgress = false }

        appendLog("Session check: \(reason)")

        if let account = DataManager.shared.model.account,
           let session = DataManager.shared.model.session {
            do {
                let team = try await fetchTeam(for: account, session: session)
                DataManager.shared.model.update(account: account, session: session, team: team)
                persistAuthState(email: account.appleID, teamIdentifier: team.identifier)
                appendLog("Session still valid.")
                return
            } catch {
                appendLog("Session validation failed: \(error.localizedDescription)")
            }
        }

        do {
            _ = try await reauthenticateWithStoredCredentials(
                allowsInteractiveVerification: false,
                logPrefix: reason
            )
        } catch {
            appendLog("Silent reauth failed: \(error.localizedDescription)")
            clearLiveSessionOnly()
        }
    }

    func clearAllAuthData() {
        verificationCodeHandler = nil
        needVerificationCode = false
        verificationCode = ""
        logs = ""

        clearLiveSessionOnly()

        Keychain.shared.appleIDEmailAddress = nil
        Keychain.shared.appleIDPassword = nil
        Keychain.shared.authStateData = nil
        Keychain.shared.identifier = nil
        Keychain.shared.adiPb = nil

        appleID = ""
        password = ""
    }

    private func startSessionMonitor() {
        refreshTimer?.invalidate()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshSessionIfNeeded()
            }
        }
    }

    private func performAuthentication(
        appleID: String,
        password: String,
        allowsInteractiveVerification: Bool,
        persistCredentials: Bool,
        logPrefix: String
    ) async throws -> Bool {
        if isLoginInProgress {
            return false
        }

        DataManager.shared.model.applyAnisetteServerURL()

        logs = ""
        isLoginInProgress = true
        needVerificationCode = false
        verificationCode = ""
        verificationCodeHandler = nil

        defer {
            isLoginInProgress = false
        }

        appendLog("\(logPrefix): fetching anisette data...")

        AnisetteDataHelper.shared.loggingFunc = { [weak self] text in
            Task { @MainActor in
                self?.appendLog(text)
            }
        }

        let anisetteData = try await AnisetteDataHelper.shared.getAnisetteData()

        let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Account, AppleAPISession), Error>) in
            AppleAPI().authenticate(
                appleID: appleID,
                password: password,
                anisetteData: anisetteData
            ) { [weak self] completionHandler in
                guard let self else {
                    completionHandler(nil)
                    return
                }

                Task { @MainActor in
                    if allowsInteractiveVerification {
                        self.verificationCodeHandler = completionHandler
                        self.needVerificationCode = true
                        self.appendLog("Verification code required.")
                    } else {
                        self.appendLog("Silent reauth requires a verification code. Aborting silent reauth.")
                        completionHandler(nil)
                    }
                }
            } completionHandler: { account, session, error in
                if let error {
                    c.resume(throwing: error)
                    return
                }

                guard let account, let session else {
                    c.resume(throwing: "Account or session is nil. Please try again or reopen the app.")
                    return
                }

                c.resume(returning: (account, session))
            }
        }

        let account = result.0
        let session = result.1

        appendLog("\(logPrefix): signed in successfully.")

        let team = try await fetchTeam(for: account, session: session)
        appendLog("\(logPrefix): team fetched successfully.")

        DataManager.shared.model.update(account: account, session: session, team: team)

        if persistCredentials {
            Keychain.shared.appleIDEmailAddress = appleID
            Keychain.shared.appleIDPassword = password
        }

        self.appleID = appleID
        self.password = password

        persistAuthState(email: account.appleID, teamIdentifier: team.identifier)

        needVerificationCode = false
        verificationCode = ""
        verificationCodeHandler = nil

        return true
    }

    private func reauthenticateWithStoredCredentials(
        allowsInteractiveVerification: Bool,
        logPrefix: String
    ) async throws -> Bool {
        let savedAppleID = Keychain.shared.appleIDEmailAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let savedPassword = Keychain.shared.appleIDPassword ?? ""

        guard !savedAppleID.isEmpty, !savedPassword.isEmpty else {
            throw "No saved Apple ID credentials found in Keychain."
        }

        return try await performAuthentication(
            appleID: savedAppleID,
            password: savedPassword,
            allowsInteractiveVerification: allowsInteractiveVerification,
            persistCredentials: true,
            logPrefix: logPrefix
        )
    }

    func fetchTeam(for account: Account, session: AppleAPISession) async throws -> Team {
        let fetchedTeams = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Team]?, Error>) in
            AppleAPI().fetchTeamsForAccount(account: account, session: session) { teams, error in
                if let error {
                    c.resume(throwing: error)
                    return
                }
                c.resume(returning: teams)
            }
        }

        guard let fetchedTeams,
              !fetchedTeams.isEmpty,
              let team = fetchedTeams.first else {
            throw "Unable to Fetch Team!"
        }

        return team
    }

    private func clearLiveSessionOnly() {
        DataManager.shared.model.clearLiveAuthState()
    }

    private func persistAuthState(email: String, teamIdentifier: String?) {
        let state = PersistedAuthState(
            appleID: email,
            teamIdentifier: teamIdentifier,
            anisetteServerURL: DataManager.shared.model.anisetteServerURL,
            lastSuccessfulAuthAt: Date().timeIntervalSince1970
        )

        do {
            Keychain.shared.authStateData = try JSONEncoder().encode(state)
        } catch {
            appendLog("Failed to persist auth state: \(error.localizedDescription)")
        }
    }

    private func appendLog(_ text: String) {
        let next = logs + "\(text)\n"
        if next.count > 12000 {
            logs = String(next.suffix(12000))
        } else {
            logs = next
        }
    }
}