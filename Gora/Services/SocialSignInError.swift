//
//  SocialSignInError.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import Foundation

enum SocialSignInError: Error {
    case cancelled
    case failed

    /// Returns nil when the person cancelled, so the UI shows no alert.
    static func userMessage(for error: Error) -> String? {
        if let socialError = error as? SocialSignInError {
            switch socialError {
            case .cancelled: return nil
            case .failed:    return fallbackMessage
            }
        }
        if let apiError = error as? APIError { return apiError.userMessage }
        return fallbackMessage
    }

    private static let fallbackMessage = "Sign-in didn't work. Please try again."
}
