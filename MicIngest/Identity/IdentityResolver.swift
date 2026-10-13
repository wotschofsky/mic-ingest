import Foundation

/// A person the app knows across recordings. Distinct from a diarized cluster and from a display name.
struct Person: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var createdAt: Date
    /// Path of the library folder this person belongs to. People, and their voice profiles, are
    /// kept per library, so a library shared with someone else never carries people from another one.
    var library = ""
}

/// Why an embedding was allowed into a person's voice profile.
enum EmbeddingProvenance: String, Codable {
    case manualConfirmation = "manual_confirmation"
    case explicitSelfIdentification = "explicit_self_identification"
    case highConfidenceVoiceMatch = "high_confidence_voice_match"
}

enum ManualDecision: Equatable {
    case person(String)
    case unidentified
}

/// Everything known about one diarized speaker when resolving its identity.
struct ResolverInput {
    var label: String
    var manual: ManualDecision?
    /// nil when the cluster had too little clean speech to compare.
    var voice: VoiceMatch?
    var finding: NameFinding?
    /// Start time of each utterance the finding cites, keyed by utterance index.
    var utteranceStartMs: [Int: Int] = [:]
}

struct Resolution: Equatable {
    enum Outcome: Equatable {
        case unidentified
        case person(String)
        /// Explicit self-identification of someone not yet known: create them.
        case newPerson(name: String)
    }

    var outcome: Outcome
    var state: IdentityState
    var confidence: String?
    var evidence: [IdentityEvidence]
    /// Set when this cluster's voice may be added to the person's profile, with the reason.
    var enrollment: EmbeddingProvenance?
}

/// Combines manual decisions, voice similarity and transcript evidence into one identity per speaker.
/// Bias: a wrong name is much worse than no name, so anything short of clear evidence stays unidentified.
struct IdentityResolver {
    var people: [Person]
    /// People who already have voice samples for the current embedding model.
    var peopleWithVoiceProfile: Set<String>
    var thresholds: VoiceThresholds

    private func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }

    /// A known person with exactly this name; nil if there is none or the name is ambiguous.
    func person(named name: String) -> Person? {
        let matches = people.filter { key($0.displayName) == key(name) }
        return matches.count == 1 ? matches[0] : nil
    }

    func resolve(_ input: ResolverInput) -> Resolution {
        let best = input.voice?.best
        let band = input.voice?.band ?? .unknown
        let finding = input.finding?.suggestedName == nil ? nil : input.finding
        let named = finding?.suggestedName.flatMap(person(named:))

        // Collect all evidence first; `applied` is set once the outcome is known.
        var evidence: [IdentityEvidence] = []
        if let best, band != .unknown {
            evidence.append(IdentityEvidence(source: .voiceMatch, applied: false, personID: best.personID,
                                             similarity: (best.similarity * 1000).rounded() / 1000, band: band.rawValue))
        }
        if let finding, let name = finding.suggestedName {
            for item in finding.evidence {
                let index = Int(item.utteranceId.dropFirst())
                evidence.append(IdentityEvidence(
                    source: finding.basis == .selfIdentification ? .selfIdentification : .transcriptContext,
                    applied: false, personID: named?.id, name: name, confidence: finding.confidence.rawValue,
                    utteranceIndex: index, timestampMs: index.flatMap { input.utteranceStartMs[$0] },
                    quote: item.quote, reason: item.reason))
            }
        }

        func result(_ outcome: Resolution.Outcome, _ state: IdentityState, confidence: String? = nil,
                    applying sources: Set<EvidenceSource> = [], enrollment: EmbeddingProvenance? = nil) -> Resolution {
            var evidence = evidence
            for index in evidence.indices { evidence[index].applied = sources.contains(evidence[index].source) }
            return Resolution(outcome: outcome, state: state, confidence: confidence, evidence: evidence, enrollment: enrollment)
        }
        let transcriptSources: Set<EvidenceSource> = [.selfIdentification, .transcriptContext]

        // 1. The user's decision overrides everything automatic.
        switch input.manual {
        case .person(let id):
            var resolution = result(.person(id), .manual, enrollment: .manualConfirmation)
            resolution.evidence.insert(IdentityEvidence(source: .manual, applied: true, personID: id), at: 0)
            return resolution
        case .unidentified:
            return result(.unidentified, .manualUnidentified)
        case nil:
            break
        }

        let explicit = finding?.isExplicitSelfIdentification == true
        let transcriptAgrees = named != nil && named?.id == best?.personID && (finding?.confidence ?? .low) >= .medium

        // 2. Strong voice match.
        if let best, band == .strong {
            if explicit, !transcriptAgrees {
                // The voice says one person, the speaker says they are someone else. Trust neither.
                return result(.unidentified, .unidentified)
            }
            if transcriptAgrees {
                return result(.person(best.personID), .automatic, confidence: "very_high",
                              applying: transcriptSources.union([.voiceMatch]),
                              enrollment: explicit ? .explicitSelfIdentification
                                  : best.similarity >= thresholds.enroll ? .highConfidenceVoiceMatch : nil)
            }
            return result(.person(best.personID), .automatic, confidence: "high", applying: [.voiceMatch],
                          enrollment: best.similarity >= thresholds.enroll ? .highConfidenceVoiceMatch : nil)
        }

        // 3. Borderline voice match: only with independent transcript evidence for the same person.
        if let best, band == .borderline, transcriptAgrees {
            return result(.person(best.personID), .automatic, confidence: explicit ? "high" : "medium",
                          applying: transcriptSources.union([.voiceMatch]),
                          enrollment: explicit ? .explicitSelfIdentification : nil)
        }

        // 4. The speaker explicitly said who they are.
        if explicit, let name = finding?.suggestedName {
            guard let named else {
                // Nobody known by that name (or several): a new person, if the name is not ambiguous.
                let ambiguous = people.contains { key($0.displayName) == key(name) }
                return ambiguous ? result(.unidentified, .unidentified)
                    : result(.newPerson(name: name), .automatic, confidence: "high",
                             applying: [.selfIdentification], enrollment: .explicitSelfIdentification)
            }
            // A known person of that name whose stored voice did not match: accept the name the
            // speaker gave, but keep this audio out of the existing profile.
            let hasProfile = peopleWithVoiceProfile.contains(named.id)
            return result(.person(named.id), .automatic, confidence: hasProfile ? "medium" : "high",
                          applying: [.selfIdentification], enrollment: hasProfile ? nil : .explicitSelfIdentification)
        }

        // 5. Closest voice, a mention, an address: not enough. The speaker stays unidentified.
        return result(.unidentified, .unidentified)
    }
}
