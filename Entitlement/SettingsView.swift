//
//  SettingsView.swift
//  Entitlement
//
//  Created by s s on 2025/3/14.
//

import SwiftUI
import StosSign

struct SettingsView: View {

    @State var email = ""
    @State var teamId = ""
    @StateObject var viewModel : LoginViewModel
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    

    var body: some View {
        Form {

            Section {
                if sharedModel.isLogin {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(email)
                    }
                    HStack {
                        Text("Team ID")
                        Spacer()
                        Text(teamId)
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
                    TextField("", text: $sharedModel.anisetteServerURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
            }
            
            Section {
                Button("Clean Up Keychain") {
                    cleanUp()
                }
            } footer: {
                Text("If something went wrong during signing in, please try to clean up the keychain, reopen the app and try again.")
            }
        }
        .alert("Error", isPresented: $errorShow){
            Button("OK".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $viewModel.loginModalShow) {
            loginModal
        }
        .onAppear {
            sharedModel.syncAnisetteServerURL()
            refreshAccountSummary()
        }
        .onChange(of: sharedModel.anisetteServerURL) { _, _ in
            sharedModel.syncAnisetteServerURL()
        }
    }
    
    var loginModal: some View {
        NavigationView {
            Form {
                Section {
                    TextField("", text: $viewModel.appleID)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
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
                    } header: {
                        Text("Verification Code")
                    }
                }
                Section {
                    Button("Continue") {
                        Task { await loginButtonClicked() }
                    }
                    .disabled(viewModel.isLoginInProgress && !viewModel.needVerificationCode)
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
            sharedModel.syncAnisetteServerURL()
            if let email = Keychain.shared.appleIDEmailAddress, let password = Keychain.shared.appleIDPassword {
                viewModel.appleID = email
                viewModel.password = password
            }
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
                guard let account = sharedModel.account, let team = sharedModel.team else {
                    throw "Login succeeded, but account details were missing. Please reopen the app and try again."
                }
                
                viewModel.loginModalShow = false
                email = account.appleID
                teamId = team.identifier
            }
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func cleanUp() {
        Keychain.shared.adiPb = nil
        Keychain.shared.identifier = nil
        Keychain.shared.appleIDPassword = nil
        Keychain.shared.appleIDEmailAddress = nil
        sharedModel.resetSession()
        email = ""
        teamId = ""
        viewModel.resetForNewAttempt(clearStoredCredentials: true)
    }
    
    func refreshAccountSummary() {
        email = sharedModel.account?.appleID ?? ""
        teamId = sharedModel.team?.identifier ?? ""
    }
    
}
