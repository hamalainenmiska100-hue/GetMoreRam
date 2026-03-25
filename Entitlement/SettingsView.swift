//
//  SettingsView.swift
//  Entitlement
//
//  Created by s s on 2025/3/14.
//

import SwiftUI
import StosSign

struct SettingsView: View {
    @ObservedObject var viewModel: LoginViewModel
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var anisetteServerDraft = ""
    @State private var errorShow = false
    @State private var errorInfo = ""

    var body: some View {
        Form {
            Section {
                if sharedModel.isLogin {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(sharedModel.account?.appleID ?? Keychain.shared.appleIDEmailAddress ?? "")
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Team ID")
                        Spacer()
                        Text(sharedModel.team?.identifier ?? "")
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    Button("Sign in") {
                        viewModel.loginModalShow = true
                    }
                }
            } header: {
                Text("Account")
            }

            Section {
                HStack {
                    Text("Anisette Server URL")
                    Spacer()
                    TextField("", text: $anisetteServerDraft)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Button("Apply Anisette Server") {
                    Task { await applyAnisetteServerURL() }
                }
            } footer: {
                Text("Apply the server only after you finish editing the URL. This will clear the live session and try a silent reauth with the saved Apple ID.")
            }

            Section {
                Button("Clean Up Keychain") {
                    cleanUp()
                }
            } footer: {
                Text("If something went wrong during signing in, clean up the keychain, reopen the app and sign in again.")
            }
        }
        .alert("Error", isPresented: $errorShow) {
            Button("OK".loc, action: {})
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $viewModel.loginModalShow) {
            loginModal
        }
        .onAppear {
            anisetteServerDraft = sharedModel.anisetteServerURL
            sharedModel.applyAnisetteServerURL()
            viewModel.restoreCredentialsIntoFields()

            Task {
                await viewModel.bootstrapFromKeychainIfPossible()
            }
        }
    }

    var loginModal: some View {
        NavigationView {
            Form {
                Section {
                    TextField("", text: $viewModel.appleID)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(viewModel.isLoginInProgress)
                } header: {
                    Text("Apple ID")
                }

                Section {
                    SecureField("", text: $viewModel.password)
                        .disabled(viewModel.isLoginInProgress)
                } header: {
                    Text("Password")
                }

                if viewModel.needVerificationCode {
                    Section {
                        TextField("", text: $viewModel.verificationCode)
                            .keyboardType(.numberPad)
                            .disabled(viewModel.isLoginInProgress)
                    } header: {
                        Text("Verification Code")
                    }
                }

                Section {
                    Button("Continue") {
                        Task { await loginButtonClicked() }
                    }
                    .disabled(viewModel.isLoginInProgress)
                }

                Section {
                    Text(viewModel.logs)
                        .font(.system(.subheadline, design: .monospaced))
                } header: {
                    Text("Debugging")
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        viewModel.loginModalShow = false
                    }
                }
            }
        }
        .onAppear {
            viewModel.restoreCredentialsIntoFields()
        }
    }

    func loginButtonClicked() async {
        do {
            if viewModel.needVerificationCode {
                viewModel.submitVerficationCode()
                return
            }

            let result = try await viewModel.authenticate()
            if result {
                anisetteServerDraft = sharedModel.anisetteServerURL
                viewModel.loginModalShow = false
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func applyAnisetteServerURL() async {
        let trimmed = anisetteServerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorInfo = "Anisette Server URL cannot be empty."
            errorShow = true
            return
        }

        sharedModel.anisetteServerURL = trimmed
        await viewModel.handleAnisetteServerURLChange()
        anisetteServerDraft = sharedModel.anisetteServerURL
    }

    func cleanUp() {
        viewModel.clearAllAuthData()
        anisetteServerDraft = sharedModel.anisetteServerURL
    }
}