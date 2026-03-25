//
//  AppIDView.swift
//  Entitlement
//
//  Created by s s on 2025/3/15.
//

import SwiftUI

struct AppIDView: View {
    @ObservedObject var viewModel: AppIDViewModel

    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var showBulkResult = false
    @State private var showApplyAllConfirm = false

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading && viewModel.appIDs.isEmpty {
                    ProgressView()
                } else {
                    List(viewModel.appIDs, id: \.self) { item in
                        NavigationLink {
                            appIDDetailView(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.bundleID)
                                    .font(.headline)
                                    .lineLimit(nil)

                                if !item.result.isEmpty {
                                    Text(item.result)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("App IDs")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showApplyAllConfirm = true
                    } label: {
                        if viewModel.isApplyingToAll {
                            ProgressView()
                        } else {
                            Text("All")
                        }
                    }
                    .disabled(viewModel.isApplyingToAll || viewModel.isLoading)

                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isApplyingToAll || viewModel.isLoading)
                }
            }
            .task {
                if viewModel.appIDs.isEmpty {
                    await refresh()
                }
            }
            .alert("Error", isPresented: $errorShow) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorInfo)
            }
            .alert("Apply entitlement to all App IDs?", isPresented: $showApplyAllConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Apply to All") {
                    Task {
                        await viewModel.applyIncreasedMemoryToAll()
                        showBulkResult = true
                    }
                }
            } message: {
                Text("This will try to enable the entitlement for every App ID currently listed.")
            }
            .alert("Bulk Result", isPresented: $showBulkResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.bulkResultText.isEmpty ? "Done." : viewModel.bulkResultText)
            }
            .overlay(alignment: .bottom) {
                if viewModel.isApplyingToAll || !viewModel.bulkProgressText.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(viewModel.bulkProgressText.isEmpty ? "Working..." : viewModel.bulkProgressText)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private func appIDDetailView(_ item: AppIDModel) -> some View {
        Form {
            Section {
                Text(item.bundleID)
                    .textSelection(.enabled)

                if !item.result.isEmpty {
                    Text(item.result)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Bundle ID")
            }

            Section {
                Button {
                    Task {
                        do {
                            try await item.addIncreasedMemory()
                        } catch {
                            errorInfo = error.localizedDescription
                            errorShow = true
                        }
                    }
                } label: {
                    if item.isProcessing {
                        ProgressView()
                    } else {
                        Text("Add Increased Memory")
                    }
                }
                .disabled(item.isProcessing || viewModel.isApplyingToAll)
            }
        }
        .navigationTitle("App ID")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refresh() async {
        do {
            try await viewModel.fetchAppIDs()
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}

#Preview {
    AppIDView(viewModel: AppIDViewModel())
}