//
//  Shared.swift
//  Entitlement
//
//  Created by s s on 2025/3/15.
//

import SwiftUI
import StosSign

class AlertHelper<T>: ObservableObject {
    @Published var show = false
    private var result: T?
    private var c: CheckedContinuation<Void, Never>? = nil

    func open() async -> T? {
        await withCheckedContinuation { c in
            self.c = c
            Task { @MainActor in
                self.show = true
            }
        }
        return self.result
    }

    func close(result: T?) {
        if let c {
            self.result = result
            c.resume()
            self.c = nil
        }
        DispatchQueue.main.async {
            self.show = false
        }
    }
}

typealias YesNoHelper = AlertHelper<Bool>

class InputHelper: AlertHelper<String> {
    @Published var initVal = ""

    func open(initVal: String) async -> String? {
        self.initVal = initVal
        return await super.open()
    }

    override func open() async -> String? {
        self.initVal = ""
        return await super.open()
    }
}

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }

    var loc: String {
        return self
    }

    func localizeWithFormat(_ arguments: CVarArg...) -> String {
        String.localizedStringWithFormat(self.loc, arguments)
    }
}

final class SharedModel: ObservableObject {
    @Published var isLogin = false
    @Published var account: Account?
    @Published var team: Team?

    @AppStorage("AnisetteServer") var anisetteServerURL = "https://ani.sidestore.io"

    var session: AppleAPISession?

    init() {
        applyAnisetteServerURL()
    }

    func applyAnisetteServerURL() {
        let trimmed = anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        anisetteServerURL = trimmed.isEmpty ? "https://ani.sidestore.io" : trimmed
        AnisetteDataHelper.shared.url = URL(string: anisetteServerURL)
    }

    func update(account: Account, session: AppleAPISession, team: Team) {
        self.account = account
        self.session = session
        self.team = team
        self.isLogin = true
    }

    func clearLiveAuthState() {
        self.account = nil
        self.session = nil
        self.team = nil
        self.isLogin = false
    }
}

final class DataManager {
    static let shared = DataManager()
    let model = SharedModel()

    private init() {}
}