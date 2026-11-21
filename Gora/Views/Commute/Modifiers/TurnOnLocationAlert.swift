//
//  TurnOnLocationAlert.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/19/26.
//

import SwiftUI

extension View {
    /// Shows the Turn On Location alert. iOS does not show the permission prompt again after
    /// Don't Allow, so every Turn On control opens this alert, and its button opens Settings.
    func turnOnLocationAlert(isPresented: Binding<Bool>) -> some View {
        modifier(TurnOnLocationAlert(isPresented: isPresented))
    }
}

private struct TurnOnLocationAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    private enum Strings {
        static let title = "Turn On Location"
        static let message = "In Settings, tap Location, then choose While Using the App. Turn on Precise Location so Gora can follow each step."
        static let notNow = "Not Now"
        static let openSettings = "Open Settings"
    }

    func body(content: Content) -> some View {
        content.alert(Strings.title, isPresented: $isPresented) {
            Button(Strings.notNow, role: .cancel) {}
            Button(Strings.openSettings, action: openSettings)
        } message: {
            Text(Strings.message)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
