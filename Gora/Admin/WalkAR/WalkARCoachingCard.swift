//
//  WalkARCoachingCard.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

/// Tells the passenger where to point the camera so the survey can relocalize.
struct WalkARCoachingCard: View {
    let survey: ARSurveyMetadata?

    private var anchors: [ARSurveyImageAnchor] {
        survey?.imageAnchors.filter { !$0.fileName.isEmpty } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            HStack(spacing: DesignTokens.Space.m) {
                if let survey, let first = anchors.first {
                    WalkARSignThumbnail(surveyID: survey.id, fileName: first.fileName, side: 72)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                    Text(title).font(DesignTokens.TypeScale.instructionCompact)
                    if let captureLine { captionText(captureLine) }
                }
                Spacer(minLength: 0)
            }
            if let survey, anchors.count > 1 { otherSigns(survey: survey) }
        }
        .foregroundStyle(.white)
        .padding(DesignTokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var title: String {
        guard let first = anchors.first else { return "Stand where the survey was scanned and face the same way." }
        return "Point your camera at the \(first.name) sign."
    }

    /// For example "Scanned at dusk, 18 hours ago".
    private var captureLine: String? {
        guard let survey else { return nil }
        let age = RelativeDateTimeFormatter().localizedString(for: survey.updatedAt, relativeTo: Date())
        return "Scanned \(survey.captureContext.lightCondition.scanPhrase), \(age)"
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeScale.subtitle)
            .foregroundStyle(.white.opacity(0.7))
    }

    private func otherSigns(survey: ARSurveyMetadata) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Space.s) {
                ForEach(anchors.dropFirst()) { anchor in
                    VStack(spacing: DesignTokens.Space.xxs) {
                        WalkARSignThumbnail(surveyID: survey.id, fileName: anchor.fileName, side: 48)
                        Text(anchor.name)
                            .font(DesignTokens.TypeScale.meta)
                            .lineLimit(1)
                            .frame(maxWidth: 64)
                    }
                }
            }
        }
    }
}

private extension ARLightCondition {
    var scanPhrase: String {
        switch self {
        case .day: "in daylight"
        case .dusk: "at dusk"
        case .night: "at night"
        case .artificial: "under artificial light"
        }
    }
}

/// A sign image that loads off the main actor. A placeholder shows until the image loads.
private struct WalkARSignThumbnail: View {
    let surveyID: UUID
    let fileName: String
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.15)
                Image(systemName: "photo").foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        .task(id: fileName) { image = await Self.load(surveyID: surveyID, fileName: fileName) }
    }

    private static func load(surveyID: UUID, fileName: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            (try? ARSurveyStore().loadImage(surveyID: surveyID, fileName: fileName)).map { UIImage(cgImage: $0) }
        }.value
    }
}
