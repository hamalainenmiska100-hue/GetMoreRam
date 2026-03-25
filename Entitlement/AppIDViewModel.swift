//
//  AppIDViewModel.swift
//  Entitlement
//
//  Created by s s on 2025/3/15.
//

import SwiftUI
import StosSign

@MainActor
final class AppIDModel: ObservableObject, Hashable {
    static func == (lhs: AppIDModel, rhs: AppIDModel) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    var appID: AppID
    @Published var bundleID: String
    @Published var result: String = ""
    @Published var isProcessing = false

    init(appID: AppID) {
        self.appID = appID
        self.bundleID = appID.bundleIdentifier
    }

    func addIncreasedMemory() async throws {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        _ = try await LoginViewModel.shared.ensureAuthenticated(interactive: false)

        guard let team = DataManager.shared.model.team,
              let session = DataManager.shared.model.session else {
            throw "Please Login First"
        }

        let dateFormatter = ISO8601DateFormatter()
        let httpHeaders = [
            "Content-Type": "application/vnd.api+json",
            "User-Agent": "Xcode",
            "Accept": "application/vnd.api+json",
            "Accept-Language": "en-us",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "11.2 (11B41)",
            "X-Apple-I-Identity-Id": session.dsid,
            "X-Apple-GS-Token": session.authToken,
            "X-Apple-I-MD-M": session.anisetteData.machineID,
            "X-Apple-I-MD": session.anisetteData.oneTimePassword,
            "X-Apple-I-MD-LU": session.anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": session.anisetteData.routingInfo.description,
            "X-Mme-Device-Id": session.anisetteData.deviceUniqueIdentifier,
            "X-MMe-Client-Info": session.anisetteData.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from: session.anisetteData.date),
            "X-Apple-Locale": session.anisetteData.locale.identifier,
            "X-Apple-I-TimeZone": session.anisetteData.timeZone.abbreviation() ?? TimeZone.current.identifier
        ]

        var request = URLRequest(url: URL(string: "https://developerservices2.apple.com/services/v1/bundleIds/\(appID.identifier)")!)
        request.httpMethod = "PATCH"
        request.allHTTPHeaderFields = httpHeaders
        request.httpBody = """
        {"data":{"relationships":{"bundleIdCapabilities":{"data":[{"relationships":{"capability":{"data":{"id":"INCREASED_MEMORY_LIMIT","type":"capabilities"}}},"type":"bundleIdCapabilities","attributes":{"settings":[],"enabled":true}}]}},"id":"\(appID.identifier)","attributes":{"hasExclusiveManagedCapabilities":false,"teamId":"\(team.identifier)","bundleType":"bundle","identifier":"\(appID.bundleIdentifier)","seedId":"\(team.identifier)","name":"\(appID.name)"},"type":"bundleIds"}}
        """.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw "HTTP \(httpResponse.statusCode): \(body)"
        }

        result = String(data: data, encoding: .utf8) ?? "OK"
    }
}

@MainActor
final class AppIDViewModel: ObservableObject {
    @Published var appIDs: [AppIDModel] = []
    @Published var isLoading = false
    @Published var isApplyingToAll = false
    @Published var bulkProgressText = ""
    @Published var bulkResultText = ""

    func fetchAppIDs() async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        _ = try await LoginViewModel.shared.ensureAuthenticated(interactive: false)

        guard let team = DataManager.shared.model.team,
              let session = DataManager.shared.model.session else {
            throw "Please Login First"
        }

        let ids = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[AppID], Error>) in
            AppleAPI().fetchAppIDsForTeam(team: team, session: session) { appIDs, error in
                if let error {
                    c.resume(throwing: error)
                    return
                }

                guard let appIDs else {
                    c.resume(throwing: "AppIDs is nil. Please try again or reopen the app.")
                    return
                }

                c.resume(returning: appIDs)
            }
        }

        let uniqueIDs = Dictionary(grouping: ids, by: \.identifier)
            .compactMap { $0.value.first }
            .sorted {
                $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending
            }

        appIDs = uniqueIDs.map { AppIDModel(appID: $0) }
    }

    func applyIncreasedMemoryToAll() async {
        guard !isApplyingToAll else { return }
        isApplyingToAll = true
        bulkProgressText = ""
        bulkResultText = ""

        defer { isApplyingToAll = false }

        if appIDs.isEmpty {
            do {
                try await fetchAppIDs()
            } catch {
                bulkResultText = "Failed to load App IDs: \(error.localizedDescription)"
                return
            }
        }

        var successCount = 0
        var failureMessages: [String] = []

        for (index, model) in appIDs.enumerated() {
            bulkProgressText = "Processing \(index + 1)/\(appIDs.count): \(model.bundleID)"

            do {
                try await model.addIncreasedMemory()
                successCount += 1
            } catch {
                let message = "\(model.bundleID): \(error.localizedDescription)"
                model.result = message
                failureMessages.append(message)
            }
        }

        if failureMessages.isEmpty {
            bulkResultText = "Done. Added entitlement to \(successCount)/\(appIDs.count) App IDs."
        } else {
            bulkResultText = """
            Done. Success: \(successCount)/\(appIDs.count)

            Failures:
            \(failureMessages.joined(separator: "\n"))
            """
        }

        bulkProgressText = ""
    }
}