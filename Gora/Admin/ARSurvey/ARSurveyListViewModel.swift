//
//  ARSurveyListViewModel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import Observation

@MainActor
@Observable
final class ARSurveyListViewModel {
    private(set) var surveys: [ARSurveySummary] = []
    var errorMessage: String?

    @ObservationIgnored private let store = ARSurveyStore()

    func reload() async {
        let store = store
        surveys = await Task.detached(priority: .userInitiated) { store.list() }.value
    }

    func delete(_ survey: ARSurveySummary) async {
        let store = store
        let id = survey.id
        do {
            try await Task.detached(priority: .userInitiated) { try store.delete(id: id) }.value
            await reload()
        } catch {
            errorMessage = "The survey could not be deleted."
        }
    }
}
