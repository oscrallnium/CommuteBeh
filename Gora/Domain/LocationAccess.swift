//
//  LocationAccess.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/19/26.
//

import CoreLocation

/// Whether the rider lets Gora read the phone location.
/// `off` covers Don't Allow, a restricted phone, and Location Services turned off for the whole phone.
enum LocationAccess {
    case undetermined
    case allowed
    case off

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: self = .allowed
        case .denied, .restricted: self = .off
        case .notDetermined: self = .undetermined
        @unknown default: self = .undetermined
        }
    }
}
