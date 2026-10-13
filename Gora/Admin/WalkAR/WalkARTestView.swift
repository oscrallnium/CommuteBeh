//
//  WalkARTestView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import MapKit
import SwiftUI

/// Admin test screen. Drop a pin, get a walking route, and open AR guidance along it.
struct WalkARTestView: View {
    @State private var picker = WalkRoutePickerModel()
    @State private var isShowingAR = false
    @State private var surveys: [ARSurveySummary] = []
    @State private var surveyID: UUID?

    var body: some View {
        MapReader { proxy in
            Map {
                UserAnnotation()
                if let destination = picker.destination {
                    Marker("Destination", coordinate: destination.clCoordinate).tint(DesignTokens.Colors.action)
                }
                if let route = picker.route {
                    MapPolyline(coordinates: route.polyline.map(\.clCoordinate))
                        .stroke(TransportMode.walk.color, lineWidth: 5)
                }
            }
            .onTapGesture { point in drop(at: point, proxy: proxy) }
            .simultaneousGesture(longPress(proxy: proxy))
        }
        .mapControls { MapUserLocationButton() }
        .safeAreaInset(edge: .bottom) { bottomPanel }
        .navigationTitle("Walk AR Test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { picker.start() }
        .task { await loadSurveys() }
        .onDisappear { picker.stop() }
        .fullScreenCover(isPresented: $isShowingAR, onDismiss: { picker.start() }) {
            if let route = picker.route { WalkARScreen(polyline: route.polyline, surveyID: surveyID) }
        }
    }

    // MARK: Gestures

    private func drop(at point: CGPoint, proxy: MapProxy) {
        guard let coordinate = proxy.convert(point, from: .local) else { return }
        picker.setDestination(Coordinates(lat: coordinate.latitude, lng: coordinate.longitude))
    }

    private func longPress(proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                if case .second(true, let drag?) = value { drop(at: drag.location, proxy: proxy) }
            }
    }

    // MARK: Panel

    private var bottomPanel: some View {
        VStack(spacing: DesignTokens.Space.s) {
            Text(summary)
                .font(DesignTokens.TypeScale.rowTitle)
                .multilineTextAlignment(.center)
            surveyPicker
            Button("Start AR") {
                picker.stop()
                isShowingAR = true
            }
                .font(DesignTokens.TypeScale.controlLabel)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Colors.action)
                .foregroundStyle(Color.licorice)
                .disabled(picker.route == nil)
        }
        .padding(DesignTokens.Space.l)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .padding(DesignTokens.Space.l)
    }

    private var surveyPicker: some View {
        Picker("Survey", selection: $surveyID) {
            Text("None").tag(UUID?.none)
            ForEach(surveys) { survey in
                Text("\(survey.metadata.name) · \(survey.metadata.zoneName)").tag(UUID?.some(survey.id))
            }
        }
        .pickerStyle(.menu)
        .font(DesignTokens.TypeScale.controlLabel)
    }

    private func loadSurveys() async {
        surveys = await Task.detached(priority: .userInitiated) { ARSurveyStore().list() }.value
    }

    private var summary: String {
        if picker.isLoading { return "Finding a walking route" }
        if let route = picker.route {
            return "\(WalkARHUD.format(meters: route.distanceMeters)) · \(Int(route.minutes.rounded())) min walk"
        }
        return picker.message ?? "Tap or press and hold the map to drop a pin"
    }
}

private extension Coordinates {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
