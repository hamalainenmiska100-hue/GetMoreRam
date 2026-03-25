//
//  LoginViewModel.swift
//  Entitlement
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import StosSign
import KeychainAccess

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var appleID = ""
    @Published var password = ""
    @Published var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var isLoginInProgress = false
    @Published var logs = ""
    
    private var verificationCodeHandler: ((String?) -> Void)?
    
    func submitVerficationCode() {
        let trimmedCode = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        verificationCodeHandler?(trimmedCode.isEmpty ? nil : trimmedCode)
    }
    
    func resetForNewAttempt(clearStoredCredentials: Bool = false) {
        needVerificationCode = false
        verificationCode = ""
        verificationCodeHandler = nil
        isLoginInProgress = false
        
        if clearStoredCredentials {
            appleID = ""
            password = ""
        }
    }
    
    func authenticate() async throws -> Bool {
        if isLoginInProgress {
            return false
        }
        
        let enteredAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredPassword = password
        
        guard !enteredAppleID.isEmpty else {
            throw "Apple ID is required."
        }
        
        guard !enteredPassword.isEmpty else {
            throw "Password is required."
        }
        
        logs = ""
        isLoginInProgress = true
        
        func logging(text: String) {
            Task { @MainActor in
                self.logs.append("\(text)\n")
            }
        }
        
        AnisetteDataHelper.shared.loggingFunc = logging
        
        defer {
            AnisetteDataHelper.shared.loggingFunc = nil
            resetForNewAttempt()
        }
        
        let anisetteData = try await AnisetteDataHelper.shared.getAnisetteData()
        
        let (account, session) = try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<(Account, AppleAPISession), Error>) in
            AppleAPI().authenticate(appleID: enteredAppleID, password: enteredPassword, anisetteData: anisetteData) { completionHandler in
                self.verificationCodeHandler = completionHandler
                Task { @MainActor in
                    self.needVerificationCode = true
                }
            } completionHandler: { account, session, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let account, let session {
                    continuation.resume(returning: (account, session))
                } else {
                    continuation.resume(throwing: "Account or session is nil. Please try again or reopen the app.")
                }
            }
        }
        logging(text: "Successfully signed in")
        
        let team = try await fetchTeam(for: account, session: session)
        logging(text: "Successfully fetched team")
        
        DataManager.shared.model.account = account
        DataManager.shared.model.session = session
        DataManager.shared.model.team = team
        DataManager.shared.model.isLogin = true
        Keychain.shared.appleIDEmailAddress = enteredAppleID
        Keychain.shared.appleIDPassword = enteredPassword
        
        return true
    }
    
    func fetchTeam(for account: Account, session: AppleAPISession) async throws -> Team {
        let fetchedTeams = try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<[Team]?, Error>) in
            AppleAPI().fetchTeamsForAccount(account: account, session: session) { teams, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: teams)
            }
        }
        
        guard let fetchedTeams, !fetchedTeams.isEmpty, let team = fetchedTeams.first else {
            throw "Unable to Fetch Team!"
        }
        
        return team
    }
}
