//
//  StateRepository.swift
//

import Foundation
import os

final class StateRepository {
    enum LoadResult: Equatable {
        case missing
        case loaded(AppState)
        /// Unreadable, undecodable or breaking the data-model rules: prompt a fresh start, never restore from it.
        case corrupt
    }

    static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FocusTimeScrambler/state.json")

    let fileURL: URL
    private let log = Logger(subsystem: "scramble.time-scramble", category: "StateRepository")

    init(fileURL: URL = StateRepository.defaultURL) {
        self.fileURL = fileURL
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            let state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: fileURL))
            guard state.isValid else {
                log.error("state.json breaks the data-model rules")
                return .corrupt
            }
            return .loaded(state)
        } catch {
            log.error("state.json unreadable: \(String(describing: error), privacy: .public)")
            return .corrupt
        }
    }

    /// Atomic: `.atomic` writes a temporary file and renames it over the target, so a crash never leaves half a file.
    func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
