//
//  AdminRoutesView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI
import MapKit

// MARK: - Root: list of lines

struct AdminRoutesView: View {
    @State private var vm = AdminRoutesViewModel()
    @State private var routeToDelete: AdminRoutesViewModel.LineGroup?
    @State private var showCreateLoop = false

    var body: some View {
        NavigationStack {
            Group {
                if let error = vm.errorMessage {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else if vm.lineGroups.isEmpty {
                    ProgressView("Loading routes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if let error = vm.deleteRouteError {
                            Section {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(Color.vermilion)
                            }
                        }
                        Section("Settings") {
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { vm.enforceOperatingHours },
                                    set: { newValue in Task { await vm.setEnforceOperatingHours(newValue) } }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Enforce Operating Hours")
                                        if let err = vm.settingsError {
                                            Text(err)
                                                .font(.caption)
                                                .foregroundStyle(Color.vermilion)
                                        }
                                    }
                                }
                                .disabled(vm.isLoadingSettings)
                                if vm.isLoadingSettings {
                                    ProgressView()
                                        .padding(.leading, 4)
                                }
                            }
                        }
                        Section {
                            NavigationLink(destination: AdminEdgesView()) {
                                Label("Edit Polylines", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
                            }
                        }
                        Section("AR") {
                            NavigationLink(destination: ARSurveyListView()) {
                                Label("AR Surveys", systemImage: "arkit")
                            }
                            NavigationLink(destination: WalkARTestView()) {
                                Label("Walk AR Test", systemImage: "figure.walk")
                            }
                        }
                        Section("Lines") {
                            ForEach(vm.lineGroups) { group in
                                NavigationLink(destination: StationListView(group: group, vm: vm)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.id)
                                            .font(.headline)
                                        Text("\(group.stations.count) stations")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        routeToDelete = group
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .disabled(vm.isDeletingRoute)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .disabled(vm.isDeletingRoute)
                    .overlay {
                        if vm.isDeletingRoute {
                            ProgressView("Deleting route…")
                                .padding(16)
                                .background(.regularMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .navigationTitle("Manage Routes")
            .onAppear { vm.load() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TransitDataDidUpdate"))) { _ in
                vm.load()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateLoop = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Route")
                }
            }
            .fullScreenCover(isPresented: $showCreateLoop) {
                CreateLoopView()
            }
            .confirmationDialog(
                "Delete \(routeToDelete?.id ?? "") route?",
                isPresented: Binding(
                    get: { routeToDelete != nil },
                    set: { if !$0 { routeToDelete = nil } }
                ),
                presenting: routeToDelete
            ) { group in
                Button("Delete Route", role: .destructive) {
                    let lineId = group.id
                    routeToDelete = nil
                    Task { await vm.deleteRoute(lineId) }
                }
                Button("Cancel", role: .cancel) { routeToDelete = nil }
            } message: { group in
                Text("This permanently removes all \(group.stations.count) stations and every edge on \(group.id). This cannot be undone.")
            }
        }
    }
}
