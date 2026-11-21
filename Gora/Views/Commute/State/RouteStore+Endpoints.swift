//
//  RouteStore+Endpoints.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/6/26.
//

import Foundation

// MARK: - Endpoint actions
// These methods change model state only. Focus and camera changes stay in the views.

extension RouteStore {

    /// Empties one search field and drops its confirmed place and suggestions.
    func clear(_ field: SearchField) {
        switch field {
        case .origin:
            originText = ""
            originID = ""
            originCoordinate = nil
            confirmedOriginLabel = nil
            lastOriginQuery = ""
            originDebounce?.cancel()
            originSuggestions = []
            showOriginSuggestions = false
        case .destination:
            destinationText = ""
            destinationID = ""
            destinationCoordinate = nil
            confirmedDestLabel = nil
            lastDestQuery = ""
            destDebounce?.cancel()
            destSuggestions = []
            showDestSuggestions = false
        }
    }

    /// Exchanges the origin and the destination, with their text, labels, and coordinates.
    func swapEndpoints() {
        let tempText  = originText
        let tempID    = originID
        let tempCoord = originCoordinate
        let tempLabel = confirmedOriginLabel

        originText              = destinationText
        originID                = destinationID
        originCoordinate        = destinationCoordinate
        confirmedOriginLabel    = confirmedDestLabel

        destinationText         = tempText
        destinationID           = tempID
        destinationCoordinate   = tempCoord
        confirmedDestLabel      = tempLabel

        if originID == RouteRequest.virtualDestID       { originID = RouteRequest.virtualOriginID }
        if destinationID == RouteRequest.virtualOriginID { destinationID = RouteRequest.virtualDestID }

        originDebounce?.cancel()
        destDebounce?.cancel()
        lastOriginQuery       = ""
        lastDestQuery         = ""
        showOriginSuggestions = false
        showDestSuggestions   = false
        originSuggestions     = []
        destSuggestions       = []
    }

    /// Confirms `suggestion` for `field` and sets the field text.
    /// Returns true when the selection applied. An address that fails to resolve returns false.
    func select(_ suggestion: LocationSuggestion, for field: SearchField) async -> Bool {
        switch (suggestion, field) {
        case (.station(let station), .origin):
            confirmOriginStation(station)
            originText = station.name
            return true
        case (.station(let station), .destination):
            confirmDestinationStation(station)
            destinationText = station.name
            return true
        case (.address(let completion), .origin):
            guard let name = await confirmOriginAddress(completion) else { return false }
            originText = name
            return true
        case (.address(let completion), .destination):
            guard let name = await confirmDestinationAddress(completion) else { return false }
            destinationText = name
            return true
        }
    }

    /// Confirms the saved place for `field` and sets the field text. It starts no search.
    func fill(_ field: SearchField, with place: SavedPlace) {
        switch field {
        case .origin:
            originDebounce?.cancel()
            setOriginCoordinate(place.coordinates)
            confirmedOriginLabel = place.name
            originSuggestions = []
            showOriginSuggestions = false
            originText = place.name
        case .destination:
            destDebounce?.cancel()
            setDestinationCoordinate(place.coordinates)
            confirmedDestLabel = place.name
            destSuggestions = []
            showDestSuggestions = false
            destinationText = place.name
        }
    }

    /// Hides the route results and keeps the origin and the destination.
    func closeResults() {
        routeResult = nil
        routeOptions = []
        errorMessage = nil
    }
}
