//
//  SettingsWebPageView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/22/26.
//

import SwiftUI
import WebKit

/// Addresses of the legal pages that Gora publishes on the web.
enum LegalLinks {
    static let privacyPolicy = URL(string: "https://gora-legal.pages.dev/privacy")!
}

/// A pushed page that shows one web page, with a loading state and a retry state.
struct SettingsWebPageView: View {
    let title: String
    let url: URL

    @State private var page = WebPage()
    @State private var loadFailed = false

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loadFailed {
            errorState
        } else {
            WebView(page)
                .overlay { loadingIndicator }
        }
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if page.isLoading {
            ProgressView()
                .accessibilityLabel(Strings.loadingLabel)
        }
    }

    private var errorState: some View {
        ContentUnavailableView {
            Label(Strings.errorTitle, systemImage: "wifi.exclamationmark")
        } description: {
            Text(Strings.errorDescription)
        } actions: {
            Button(Strings.retry) {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func load() async {
        loadFailed = false
        do {
            for try await _ in page.load(url) {}
        } catch {
            loadFailed = true
        }
    }
}

private enum Strings {
    static let loadingLabel = "Loading page"
    static let errorTitle = "Can't Load Page"
    static let errorDescription = "Check your internet connection and try again."
    static let retry = "Try Again"
}
