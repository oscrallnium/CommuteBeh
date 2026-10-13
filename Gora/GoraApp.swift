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
                    get: { !session.isLoggedIn },
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
                ContentView()
            }
            Tab("Explore", systemImage: "map.fill") {
                ExploreView()
            }
            Tab("Record", systemImage: "record.circle") {
                RecordCommuteView()
            }
            if session.isAdmin {
                Tab("Admin", systemImage: "gear.badge") {
                    AdminRoutesView()
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}
