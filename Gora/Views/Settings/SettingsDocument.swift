//
//  SettingsDocument.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import Foundation

/// The text of a legal document: dated sections and a closing line.
struct SettingsDocument {
    struct Section: Identifiable {
        let heading: String
        let body: String
        var id: String { heading }
    }

    let title: String
    let effective: String
    let sections: [Section]
    let footer: String
}

extension SettingsDocument {
    static let privacyPolicy = SettingsDocument(
        title: "Privacy Policy",
        effective: "Effective October 1, 2026",
        sections: [
            Section(heading: "What Gora collects",
                    body: "Your name and email, the places you save, and the trips you plan or record. Location is used only while you use the app or during an active commute."),
            Section(heading: "How it is used",
                    body: "To find routes, follow your trip in Commute mode and estimate fares. Anonymous usage data is collected only if you turn it on in Settings."),
            Section(heading: "Your choices",
                    body: "Turn off trip history, download a copy of your data or delete your account at any time from Settings."),
            Section(heading: "Contact",
                    body: "Questions about privacy go to privacy@commutebeh.app."),
        ],
        footer: "The full policy is also published at commutebeh.app/privacy.")

    static let terms = SettingsDocument(
        title: "Terms",
        effective: "Effective October 1, 2026",
        sections: [
            Section(heading: "Using Gora",
                    body: "Gora suggests routes using public transit, jeepney and walking data. Follow posted signs and instructions from transport staff."),
            Section(heading: "Routes and fares",
                    body: "Travel times and fares are estimates and can change without notice. Pay the fare charged by the operator."),
            Section(heading: "Your account",
                    body: "Keep your sign-in details private. You are responsible for activity on your account."),
            Section(heading: "Changes to these terms",
                    body: "When the terms change, the app shows the new version before you continue."),
        ],
        footer: "The full terms are also published at commutebeh.app/terms.")
}
