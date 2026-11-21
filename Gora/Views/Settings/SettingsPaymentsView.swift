//
//  SettingsPaymentsView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/15/26.
//

import SwiftUI

/// The Payment Methods page. One toggle row per payment method of the graph.
struct SettingsPaymentsView: View {
    @State private var vm = SettingsPaymentsViewModel()

    var body: some View {
        content
            .navigationTitle(Strings.title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await vm.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            Text(Strings.unavailable)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(DesignTokens.Space.xxxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let methods):
            methodList(methods)
        }
    }

    private func methodList(_ methods: [PaymentMethodConfig]) -> some View {
        List {
            Section {
                ForEach(methods, id: \.id) { method in
                    methodRow(method)
                }
            } footer: {
                Text(Strings.footer)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func methodRow(_ method: PaymentMethodConfig) -> some View {
        Toggle(isOn: Binding(
            get: { vm.isOn(method.id) },
            set: { vm.set(method.id, isOn: $0) }
        )) {
            HStack(spacing: DesignTokens.Space.ml) {
                PaymentMethodIcon(config: method)
                Text(method.displayName)
            }
        }
        .disabled(vm.isLastOn(method.id))
    }

    private enum Strings {
        static let title = "Payment Methods"
        static let unavailable = "Payment methods are not available. Connect to the internet and try again."
        static let footer = "Routes use only lines that accept at least one of these methods."
    }
}

/// Loads the payment methods and stores the IDs that the passenger turned off.
@Observable
@MainActor
final class SettingsPaymentsViewModel {
    enum LoadState {
        case loading
        case loaded([PaymentMethodConfig])
        case failed
    }

    private(set) var state: LoadState = .loading
    private var excluded = SettingsKey.excludedPaymentIDs

    func load() async {
        switch await GraphStore.shared.graph() {
        case .success(let graph):
            state = .loaded(graph.paymentMethods.values.sorted { $0.displayName < $1.displayName })
        case .failure:
            state = .failed
        }
    }

    func isOn(_ id: String) -> Bool { !excluded.contains(id) }

    /// True when the method is on and no other method is on.
    func isLastOn(_ id: String) -> Bool {
        guard case .loaded(let methods) = state, isOn(id) else { return false }
        return methods.filter { isOn($0.id) }.count == 1
    }

    func set(_ id: String, isOn: Bool) {
        if isOn { excluded.remove(id) } else { excluded.insert(id) }
        SettingsKey.setExcludedPaymentIDs(excluded)
    }
}
