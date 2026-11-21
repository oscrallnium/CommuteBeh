//
//  SearchFieldAccessory.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/8/26.
//

import SwiftUI

/// The trailing slot of a search field row: a spinner while resolving, a clear button when the
/// field has text, otherwise empty. The slot size is fixed, so the row height never changes.
struct SearchFieldAccessory: View {
    let isResolving: Bool
    let hasText: Bool
    let onClear: () -> Void

    var body: some View {
        Group {
            if isResolving {
                ProgressView().controlSize(.small)
            } else if hasText {
                Button(action: onClear) {
                    Image(systemName: Symbol.clear)
                        .foregroundStyle(.tertiary)
                        .frame(width: Layout.size, height: Layout.size)
                        .contentShape(Rectangle().inset(by: Layout.hitInset))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: Layout.size, height: Layout.size)
    }
}

private enum Layout {
    static let size: CGFloat = 22
    /// A negative inset grows the hit area to 44 pt.
    static let hitInset: CGFloat = -11
}

private enum Symbol {
    static let clear = "xmark.circle.fill"
}
