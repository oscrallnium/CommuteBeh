//
//  ARSurveyStore.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One saved survey as the list shows it.
nonisolated struct ARSurveySummary: Identifiable, Hashable, Sendable {
    let metadata: ARSurveyMetadata
    let warnings: [String]
    let errors: [String]

    var id: UUID { metadata.id }
}

nonisolated struct ARSurveyValidation: Sendable {
    var warnings: [String] = []
    var errors: [String] = []
}

/// Application Support/ARSurveys/<id>/ holds `metadata.json`, `worldmap.bin` and the sign image files.
/// Each folder is the payload for `POST /api/v1/ar/surveys`.
nonisolated struct ARSurveyStore: Sendable {
    static let minimumFeaturePoints = 500
    static let warningBytes = 10 * 1_000_000
    static let errorBytes = 25 * 1_000_000

    private let metadataName = "metadata.json"
    private let worldMapName = "worldmap.bin"

    private var rootURL: URL {
        URL.applicationSupportDirectory.appending(path: "ARSurveys", directoryHint: .isDirectory)
    }

    private func folder(for id: UUID) -> URL {
        rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    // MARK: Read

    func list() -> [ARSurveySummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? loadMetadata(in: $0) }
            .map { summary(for: $0) }
            .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
    }

    func loadMetadata(id: UUID) throws -> ARSurveyMetadata {
        try loadMetadata(in: folder(for: id))
    }

    /// Returns the decompressed `NSKeyedArchiver` data of the world map.
    func loadWorldMapData(id: UUID) throws -> Data {
        let compressed = try Data(contentsOf: folder(for: id).appending(path: worldMapName))
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }

    /// Decompresses and unarchives the saved world map. Call it off the main actor.
    func loadWorldMap(id: UUID) throws -> ARWorldMap {
        let archive = try loadWorldMapData(id: id)
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: archive) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return map
    }

    /// Reads one sign image file. Call it off the main actor.
    func loadImage(surveyID: UUID, fileName: String) throws -> CGImage {
        let url = folder(for: surveyID).appending(path: fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    /// Encodes an image as PNG data for `save`.
    static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private func loadMetadata(in folder: URL) throws -> ARSurveyMetadata {
        let data = try Data(contentsOf: folder.appending(path: metadataName))
        return try ARSurveyCoding.makeDecoder().decode(ARSurveyMetadata.self, from: data)
    }

    // MARK: Write

    /// Compresses the archive, fills `sizeBytes`, and writes the metadata, the world map and the
    /// new image files (keyed by file name). Returns the saved metadata.
    func save(_ metadata: ARSurveyMetadata, worldMapArchive: Data,
              images: [String: Data] = [:]) throws -> ARSurveyMetadata {
        let compressed = try (worldMapArchive as NSData).compressed(using: .zlib) as Data
        var saved = metadata
        saved.captureContext.sizeBytes = compressed.count
        saved.status = ARSurveyMetadata.pendingStatus
        saved.updatedAt = Date()

        let directory = folder(for: saved.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try compressed.write(to: directory.appending(path: worldMapName), options: .atomic)
        for (fileName, data) in images {
            try data.write(to: directory.appending(path: fileName), options: .atomic)
        }
        let json = try ARSurveyCoding.makeEncoder().encode(saved)
        try json.write(to: directory.appending(path: metadataName), options: .atomic)
        return saved
    }

    func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }

    // MARK: Validation

    func summary(for metadata: ARSurveyMetadata) -> ARSurveySummary {
        let result = validate(metadata)
        return ARSurveySummary(metadata: metadata, warnings: result.warnings, errors: result.errors)
    }

    /// Runs the server checks of the upload endpoint on the local copy.
    func validate(_ metadata: ARSurveyMetadata) -> ARSurveyValidation {
        var result = ARSurveyValidation()
        let context = metadata.captureContext

        if context.worldMappingQuality != "mapped" {
            result.errors.append("The scan is not fully mapped.")
        }
        if context.featurePointCount < Self.minimumFeaturePoints {
            result.errors.append("The scan has fewer than \(Self.minimumFeaturePoints) feature points.")
        }
        if context.sizeBytes > Self.errorBytes {
            result.errors.append("The world map is larger than 25 MB.")
        } else if context.sizeBytes > Self.warningBytes {
            result.warnings.append("The world map is larger than 10 MB.")
        }

        let nodeIDs = Set(metadata.nodes.map(\.id))
        if metadata.edges.contains(where: { !nodeIDs.contains($0.fromNodeId) || !nodeIDs.contains($0.toNodeId) }) {
            result.errors.append("An edge points to a sign that does not exist.")
        }
        if metadata.destinations.contains(where: { !nodeIDs.contains($0.nodeId) }) {
            result.errors.append("A destination points to a sign that does not exist.")
        }
        if metadata.imageAnchors.contains(where: { $0.physicalWidth <= 0 }) {
            result.errors.append("An image anchor has no physical width.")
        }
        let directory = folder(for: metadata.id)
        let missingFile = metadata.imageAnchors.contains {
            $0.fileName.isEmpty || !FileManager.default.fileExists(atPath: directory.appending(path: $0.fileName).path)
        }
        if missingFile {
            result.errors.append("An image anchor has no image file.")
        }
        return result
    }
}
