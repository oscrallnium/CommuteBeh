//
//  SafariView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/22/26.
//

import SafariServices
import SwiftUI

/// Addresses of the legal and support pages that Gora publishes, and the support email address.
enum LegalLinks {
    static let privacyPolicy = URL(string: "https://gora-legal.pages.dev/privacy")!
    static let terms = URL(string: "https://gora-legal.pages.dev/terms")!
    static let support = URL(string: "https://gora-legal.pages.dev/support")!
    static let supportEmail = URL(string: "mailto:gorasupport@gmail.com")!
}

/// Shows one web page in `SFSafariViewController`. Present it in a sheet.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(DesignTokens.Colors.action)
        controller.delegate = context.coordinator
        context.coordinator.dismiss = context.environment.dismiss
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.dismiss = context.environment.dismiss
    }

    /// Closes the hosting sheet when the person taps Done.
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var dismiss: DismissAction?

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            dismiss?()
        }
    }
}
