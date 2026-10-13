import Foundation
import Accelerate

/// Cosine-similarity bands for the bundled embedding model, measured on German speech
/// (docs/SPEAKER_EMBEDDINGS.md has the numbers); adjustable under Settings → Advanced.
struct VoiceThresholds: Codable, Equatable {
    /// At or above: the voice alone identifies the person.
    var strong: Double
    /// At or above: an automatic match may also be added to the person's voice profile.
    var enroll: Double
    /// Lower bound of the ambiguous band. Between this and `strong` a voice match only counts
    /// when independent transcript evidence names the same person. Below it: unknown.
    var borderline: Double
    /// Required lead over the second-closest known person for a strong match.
    var margin: Double

    /// With these values no unenrolled speaker was auto-identified in any measured condition
    /// (highest impostor score 0.76); the price is that distant or noisy speech is often missed.
    static let `default` = VoiceThresholds(strong: 0.78, enroll: 0.82, borderline: 0.50, margin: 0.10)
}

enum VoiceBand: String, Codable {
    case strong, borderline, unknown
}

struct VoiceCandidate: Equatable {
    var personID: String
    var similarity: Double
}

/// Outcome of comparing one diarized cluster with every known voice profile.
struct VoiceMatch: Equatable {
    /// All known people, closest first.
    var candidates: [VoiceCandidate]
    var band: VoiceBand

    var best: VoiceCandidate? { candidates.first }
    func similarity(to personID: String) -> Double? { candidates.first { $0.personID == personID }?.similarity }
}

enum VoiceMatcher {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b), normA = vDSP.sumOfSquares(a).squareRoot(), normB = vDSP.sumOfSquares(b).squareRoot()
        return normA > 0 && normB > 0 ? Double(dot / (normA * normB)) : 0
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vDSP.sumOfSquares(vector).squareRoot()
        return norm > 0 ? vDSP.divide(vector, norm) : vector
    }

    /// Mean of unit vectors, renormalised.
    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count { sum = vDSP.add(sum, normalized(vector)) }
        return normalized(sum)
    }

    /// A person's score is the similarity to their closest stored sample, so a profile holding
    /// samples from different acoustic conditions matches under any of them.
    ///
    /// There is always a closest person; being closest means nothing. Only the bands decide.
    static func match(_ embedding: [Float], profiles: [String: [[Float]]], thresholds: VoiceThresholds) -> VoiceMatch {
        let candidates = profiles
            .compactMap { personID, samples -> VoiceCandidate? in
                guard let best = samples.map({ cosine(embedding, $0) }).max() else { return nil }
                return VoiceCandidate(personID: personID, similarity: best)
            }
            .sorted { ($0.similarity, $1.personID) > ($1.similarity, $0.personID) }
        guard let best = candidates.first else { return VoiceMatch(candidates: [], band: .unknown) }
        let lead = candidates.count > 1 ? best.similarity - candidates[1].similarity : .infinity
        let band: VoiceBand =
            best.similarity >= thresholds.strong && lead >= thresholds.margin ? .strong
            : best.similarity >= thresholds.borderline ? .borderline
            : .unknown
        return VoiceMatch(candidates: candidates, band: band)
    }
}
