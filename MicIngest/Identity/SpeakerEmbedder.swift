@preconcurrency import AVFoundation
import CoreML

/// A stretch of one speaker's speech in the merged audio, chosen for embedding.
struct SpeechExcerpt: Equatable {
    var startMs: Int
    var endMs: Int
    var seconds: Double { Double(endMs - startMs) / 1000 }
}

/// Picks the clean speech used to characterise a diarized speaker: several reasonably long,
/// confidently transcribed turns that do not overlap anyone else. Never the whole recording.
struct ExcerptSelector {
    var minSeconds = 3.0
    var maxSeconds = 10.0
    var maxExcerpts = 8
    var minConfidence = 0.6
    /// Below this the cluster is not compared or enrolled at all.
    var minExcerpts = 2
    var minTotalSeconds = 10.0

    func excerpts(for speaker: String, in transcript: Transcript) -> [SpeechExcerpt] {
        let utterances = transcript.utterances
        let candidates = utterances.enumerated().filter { index, utterance in
            guard utterance.speaker == speaker, utterance.confidence >= minConfidence,
                  Double(utterance.durationMs) / 1000 >= minSeconds else { return false }
            // Diarized turns are ordered; overlap can only involve the neighbours.
            let neighbours = [index - 1, index + 1].filter(utterances.indices.contains).map { utterances[$0] }
            return !neighbours.contains { $0.speaker != speaker && $0.startMs < utterance.endMs && $0.endMs > utterance.startMs }
        }.map(\.element)

        let chosen = candidates
            .sorted { ($0.confidence, $0.durationMs, -$0.index) > ($1.confidence, $1.durationMs, -$1.index) }
            .prefix(maxExcerpts)
            .sorted { $0.startMs < $1.startMs }
            .map { SpeechExcerpt(startMs: $0.startMs, endMs: min($0.endMs, $0.startMs + Int(maxSeconds * 1000))) }
        let total = chosen.reduce(0) { $0 + $1.seconds }
        return chosen.count >= minExcerpts && total >= minTotalSeconds ? chosen : []
    }
}

enum SpeakerEmbedderError: LocalizedError {
    case modelMissing
    case unexpectedOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing: "The voice embedding model is missing from the app bundle."
        case .unexpectedOutput: "The voice embedding model returned an unexpected result."
        }
    }
}

/// Local speaker embeddings: WeSpeaker ResNet34-LM (pyannote community-1 Core ML conversion by
/// Fluid Inference, CC-BY-4.0). Runs entirely on this Mac; nothing here touches the network.
actor SpeakerEmbedder {
    static let modelName = "WeSpeaker ResNet34-LM"
    /// Embeddings from different versions are not comparable; profiles are kept per version.
    static let modelVersion = "wespeaker-resnet34-lm.pyannote-community-1.coreml-1"
    static let dimension = 256

    private static let sampleRate = 16_000.0
    private static let windowSamples = 160_000   // the model takes exactly 10 s
    private static let weightFrames = 589

    private var models: (fbank: MLModel, embedding: MLModel)?

    private func loadedModels() throws -> (fbank: MLModel, embedding: MLModel) {
        if let models { return models }
        guard let bundle = Bundle.main.url(forResource: "VoiceModels", withExtension: "bundle") else {
            throw SpeakerEmbedderError.modelMissing
        }
        let loaded = (
            fbank: try MLModel(contentsOf: bundle.appendingPathComponent("FBank.mlmodelc")),
            embedding: try MLModel(contentsOf: bundle.appendingPathComponent("Embedding.mlmodelc")))
        models = loaded
        return loaded
    }

    /// One L2-normalised embedding per window of 16 kHz mono samples.
    func embed(_ windows: [[Float]]) throws -> [[Float]] {
        guard !windows.isEmpty else { return [] }
        let models = try loadedModels()
        var result: [[Float]] = []
        // The model accepts batches of up to 32 windows.
        for batch in stride(from: 0, to: windows.count, by: 16).map({ Array(windows[$0..<min($0 + 16, windows.count)]) }) {
            let count = batch.count
            let audio = try MLMultiArray(shape: [count, 1, Self.windowSamples] as [NSNumber], dataType: .float32)
            audio.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
                for (row, samples) in batch.enumerated() {
                    // Shorter excerpts are repeated to fill the window; zero-padding distorts the embedding.
                    for i in 0..<Self.windowSamples {
                        pointer[row * Self.windowSamples + i] = samples.isEmpty ? 0 : samples[i % samples.count]
                    }
                }
            }
            let weights = try MLMultiArray(shape: [count, Self.weightFrames] as [NSNumber], dataType: .float32)
            weights.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in pointer.update(repeating: 1) }

            let features = try models.fbank.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio]))
            guard let fbank = features.featureValue(for: "fbank_features")?.multiArrayValue else {
                throw SpeakerEmbedderError.unexpectedOutput
            }
            let output = try models.embedding.prediction(from: MLDictionaryFeatureProvider(
                dictionary: ["fbank_features": fbank, "weights": weights]))
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue,
                  embedding.count == count * Self.dimension else {
                throw SpeakerEmbedderError.unexpectedOutput
            }
            for row in 0..<count {
                let vector = (0..<Self.dimension).map { embedding[row * Self.dimension + $0].floatValue }
                result.append(VoiceMatcher.normalized(vector))
            }
        }
        return result
    }

    /// Embedding of one diarized speaker: the centroid over that speaker's excerpts.
    func clusterEmbedding(audio: URL, excerpts: [SpeechExcerpt]) throws -> [Float]? {
        let file = try AVAudioFile(forReading: audio)
        let windows = try excerpts.map { try Self.read(file, excerpt: $0) }.filter { $0.count >= Int(Self.sampleRate) }
        return VoiceMatcher.centroid(try embed(windows))
    }

    /// Reads an excerpt as 16 kHz mono float samples.
    static func read(_ file: AVAudioFile, excerpt: SpeechExcerpt) throws -> [Float] {
        let source = file.processingFormat
        let start = AVAudioFramePosition(Double(excerpt.startMs) / 1000 * source.sampleRate)
        let frames = AVAudioFrameCount(max(0, min(Double(excerpt.endMs - excerpt.startMs) / 1000 * source.sampleRate,
                                                  Double(file.length - start))))
        guard start >= 0, start < file.length, frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return [] }
        file.framePosition = start
        try file.read(into: input, frameCount: frames)

        // Mix down to mono by averaging channels, then resample.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: input.frameLength),
              let channels = input.floatChannelData, let mixed = monoBuffer.floatChannelData?[0] else { return [] }
        let channelCount = Int(source.channelCount), length = Int(input.frameLength)
        for frame in 0..<length {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            mixed[frame] = sum / Float(channelCount)
        }
        monoBuffer.frameLength = input.frameLength
        if source.sampleRate == sampleRate { return Array(UnsafeBufferPointer(start: mixed, count: length)) }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(length) * sampleRate / source.sampleRate) + 1024)
        else { return [] }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return monoBuffer
        }
        if let conversionError { throw conversionError }
        guard let samples = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}
