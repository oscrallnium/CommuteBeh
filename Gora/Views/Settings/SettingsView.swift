//
//  SettingsView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import FirebaseAnalytics
import SwiftUI

private enum VersionCheck {
    case idle
    case checking
}

private enum VersionCheckStrings {
    static let actionName = "Check for Data Update"
}

/// The web pages that Settings opens in a Safari sheet.
private enum SafariPage: Identifiable {
    case help, privacy, terms

    var id: Self { self }

    var url: URL {
        switch self {
        case .help: LegalLinks.support
        case .privacy: LegalLinks.privacyPolicy
        case .terms: LegalLinks.terms
        }
    }
}

/// The Settings tab: profile, commute options, permissions, data, support and about.
struct SettingsView: View {
    @Environment(UserSession.self) private var session
    @Environment(SavedPlacesStore.self) private var savedPlaces
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    // The routing engine does not read the route preference yet.
    @AppStorage(SettingsKey.routePreference) private var routePreference: RoutePriority = .fewestTransfers
    // Fare estimates do not use the fare discount yet.
    @AppStorage(SettingsKey.fareDiscount) private var fareDiscount: FareDiscount = .none
    @AppStorage(SettingsKey.liveActivitiesEnabled) private var liveActivitiesEnabled = true
    @AppStorage(SettingsKey.showOtherModes) private var showOtherModes = true
    // Stored only; nothing reads it yet.
    @AppStorage(SettingsKey.saveTripHistory) private var saveTripHistory = true
    @AppStorage(SettingsKey.shareUsageData) private var shareUsageData = true
    @AppStorage(SettingsKey.vibrateNearDestination) private var vibrateNearDestination = true
    @AppStorage(SettingsKey.vibrateStopBeforeExit) private var vibrateStopBeforeExit = true
    @AppStorage(SettingsKey.liquidGlassEnabled) private var liquidGlassEnabled = true
    @AppStorage(SettingsKey.use24HourTime) private var use24HourTime = false

    @State private var permissions = SettingsPermissions()
    @State private var isLoggingOut = false
    @State private var showSignOutAlert = false
    @State private var graphVersion: String?
    @State private var versionCheck: VersionCheck = .idle
    @State private var versionHapticCount = 0
    @State private var paymentCount: Int?
    @State private var excludedPaymentIDs = SettingsKey.excludedPaymentIDs
    @State private var safariPage: SafariPage?

