//
//  KeyWindowProvider.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import UIKit

enum KeyWindowProvider {
    /// The key window of the foreground active scene.
    @MainActor static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }
    }

    @MainActor static var topViewController: UIViewController? {
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
