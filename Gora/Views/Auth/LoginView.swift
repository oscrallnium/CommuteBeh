//
//  LoginView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI

struct LoginView: View {
    @Environment(UserSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var status: SignInStatus = .idle
    @State private var legalPage: LegalPage?
    @State private var introVisible = false

    private enum Provider {
        case apple, google

        @MainActor func signIn() async throws -> UserProfile {
            switch self {
            case .apple: try await AuthService.shared.signInWithApple()
            case .google: try await AuthService.shared.signInWithGoogle()
            }
        }
    }

    private enum SignInStatus {
        case idle
        case signingIn(Provider)
        case failed(String)

        var message: String {
            switch self {
            case .idle, .signingIn: ""
            case .failed(let message): message
            }
        }

        var isSigningIn: Bool {
            if case .signingIn = self { return true }
            return false
        }

        func isSigningIn(_ provider: Provider) -> Bool {
            if case .signingIn(let current) = self { return current == provider }
            return false
        }
    }

    private enum LegalPage: Identifiable {
        case terms, privacyPolicy

        var id: Self { self }

        var url: URL {
            switch self {
            case .terms: LegalLinks.terms
            case .privacyPolicy: LegalLinks.privacyPolicy
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background.ignoresSafeArea()
            hero
            content
        }
        .environment(\.colorScheme, .light)
        .sheet(item: $legalPage) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        .onAppear(perform: showIntro)
        .onChange(of: status.message) { _, message in
            guard !message.isEmpty else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private var hero: some View {
        GeometryReader { proxy in
            let imageWidth = max(proxy.size.width, proxy.size.height * Layout.imageAspect)
            Image(Strings.heroImage)
                .resizable()
                .frame(width: imageWidth, height: proxy.size.height)
                .offset(x: -(imageWidth - proxy.size.width) * Layout.imageFocusX)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
        .frame(height: Layout.heroHeight)
        .overlay { heroFade }
        .ignoresSafeArea(edges: .top)
        .accessibilityHidden(true)
    }

    private var heroFade: some View {
        LinearGradient(
            stops: [
                .init(color: Palette.background.opacity(0), location: 0),
                .init(color: Palette.background.opacity(0), location: Layout.fadeStart),
                .init(color: Palette.background.opacity(Layout.fadeMidOpacity), location: Layout.fadeMid),
                .init(color: Palette.background, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            intro
            buttons
            guestButton
            legalNote
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.bottom, Layout.bottomPadding)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Layout.introSpacing) {
            Text(Strings.title)
                .font(.largeTitle.bold())
                .tracking(Layout.titleTracking)
                .foregroundStyle(Palette.primary)
                .accessibilityAddTraits(.isHeader)
            Text(Strings.subtitle)
                .font(.body)
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Layout.introBottomSpacing)
        .opacity(introVisible ? 1 : 0)
        .offset(y: introVisible ? 0 : Layout.introRise)
    }

    private var buttons: some View {
        VStack(spacing: Layout.buttonSpacing) {
            googleButton
            appleButton
            statusLine
        }
    }

    private var googleButton: some View {
        Button { signIn(with: .google) } label: {
            providerLabel(.google, tint: Palette.googleText) {
                HStack(spacing: Layout.googleIconGap) {
                    Image(Strings.googleLogo)
                        .resizable()
                        .frame(width: Layout.googleIconSize, height: Layout.googleIconSize)
                        .accessibilityHidden(true)
                    Text(Strings.google)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.googleText)
            .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(Palette.primary.opacity(Layout.strokeOpacity), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(status.isSigningIn)
    }

    private var appleButton: some View {
        Button { signIn(with: .apple) } label: {
            providerLabel(.apple, tint: .white) {
                HStack(spacing: Layout.appleIconGap) {
                    Image(systemName: "apple.logo")
                    Text(Strings.apple)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
            .background(Capsule().fill(Color.black))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(status.isSigningIn)
    }

    @ViewBuilder
    private func providerLabel<Content: View>(
        _ provider: Provider, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        if status.isSigningIn(provider) {
            ProgressView()
                .tint(tint)
                .accessibilityLabel(Strings.signingIn)
        } else {
            content()
        }
    }

    private func signIn(with provider: Provider) {
        guard !status.isSigningIn else { return }
        status = .signingIn(provider)
        Task {
            do {
                session.login(user: try await provider.signIn())
            } catch {
                status = SocialSignInError.userMessage(for: error).map(SignInStatus.failed) ?? .idle
            }
        }
    }

    private var statusLine: some View {
        Text(status.message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.error)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: Layout.statusMinHeight)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var guestButton: some View {
        Button { session.dismissLogin() } label: {
            HStack(spacing: Layout.guestGap) {
                Text(Strings.guestPrompt).foregroundStyle(Palette.secondary)
                Text(Strings.guest).fontWeight(.semibold).foregroundStyle(Palette.accent)
            }
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: Layout.guestMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressedOpacityStyle())
        .disabled(status.isSigningIn)
        .accessibilityLabel(Strings.guest)
    }

    private var legalNote: some View {
        Text(legalText)
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .tint(Palette.accent)
            .multilineTextAlignment(.center)
            .padding(.top, Layout.legalTopMargin)
            .environment(\.openURL, OpenURLAction { url in
                switch url {
                case LegalLinks.terms: legalPage = .terms
                case LegalLinks.privacyPolicy: legalPage = .privacyPolicy
                default: return .systemAction
                }
                return .handled
            })
    }

    private var legalText: AttributedString {
        var text = AttributedString(Strings.legalPrefix)
        text.append(legalLink(Strings.termsTitle, url: LegalLinks.terms))
        text.append(AttributedString(Strings.legalMiddle))
        text.append(legalLink(Strings.privacyTitle, url: LegalLinks.privacyPolicy))
        text.append(AttributedString(Strings.legalSuffix))
        return text
    }

    private func legalLink(_ title: String, url: URL) -> AttributedString {
        var link = AttributedString(title)
        link.link = url
        link.foregroundColor = Palette.accent
        link.underlineStyle = .single
        return link
    }

    private func showIntro() {
        guard !introVisible else { return }
        guard !reduceMotion else {
            introVisible = true
            return
        }
        withAnimation(.spring(duration: Layout.introDuration, bounce: 0)) { introVisible = true }
    }
}

private struct PressedOpacityStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private enum Palette {
    static let background = Color(hex: "#F2F0E9")!
    static let primary = Color(hex: "#1C2420")!
    static let secondary = Color(hex: "#56605A")!
    static let accent = Color(hex: "#2F5A43")!
    static let error = Color(hex: "#B3261E")!
    static let googleText = Color(hex: "#1F1F1F")!
}

private enum Layout {
    static let heroHeight: CGFloat = 500
    static let imageAspect: CGFloat = 2213.0 / 1652.0
    static let imageFocusX: CGFloat = 0.16
    static let fadeStart: CGFloat = 0.62
    static let fadeMid: CGFloat = 0.86
    static let fadeMidOpacity: Double = 0.85
    static let horizontalPadding: CGFloat = 24
    static let bottomPadding: CGFloat = 8
    static let introSpacing: CGFloat = 10
    static let introBottomSpacing: CGFloat = 28
    static let introRise: CGFloat = 12
    static let introDuration: Double = 0.5
    static let titleTracking: CGFloat = -0.68
    static let buttonSpacing: CGFloat = 12
    static let buttonHeight: CGFloat = 50
    static let googleIconSize: CGFloat = 18
    static let googleIconGap: CGFloat = 10
    static let appleIconGap: CGFloat = 8
    static let strokeOpacity: Double = 0.16
    static let statusMinHeight: CGFloat = 22
    static let guestMinHeight: CGFloat = 44
    static let guestGap: CGFloat = 5
    static let legalTopMargin: CGFloat = 4
}

private enum Strings {
    static let heroImage = "LoginCatTrain"
    static let title = "Your purr-fect commute starts here."
    static let subtitle = "Sign in to sync your saved stops, schedules, and fastest shortcuts in one place."
    static let google = "Continue with Google"
    static let googleLogo = "GoogleLogo"
    static let signingIn = "Signing in"
    static let apple = "Continue with Apple"
    static let guestPrompt = "Just a curious cat?"
    static let guest = "Continue as guest"
    static let legalPrefix = "By continuing, you agree to the "
    static let termsTitle = "Terms of Service"
    static let legalMiddle = " and acknowledge the "
    static let privacyTitle = "Privacy Policy"
    static let legalSuffix = "."
}
