//
//  CommuteBehApp.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 5/27/26.
//

import SwiftUI

@main
struct CommuteBehApp: App {
    @State private var session = UserSession()

    var body: some Scene {
        WindowGroup {
            if session.isLoggedIn {
                MainTabView()
                    .environment(session)
            } else {
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
            ContentView()
                .tabItem { Label("Commute", systemImage: "arrow.triangle.swap") }
            ExploreView()
                .tabItem { Label("Explore", systemImage: "map.fill") }
            RecordCommuteView()
                .tabItem { Label("Record", systemImage: "record.circle") }
            if session.isAdmin {
                AdminRoutesView()
                    .tabItem { Label("Admin", systemImage: "gear.badge") }
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
