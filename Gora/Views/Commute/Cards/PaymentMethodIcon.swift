//
//  PaymentMethodIcon.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/13/26.
//

import SwiftUI
import UIKit

// MARK: - Payment Method Icon

/// The icon of one payment method. A brand image named "payment.<id>" fills the badge.
/// A symbol named "payment.<id>" or the config's SF Symbol draws small and centered.
/// A color named "payment.<id>.tint" tints a symbol, and "payment.<id>.background" fills the badge.
struct PaymentMethodIcon: View {
    let paymentID: String
    /// The config that the caller passes. A view outside the Commute tab passes it, because
    /// only the Commute tab provides `RouteStore`.
    private let givenConfig: PaymentMethodConfig?
    /// Optional, because a non-optional environment object stops the app where no ancestor provides it.
    @Environment(RouteStore.self) private var routeStore: RouteStore?
    @ScaledMetric private var size: CGFloat

    init(paymentID: String) {
        self.paymentID = paymentID
        givenConfig = nil
        _size = ScaledMetric(wrappedValue: Layout.height, relativeTo: .subheadline)
    }

    init(config: PaymentMethodConfig) {
        paymentID = config.id
        givenConfig = config
        _size = ScaledMetric(wrappedValue: Layout.height, relativeTo: .subheadline)
    }

    /// The badge is card-shaped (16:9) because the brand images are wide.
    /// A symbol fills `symbolFraction` of the badge height and sits at the center.
    private enum Layout {
        static let height: CGFloat = 26
        static let aspect: CGFloat = 16.0 / 9.0
        static let symbolFraction: CGFloat = 0.6
        static let customSymbolWidthFraction: CGFloat = 0.7
        static let badgeRadius: CGFloat = 4
    }

    private var badge: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.badgeRadius, style: .continuous)
    }

    private var config: PaymentMethodConfig? { givenConfig ?? routeStore?.paymentConfig(paymentID) }

    var body: some View {
        icon
            .frame(width: size * Layout.aspect, height: size)
            .background(PaymentIconCatalog.background(forPaymentID: paymentID) ?? Color.haze, in: badge)
            .clipShape(badge)
            .accessibilityLabel(config?.displayName ?? paymentID)
    }

    @ViewBuilder
    private var icon: some View {
        switch PaymentIconCatalog.source(forPaymentID: paymentID, symbol: config?.sfSymbol) {
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
        case .customSymbol(let name):
            tinted(Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: size * Layout.aspect * Layout.customSymbolWidthFraction,
                       height: size * Layout.symbolFraction))
        case .symbol(let name):
            tinted(Image(systemName: name)
                .resizable()
                .scaledToFit()
                .frame(width: size * Layout.symbolFraction, height: size * Layout.symbolFraction))
        }
    }

    /// Applies the payment tint when one exists. Otherwise the caller's foreground style stays.
    @ViewBuilder
    private func tinted(_ symbol: some View) -> some View {
        if let tint = PaymentIconCatalog.tint(forPaymentID: paymentID) {
            symbol.foregroundStyle(tint)
        } else {
            symbol
        }
    }
}

// MARK: - Icon source

/// Decides once per payment ID whether a brand image or a symbol draws the icon.
/// Also looks up the optional tint and badge colors of the payment ID.
private enum PaymentIconCatalog {
    enum Source {
        case asset(String)
        case customSymbol(String)
        case symbol(String)
    }

    private enum Names {
        static let assetPrefix = "payment."
        static let tintSuffix = ".tint"
        static let backgroundSuffix = ".background"
        static let fallbackSymbol = "creditcard"
    }

    private static var cache: [String: Source] = [:]
    private static var colorCache: [String: Color?] = [:]

    static func tint(forPaymentID id: String) -> Color? {
        color(named: Names.assetPrefix + id + Names.tintSuffix)
    }

    static func background(forPaymentID id: String) -> Color? {
        color(named: Names.assetPrefix + id + Names.backgroundSuffix)
    }

    private static func color(named name: String) -> Color? {
        if let cached = colorCache[name] { return cached }
        let color = UIColor(named: name).map { Color(uiColor: $0) }
        colorCache[name] = color
        return color
    }

    static func source(forPaymentID id: String, symbol: String?) -> Source {
        let key = "\(id)|\(symbol ?? "")"
        if let cached = cache[key] { return cached }
        let assetName = Names.assetPrefix + id
        let source: Source
        if let image = UIImage(named: assetName) {
            source = image.isSymbolImage ? .customSymbol(assetName) : .asset(assetName)
        } else if let symbol, !symbol.isEmpty, UIImage(systemName: symbol) != nil {
            source = .symbol(symbol)
        } else {
            source = .symbol(Names.fallbackSymbol)
        }
        cache[key] = source
        return source
    }
}
