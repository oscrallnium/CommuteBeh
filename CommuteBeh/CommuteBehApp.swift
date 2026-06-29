//
//  CommuteBehApp.swift
//  CommuteBeh
//
//  Created by Oscar Allen Brioso on 5/27/26.
//

import SwiftUI

@main
struct CommuteBehApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Commute", systemImage: "arrow.triangle.swap") }
                ExploreView()
                    .tabItem { Label("Explore", systemImage: "map.fill") }
                RecordCommuteView()
                    .tabItem { Label("Record", systemImage: "record.circle") }
            }
        }
    }
}
