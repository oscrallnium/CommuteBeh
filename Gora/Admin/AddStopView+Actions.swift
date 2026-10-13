//
//  AddStopView+Actions.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/7/26.
//

import SwiftUI
import MapKit

// Placing the stop from a tap, and saving it to the backend.
// These members are internal only because the stored properties they read sit in AddStopView.swift.

extension AddStopView {

    // MARK: - Actions

    /// Places the stop and resolves the reference picker against the segment the tap
    /// landed on — see `StopInsertionPreview.resolveTap`. Never leaves the pickers
    /// untouched: a tap that lands near a spot the route passes twice sets `tapChoice`
    /// instead, so the admin picks explicitly rather than the app either guessing wrong
    /// or doing nothing.
    func place(_ coordinate: CLLocationCoordinate2D) {
        tappedCoordinate = coordinate

        guard let resolution = StopInsertionPreview.resolveTap(
            at: coordinate, stations: orderedStations, edges: chainEdges,
            preferredHeading: resolvedHeading
        ) else {
            tapChoice = nil
            tapTooFarFromRoute = true
            return
        }

        tapTooFarFromRoute = false
        referenceStationId = resolution.chosen.station.id
        position = "after"
        tapChoice = resolution.alternative != nil ? resolution : nil
    }

    func save() async {
        guard let placedCoordinate else { return }
        isSaving = true
        errorMessage = nil
        var payload: [String: Any] = [
            "referenceStationId": referenceStationId,
            "position": position,
            "name": name.trimmingCharacters(in: .whitespaces),
            "lat": placedCoordinate.latitude,
            "lng": placedCoordinate.longitude
        ]

        // A head/tail insert has no existing segment to slice, so unless the road route is
        // sent the new edge is written with an empty polyline — which is what left
        // UPLB_KANAN_SEG8 (Animal Science → CEAT) with 0 waypoints. A mid-chain insert
        // needs nothing: the server splits the existing recorded polyline.
        //
        // Post exactly the geometry the preview drew (`preview.newPolylines`, already
        // end-pinned) rather than re-fetching — what was approved on screen is what gets
        // written, and a second fetch could quietly return something else.
        if !neededChords(for: placedCoordinate).isEmpty {
            let drawn = (preview?.newPolylines ?? []).filter(\.isFetched)
            // 2, not 3 — matches the floor `refreshRoadGeometry` already fetched under;
            // a route that was good enough to preview is good enough to save.
            if drawn.count == neededChords(for: placedCoordinate).count,
               drawn.allSatisfy({ $0.coordinates.count >= 2 }) {
                payload["newEdgePolylines"] = drawn.map { poly in
                    poly.coordinates.map { ["lat": $0.lat, "lng": $0.lng] }
                }
            } else if !allowSaveWithoutGeometry {
                // Don't quietly write the straight chord this whole change exists to avoid.
                // The admin can override on the next tap — data entry shouldn't be blocked
                // by a transient MapKit failure, but it should be a decision, not a default.
                allowSaveWithoutGeometry = true
                errorMessage = "No road route for the new segment yet. Tap Save again to add the stop without it — the segment will draw nothing until you snap it in the edge editor."
                isSaving = false
                return
            }
        }

        do {
            try await onSave(payload)
            dismiss()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch is URLError {
            // The request can reach the server after the client stops waiting, so the stop
            // may exist. The server returns the existing stop for a repeated insert.
            errorMessage = "The server didn't answer in time, so the stop may already be saved. Tap Add Stop again — it won't add a second copy."
        } catch {
            errorMessage = "Failed to add stop."
        }
        isSaving = false
    }
}
