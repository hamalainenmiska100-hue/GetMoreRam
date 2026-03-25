//
//  ContentView.swift
//  Entitlement
//
//  Created by s s on 2025/3/14.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var loginViewModel = LoginViewModel.shared
    @StateObject private var appIDViewModel = AppIDViewModel()

    var body: some View {
        TabView {
            AppIDView(viewModel: appIDViewModel)
                .tabItem {
                    Label("App IDs".loc, systemImage: "square.stack.3d.up.fill")
                }

            SettingsView(viewModel: loginViewModel)
                .tabItem {
                    Label("Settings".loc, systemImage: "gearshape.fill")
                }
        }
        .environmentObject(DataManager.shared.model)
    }
}

#Preview {
    ContentView()
}