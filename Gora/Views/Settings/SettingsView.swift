//
//  SettingsView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import FirebaseAnalytics
import SwiftUI

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
    // Stored only; nothing reads it yet.
    @AppStorage(SettingsKey.saveTripHistory) private var saveTripHistory = true
    @AppStorage(SettingsKey.shareUsageData) private var shareUsageData = false
    @AppStorage(SettingsKey.vibrateNearDestination) private var vibrateNearDestination = true
    @AppStorage(SettingsKey.vibrateStopBeforeExit) private var vibrateStopBeforeExit = true
    @AppStorage(SettingsKey.liquidGlassEnabled) private var liquidGlassEnabled = true

    @State private var permissions = SettingsPermissions()
    @State private var isLoggingOut = false
    @State private var showSignOutAlert = false

    var body: some View {
        NavigationStack {
            List {
                profileSection
                commuteSection
                arrivalVibrationSection
                appearanceSection
                permissionsSection
                dataSection
                supportSection
                aboutSection
                signOutSection
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DesignTokens.Space.xxxl)
            .navigationTitle("Settings")
            .task { await permissions.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await permissions.refresh() } }
            }
            .onChange(of: shareUsageData) { _, isOn in
                Analytics.setAnalyticsCollectionEnabled(isOn)
            }
            .onChange(of: vibrateNearDestination) { _, isOn in requestNotificationAccess(ifOn: isOn) }
            .onChange(of: vibrateStopBeforeExit) { _, isOn in requestNotificationAccess(ifOn: isOn) }
            .alert("Sign Out?", isPresented: $showSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) { Task { await logout() } }
            } message: {
                Text("Your saved places and trip history stay in your account.")
            }
        }
    }

    // MARK: Sections

    private var profileSection: some View {
        Section {
            NavigationLink {
                SettingsProfileView()
            } label: {
                HStack(spacing: DesignTokens.Space.ml) {
                    SettingsAvatar(name: session.currentUser?.displayName ?? "", diameter: 60,
                                   font: .title2.bold())
                    VStack(alignment: .leading) {
                        Text(session.currentUser?.displayName ?? "").font(.title3.weight(.semibold))
                        Text("Name, email and account").font(.subheadline).foregroundStyle(.secondary)
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
                valueRow("Saved Places", "mappin.and.ellipse", .vermilion, "\(savedPlaces.places.count)")
            }
            NavigationLink {
                SettingsChoicePage(title: "Route Preferences", selection: $routePreference)
            } label: {
                valueRow("Route Preferences", "point.topleft.down.to.point.bottomright.curvepath", .lagoon,
                         routePreference.title)
            }
            NavigationLink {
                SettingsChoicePage(title: "Fare Discount", selection: $fareDiscount)
            } label: {
                valueRow("Fare Discount", "ticket", .jade, fareDiscount.title)
            }
            Toggle(isOn: $liveActivitiesEnabled) {
                SettingsRowLabel(title: "Live Activities", systemImage: "platter.filled.bottom.iphone", tint: .onyx)
            }
        } header: {
            Text("Commute")
        } footer: {
            Text("Fare Discount applies the 20% student, senior citizen or PWD fare to estimates. Show a valid ID when you pay.")
        }
    }

    private var arrivalVibrationSection: some View {
        Section {
            Toggle(isOn: $vibrateNearDestination) {
                SettingsRowLabel(title: "Near Destination", systemImage: "scope", tint: .jade)
            }
            Toggle(isOn: $vibrateStopBeforeExit) {
                SettingsRowLabel(title: "One Stop Before Exit", systemImage: "tram.fill", tint: .lagoon)
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
                SettingsRowLabel(title: "Liquid Glass", systemImage: "drop.fill", tint: .onyx)
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Turn off to use solid backgrounds instead of Liquid Glass on Gora's buttons and cards. System bars and sheets keep Liquid Glass.")
        }
    }

    private var permissionsSection: some View {
        Section {
            linkRow("Location", "location.fill", .lagoon, permissions.locationValue) {
                open(UIApplication.openSettingsURLString)
            }
            linkRow("Notifications", "bell.fill", .vermilion, permissions.notificationsValue) {
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
                SettingsRowLabel(title: "Save Trip History", systemImage: "clock.arrow.circlepath", tint: .slate)
            }
            Toggle(isOn: $shareUsageData) {
                SettingsRowLabel(title: "Share Usage Data", systemImage: "chart.bar.fill", tint: .lagoon)
            }
            NavigationLink {
                SettingsDownloadDataView()
            } label: {
                SettingsRowLabel(title: "Download My Data", systemImage: "arrow.down.circle", tint: .onyx)
            }
        } header: {
            Text("Data & Privacy")
        } footer: {
            Text("Usage data is anonymous and helps improve route times. It never includes your name or saved places.")
        }
    }

    private var supportSection: some View {
        Section("Support") {
            linkRow("Help Center", "questionmark.circle", .jade, nil) { open("https://commutebeh.app/help") }
            linkRow("Contact Support", "envelope", .lagoon, nil, showsArrow: false) {
                open("mailto:support@commutebeh.app")
            }
            NavigationLink {
                SettingsRouteReportView()
            } label: {
                SettingsRowLabel(title: "Report a Route Problem", systemImage: "exclamationmark.bubble", tint: .vermilion)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            NavigationLink {
                SettingsDocumentView(document: .privacyPolicy)
            } label: {
                SettingsRowLabel(title: "Privacy Policy", systemImage: "hand.raised.fill", tint: .slate)
            }
            NavigationLink {
                SettingsDocumentView(document: .terms)
            } label: {
                SettingsRowLabel(title: "Terms and Conditions", systemImage: "doc.text", tint: .slate)
            }
            NavigationLink {
                SettingsAcknowledgementsView()
            } label: {
                SettingsRowLabel(title: "Acknowledgements", systemImage: "heart", tint: .vermilion)
            }
            valueRow("Version", "info.circle", .slate, Self.versionText)
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
            .font(DesignTokens.TypeScale.subtitle)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private func valueRow(_ title: String, _ symbol: String, _ tint: Color, _ value: String) -> some View {
        // An HStack, not LabeledContent: LabeledContent moves the value under the title when space is short.
        HStack {
            SettingsRowLabel(title: title, systemImage: symbol, tint: tint)
                .layoutPriority(1)
            Spacer(minLength: DesignTokens.Space.s)
            valueText(value)
        }
    }

    private func linkRow(_ title: String, _ symbol: String, _ tint: Color, _ value: String?, showsArrow: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                SettingsRowLabel(title: title, systemImage: symbol, tint: tint)
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

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }
}
