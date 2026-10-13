//
//  ARSurveyModels.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI
import simd

// MARK: - Sign kind

nonisolated enum ARSignKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case exit, entrance, stairs, escalator, elevator, platform, information

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exit: "Exit"
        case .entrance: "Entrance"
        case .stairs: "Stairs"
        case .escalator: "Escalator"
        case .elevator: "Elevator"
        case .platform: "Platform"
        case .information: "Information"
        }
    }

    var symbolName: String {
        switch self {
        case .exit: "door.left.hand.open"
        case .entrance: "arrow.right.to.line"
        case .stairs: "figure.stairs"
        case .escalator: "escalator"
        case .elevator: "arrow.up.arrow.down.square"
        case .platform: "tram.fill"
        case .information: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .exit: Color.vermilion
        case .entrance: Color.jade
        case .stairs: Color.slate
        case .escalator: Color.ember
        case .elevator: Color.lagoon
        case .platform: Color.onyx
        case .information: Color.tangerine
        }
    }
}

nonisolated enum ARLightCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case day, dusk, night, artificial

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

// MARK: - Metadata (the `metadata` part of POST /api/v1/ar/surveys)

nonisolated struct ARSurveyNode: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// Equals `ARAnchor.name`, in the form `node_<uuid>`.
    let anchorIdentifier: String
    var label: String
    var kind: ARSignKind
    /// Clockwise from above, 0 = world -Z, around the world-up axis. `nil` means no arrow.
    var arrowHeadingDegrees: Double?

    init(id: UUID = UUID(), label: String, kind: ARSignKind, arrowHeadingDegrees: Double? = nil) {
        self.id = id
        self.anchorIdentifier = Self.anchorName(for: id)
        self.label = label
        self.kind = kind
        self.arrowHeadingDegrees = arrowHeadingDegrees
    }

    static let anchorPrefix = "node_"

    static func anchorName(for id: UUID) -> String { anchorPrefix + id.uuidString }
}

nonisolated struct ARSurveyEdge: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let fromNodeId: UUID
    let toNodeId: UUID
}

nonisolated struct ARSurveyDestination: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let nodeId: UUID
    let name: String
}

nonisolated struct ARSurveyImageAnchor: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let physicalWidth: Double
    /// The image pose in the survey world frame: 16 values, column-major. +Y is the image normal.
    let transform: [Float]
    /// The image file in the survey folder. Empty when the metadata lists no file.
    let fileName: String

    init(id: UUID = UUID(), name: String, physicalWidth: Double, transform: simd_float4x4, fileName: String) {
        self.id = id
        self.name = name
        self.physicalWidth = physicalWidth
        self.transform = transform.columnMajorValues
        self.fileName = fileName
    }

    /// The pose as a matrix, or `nil` when `transform` does not hold 16 values.
    var poseTransform: simd_float4x4? {
        guard transform.count == 16 else { return nil }
        return simd_float4x4(columns: (
            SIMD4(transform[0], transform[1], transform[2], transform[3]),
            SIMD4(transform[4], transform[5], transform[6], transform[7]),
            SIMD4(transform[8], transform[9], transform[10], transform[11]),
            SIMD4(transform[12], transform[13], transform[14], transform[15])))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, physicalWidth, transform, fileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        physicalWidth = try container.decode(Double.self, forKey: .physicalWidth)
        transform = try container.decodeIfPresent([Float].self, forKey: .transform) ?? []
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
    }
}

extension simd_float4x4 {
    /// The 16 values in column order.
    nonisolated var columnMajorValues: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}

nonisolated struct ARCaptureContext: Codable, Hashable, Sendable {
    var deviceModel: String
    var iosVersion: String
    var lightCondition: ARLightCondition
    /// One of `not_available`, `limited`, `extending`, `mapped`.
    var worldMappingQuality: String
    var featurePointCount: Int
    /// Compressed size of `worldmap.bin`.
    var sizeBytes: Int
}

nonisolated struct ARSurveyMetadata: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var zoneName: String
    /// The client always sends `pending`.
    var status: String
    let createdAt: Date
    var updatedAt: Date
    var captureContext: ARCaptureContext
    var nodes: [ARSurveyNode]
    var edges: [ARSurveyEdge]
    var destinations: [ARSurveyDestination]
    var imageAnchors: [ARSurveyImageAnchor]

    static let pendingStatus = "pending"

    static func new(name: String, zoneName: String, light: ARLightCondition,
                    deviceModel: String, iosVersion: String) -> ARSurveyMetadata {
        let now = Date()
        return ARSurveyMetadata(
            id: UUID(), name: name, zoneName: zoneName, status: pendingStatus,
            createdAt: now, updatedAt: now,
            captureContext: ARCaptureContext(
                deviceModel: deviceModel, iosVersion: iosVersion, lightCondition: light,
                worldMappingQuality: "not_available", featurePointCount: 0, sizeBytes: 0),
            nodes: [], edges: [], destinations: [], imageAnchors: [])
    }
}

// MARK: - JSON coding

nonisolated enum ARSurveyCoding {
    /// Snake_case keys and ISO 8601 dates, to match the Rails API.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
