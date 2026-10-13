//
//  AppDelegate.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import UIKit
import FirebaseCore

/// Configures Firebase at launch. It runs before any view, so every Firebase call in the app
/// finds a configured default app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        return true
    }
}