    var body: some View {
        NavigationStack {
            List {
                if session.isLoggedIn { profileSection } else { signInSection }
                commuteSection
                arrivalVibrationSection
                appearanceSection
                permissionsSection
                dataSection
                supportSection
                aboutSection
                if session.isLoggedIn { signOutSection }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DesignTokens.Space.xxxl)
            .navigationTitle("Settings")
            .task { await permissions.refresh() }
            .task { await loadGraphVersion() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TransitDataDidUpdate"))) { _ in
                Task { await loadGraphVersion() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                excludedPaymentIDs = SettingsKey.excludedPaymentIDs
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await permissions.refresh() } }
            }
            .onChange(of: shareUsageData) { _, isOn in
                Analytics.setAnalyticsCollectionEnabled(isOn)
            }
            .onChange(of: vibrateNearDestination) { _, isOn in requestNotificationAccess(ifOn: isOn) }
            .onChange(of: vibrateStopBeforeExit) { _, isOn in requestNotificationAccess(ifOn: isOn) }
            .sheet(item: $safariPage) { page in
                SafariView(url: page.url).ignoresSafeArea()
            }
            .alert("Sign Out?", isPresented: $showSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) { Task { await logout() } }
            } message: {
                Text("Your saved places and trip history stay in your account.")
            }
        }
    }

    // MARK: Sections

    private var signInSection: some View {
        Section {
            Button {
                session.requestLogin()
            } label: {
                Text("Sign In").frame(maxWidth: .infinity)
            }
        } footer: {
            Text("Sign in to sync your saved places and trip history.")
        }
    }

    private var profileSection: some View {
        Section {
            NavigationLink {
                SettingsProfileView()
            } label: {
                HStack(spacing: DesignTokens.Space.ml) {
                    SettingsAvatar(name: session.currentUser?.displayName ?? "", diameter: 60,
                                   font: .system(.title2, weight: .bold))
                    VStack(alignment: .leading) {
                        Text(session.currentUser?.displayName ?? "").font(.system(.title3, weight: .semibold))
                        Text("Name, email and account").font(.system(.subheadline)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, DesignTokens.Space.xs)
            }
        }
    }

    private var commuteSection: some View {
        Section {
            NavigationLink {
                SettingsSavedPlacesView()
            } label: {
                valueRow("Saved Places", "mappin.and.ellipse", "\(savedPlaces.places.count)")
            }
            NavigationLink {
                SettingsChoicePage(title: "Route Preferences", selection: $routePreference)
            } label: {
                valueRow("Route Preferences", "point.topleft.down.to.point.bottomright.curvepath",
                         routePreference.title)
            }
            NavigationLink {
                SettingsChoicePage(title: "Fare Discount", selection: $fareDiscount)
            } label: {
                valueRow("Fare Discount", "ticket", fareDiscount.title)
            }
            NavigationLink {
                SettingsPaymentsView()
            } label: {
                valueRow("Payment Methods", "creditcard", paymentsValue)
            }
            Toggle(isOn: $liveActivitiesEnabled) {
                SettingsRowLabel(title: "Live Activities", systemImage: "platter.filled.bottom.iphone")
            }
            Toggle(isOn: $showOtherModes) {
                SettingsRowLabel(title: "Other Modes at Stops", systemImage: "arrow.triangle.branch")
            }
        } header: {
            Text("Commute")
        } footer: {
            Text("Fare Discount applies the 20% student, senior citizen or PWD fare to estimates. Show a valid ID when you pay. Other Modes at Stops lists jeepneys, buses and trains that also stop at the same stops as a ride.")
        }
    }

    private var arrivalVibrationSection: some View {
        Section {
            Toggle(isOn: $vibrateNearDestination) {
                SettingsRowLabel(title: "Near Destination", systemImage: "scope")
            }
            Toggle(isOn: $vibrateStopBeforeExit) {
                SettingsRowLabel(title: "One Stop Before Exit", systemImage: "tram")
            }
        } header: {
            Text("Arrival Vibration")
        } footer: {
            Text("During a commute, your phone vibrates when you are about 200 m from your destination, or when your train is one stop before your exit. Works on the Lock Screen.")
        }
    }

    private var appearanceSection: some View {
        Section {
            Toggle(isOn: $liquidGlassEnabled) {
                SettingsRowLabel(title: "Liquid Glass", systemImage: "drop")
            }
            Toggle(isOn: $use24HourTime) {
                SettingsRowLabel(title: "24-Hour Time", systemImage: "clock")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Turn off to use solid backgrounds instead of Liquid Glass on Gora's buttons and cards. System bars and sheets keep Liquid Glass. 24-Hour Time shows arrival times as 13:24 instead of 1:24 PM.")
        }
    }

    private var permissionsSection: some View {
        Section {
            linkRow("Location", "location", permissions.locationValue) {
                open(UIApplication.openSettingsURLString)
            }
            linkRow("Notifications", "bell", permissions.notificationsValue) {
                open(UIApplication.openNotificationSettingsURLString)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Gora uses your location to find routes and to follow your trip in Commute mode. Change access in iOS Settings.")
        }
    }

    private var dataSection: some View {
        Section {
            Toggle(isOn: $saveTripHistory) {
                SettingsRowLabel(title: "Save Trip History", systemImage: "clock.arrow.circlepath")
            }
            #if DEBUG
            Toggle(isOn: $shareUsageData) {
                SettingsRowLabel(title: "Share Usage Data", systemImage: "chart.bar")
            }
            #endif
            NavigationLink {
                SettingsDownloadDataView()
            } label: {
                SettingsRowLabel(title: "Download My Data", systemImage: "arrow.down.circle")
            }
        } header: {
            Text("Data & Privacy")
        } footer: {
            Text("Usage data is anonymous and helps improve route times. It never includes your name or saved places.")
        }
    }

    private var supportSection: some View {
        Section("Support") {
            linkRow("Help Center", "questionmark.circle", nil) { safariPage = .help }
            linkRow("Contact Support", "envelope", nil, showsArrow: false) {
                open(LegalLinks.supportEmail.absoluteString)
            }
            NavigationLink {
                SettingsRouteReportView()
            } label: {
                SettingsRowLabel(title: "Report a Route Problem", systemImage: "exclamationmark.bubble")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            linkRow("Privacy Policy", "hand.raised", nil) { safariPage = .privacy }
            linkRow("Terms and Conditions", "doc.text", nil) { safariPage = .terms }
            NavigationLink {
                SettingsAcknowledgementsView()
            } label: {
                SettingsRowLabel(title: "Acknowledgements", systemImage: "heart")
            }
            valueRow("Version", "info.circle", versionText)
                .contentShape(Rectangle())
                .onLongPressGesture { checkForDataUpdate() }
                .accessibilityAction(named: VersionCheckStrings.actionName) { checkForDataUpdate() }
                .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: versionHapticCount)
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                showSignOutAlert = true
            } label: {
                if isLoggingOut {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Sign Out").frame(maxWidth: .infinity)
                }
            }
            .disabled(isLoggingOut)
        }
    }

    // MARK: Rows

    /// A row value in one small line beside the title. It shrinks a little before it truncates.
    private func valueText(_ value: String) -> some View {
        Text(value)
            .typeScale(.subtitle)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private func valueRow(_ title: String, _ symbol: String, _ value: String) -> some View {
        // An HStack, not LabeledContent: LabeledContent moves the value under the title when space is short.
        HStack {
            SettingsRowLabel(title: title, systemImage: symbol)
                .layoutPriority(1)
            Spacer(minLength: DesignTokens.Space.s)
            valueText(value)
        }
    }

    private func linkRow(_ title: String, _ symbol: String, _ value: String?, showsArrow: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                SettingsRowLabel(title: title, systemImage: symbol)
                    .layoutPriority(1)
                Spacer()
                if let value { valueText(value) }
                if showsArrow {
                    Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: Actions

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        openURL(url)
    }

    private func requestNotificationAccess(ifOn isOn: Bool) {
        guard isOn else { return }
        Task {
            await SettingsPermissions.requestNotificationAccessIfUndetermined()
            await permissions.refresh()
        }
    }

    private func logout() async {
        isLoggingOut = true
        await session.logout()
    }

    private func checkForDataUpdate() {
        guard versionCheck == .idle else { return }
        versionCheck = .checking
        Task {
            defer { versionCheck = .idle }
            if graphVersion == nil { await loadGraphVersion() }
            guard let loadedVersion = graphVersion else { return }
            switch await GraphService.shared.updateIfNewer(loadedVersion: loadedVersion) {
            case .updated, .alreadyLatest: versionHapticCount += 1
            case .failed: break
            }
        }
    }

    private func loadGraphVersion() async {
        guard case .success(let graph) = await GraphStore.shared.graph() else { return }
        graphVersion = graph.version
        paymentCount = graph.paymentMethods.count
    }

    /// "All" when nothing is off, else "on of total". Shows "Custom" until the graph loads.
    private var paymentsValue: String {
        if excludedPaymentIDs.isEmpty { return "All" }
        guard let paymentCount else { return "Custom" }
        return "\(max(paymentCount - excludedPaymentIDs.count, 1)) of \(paymentCount)"
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let graph = graphVersion.map { "(\($0))" } ?? ""
        return "\(version) (\(build))\(graph)"
    }
}
