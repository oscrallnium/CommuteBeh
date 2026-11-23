//
//  GoraApp.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 5/27/26.
//

import SwiftUI
import FirebaseCore

@main
struct GoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = UserSession()
    @State private var savedPlaces = SavedPlacesStore()

    var body: some Scene {
        WindowGroup {
            // MainTabView stays mounted behind the cover, so a mid-session
            // sign-out (e.g. an expired token) never tears down and loses
            // in-progress state in a tab like Admin.
            MainTabView()
                .environment(session)
                .environment(savedPlaces)
                .task { await savedPlaces.load() }
                .fullScreenCover(isPresented: Binding(
                    get: { session.isLoginPresented },
                    set: { _ in }
                )) {
                    LoginView()
                        .environment(session)
                }
        }
    }

}

struct MainTabView: View {
    @Environment(UserSession.self) private var session

    var body: some View {
        TabView {
            Tab("Commute", systemImage: "arrow.triangle.swap") {
                ContentView().tint(Color?.none)
            }
            if session.isAdmin {
                Tab("Routes", systemImage: "map.fill") {
                    ExploreView().tint(Color?.none)
                }
                Tab("Admin", systemImage: "gear.badge") {
                    AdminRoutesView().tint(Color?.none)
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView().tint(Color?.none)
            }
        }
        // The selected tab uses the primary action blue. Each tab clears the tint, so its content keeps
        // the system colors: the accent color for controls and green for toggles.
        .tint(DesignTokens.Colors.action)
    }
}
