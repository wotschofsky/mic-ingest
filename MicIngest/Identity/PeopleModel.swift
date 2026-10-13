import Foundation
import Observation

/// The people of the current library and their voice profiles, for menus and Settings. Edits ripple
/// into every session that references the person (metadata and Markdown are regenerated, nothing is retranscribed).
@MainActor
@Observable
final class PeopleModel {
    private(set) var people: [Person] = []
    private(set) var sampleCounts: [String: Int] = [:]

    private let database: AppDatabase
    private let identity: IdentityService
    private let settings: AppSettings
    private var observation: Task<Void, Never>?

    init(database: AppDatabase, identity: IdentityService, settings: AppSettings) {
        self.database = database
        self.identity = identity
        self.settings = settings
        reload()
        observation = Task { [weak self] in
            do {
                for try await _ in database.observeVoiceProfiles() {
                    self?.reload()
                    self?.writeToLibrary()
                }
            } catch {
                Log.persistence.error("People observation ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reads the current library's people. Also called when the current library changes.
    func reload() {
        people = (try? database.people(in: settings.destination?.path)) ?? []
        sampleCounts = (try? database.voiceSampleCounts()) ?? [:]
    }

    func person(id: String?) -> Person? { people.first { $0.id == id } }

    /// Keeps `People.json` in the library folder current, wherever a change came from
    /// (an import, a manual assignment, Settings).
    private func writeToLibrary() {
        guard let folder = settings.destination else { return }
        do { try LibraryFolder(root: folder).writePeople(from: database) } catch {
            Log.persistence.error("Could not write people to the library: \(error.localizedDescription, privacy: .public)")
        }
    }

    func create(named name: String) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        defer { reload() }
        return try? database.createPerson(named: trimmed, library: settings.destination?.path ?? "")
    }

    func rename(_ person: Person, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != person.displayName else { return }
        try? database.rename(personID: person.id, to: trimmed)
        propagate()
    }

    /// Removes the person and all of their voice data. Their speakers become unidentified again.
    func delete(_ person: Person) {
        try? database.deletePerson(id: person.id)
        propagate()
    }

    /// Removes only the stored voice embeddings; the person and existing assignments stay.
    func removeVoiceData(_ person: Person) {
        try? database.deleteVoiceSamples(personID: person.id)
        reload()
    }

    private func propagate() {
        reload()
        let store = SessionStore(database: database)
        // Checked against everyone, not just the current library: sessions elsewhere keep their people.
        let everyone = (try? database.people()) ?? []
        for var session in (try? database.sessions()) ?? [] {
            guard let metadata = try? store.metadata(for: session),
                  let updated = identity.refreshed(metadata, people: everyone) else { continue }
            do {
                try store.save(updated, for: &session)
                if let transcript = try? store.transcript(for: session) {
                    try store.writeMarkdown(transcript: transcript, metadata: updated, for: session)
                }
            } catch {
                // Destination folder offline: the database copy is updated, the files follow on next edit.
                session.metadataJSON = try? updated.encoded()
                try? database.save(session)
            }
        }
    }
}
