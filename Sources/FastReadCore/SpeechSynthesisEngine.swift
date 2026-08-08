import AVFoundation
import Foundation

/// Resultado de uma síntese: áudio em arquivo temporário mais o alinhamento.
/// O arquivo é temporário de propósito — `DiskSegmentCache.store` o move para o cache.
public struct SynthesizedSegment: Sendable, Equatable {
    public let audioURL: URL
    public let alignment: SegmentAlignment
}

public enum SynthesisError: Error, Sendable, Equatable {
    case emptyText
    case noVoiceAvailable(language: String)
    case audioFileCreationFailed
    case producedNoAudio
    case timedOut
}

public protocol SegmentSynthesizing: Sendable {
    /// `voiceIdentifier` nulo significa "a melhor voz instalada para o idioma".
    func synthesize(text: String, language: String, rate: Float,
                    voiceIdentifier: String?) async throws -> SynthesizedSegment
    /// Voz que seria usada para este idioma. Entra na chave de cache: trocar de voz
    /// precisa invalidar o áudio já gerado.
    func voiceIdentifier(for language: String) -> String?
}

extension SegmentSynthesizing {
    public func synthesize(text: String, language: String, rate: Float) async throws -> SynthesizedSegment {
        try await synthesize(text: text, language: language, rate: rate, voiceIdentifier: nil)
    }
}

/// Sintetiza um segmento em AAC e captura o alinhamento palavra-a-palavra.
///
/// Grava direto em AAC porque o PCM que sai do sintetizador custa 311 MB/hora contra
/// 17 MB/hora a 24 kbps — a diferença entre 2,5 GB e 136 MB para um livro inteiro.
public final class AVSpeechSynthesisEngine: SegmentSynthesizing, @unchecked Sendable {

    private let bitRate: Int
    private let outputDirectory: URL
    private let timeout: TimeInterval

    /// Sessões em voo. Sem isto, a sessão seria desalocada antes dos callbacks chegarem.
    private var active: [ObjectIdentifier: Session] = [:]
    private let lock = NSLock()

    public init(
        bitRate: Int = 24_000,
        outputDirectory: URL = FileManager.default.temporaryDirectory,
        timeout: TimeInterval = 60
    ) {
        self.bitRate = bitRate
        self.outputDirectory = outputDirectory
        self.timeout = timeout
    }

    public func synthesize(
        text: String,
        language: String,
        rate: Float,
        voiceIdentifier: String?
    ) async throws -> SynthesizedSegment {

        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw SynthesisError.emptyText
        }
        guard let voice = Self.resolveVoice(language: language, identifier: voiceIdentifier) else {
            throw SynthesisError.noVoiceAvailable(language: language)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent("fastread-\(UUID().uuidString).m4a")

        return try await withCheckedThrowingContinuation { continuation in
            let session = Session(text: text, outputURL: outputURL, bitRate: bitRate)
            let id = ObjectIdentifier(session)

            lock.lock(); active[id] = session; lock.unlock()

            session.start(voice: voice, rate: rate, timeout: timeout) { [weak self] result in
                self?.lock.lock(); self?.active[id] = nil; self?.lock.unlock()
                continuation.resume(with: result)
            }
        }
    }

    public func voiceIdentifier(for language: String) -> String? {
        Self.resolveVoice(language: language, identifier: nil)?.identifier
    }

    /// Melhor voz instalada para o idioma, preferindo as de maior qualidade.
    ///
    /// As vozes `enhanced`/`premium` precisam ser baixadas pelo usuário em Ajustes;
    /// sem elas o sistema só oferece as `compact`, bem mais robóticas.
    static func resolveVoice(language: String, identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix.lowercased()) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }
}

// MARK: - Sessão de síntese

/// Uma única síntese. Isolada por instância para que várias rodem em paralelo —
/// medido: 3 sínteses simultâneas levam o mesmo tempo de parede que uma.
private final class Session: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let text: String
    private let outputURL: URL
    private let bitRate: Int
    private let synthesizer = AVSpeechSynthesizer()
    /// O buffer de fim chega duas vezes; só a primeira pode concluir a sessão.
    private let termination = TerminationGuard()

    private var markers: [RawMarker] = []
    private var audioFile: AVAudioFile?
    private var format: AudioFormatInfo?
    private var totalFrames: Int64 = 0
    private var totalBytes: Int64 = 0
    private var completion: ((Result<SynthesizedSegment, Error>) -> Void)?
    private let lock = NSLock()

    init(text: String, outputURL: URL, bitRate: Int) {
        self.text = text
        self.outputURL = outputURL
        self.bitRate = bitRate
        super.init()
        synthesizer.delegate = self
    }

    func start(
        voice: AVSpeechSynthesisVoice,
        rate: Float,
        timeout: TimeInterval,
        completion: @escaping (Result<SynthesizedSegment, Error>) -> Void
    ) {
        self.completion = completion

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate

        synthesizer.write(utterance) { [weak self] buffer in
            self?.handle(buffer)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(SynthesisError.timedOut))
        }
    }

    /// Markers do alinhamento. Este delegate funciona durante `write()`; já o parâmetro
    /// `toMarkerCallback:` de `write(_:toBufferCallback:toMarkerCallback:)` não dispara.
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeak marker: AVSpeechSynthesisMarker,
        utterance: AVSpeechUtterance
    ) {
        guard marker.mark == .word else { return }
        lock.lock()
        markers.append(RawMarker(byteSampleOffset: marker.byteSampleOffset, range: marker.textRange))
        lock.unlock()
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }

        guard pcm.frameLength > 0 else {
            finishWithCollectedAudio()
            return
        }

        lock.lock()
        if audioFile == nil {
            let description = pcm.format.streamDescription.pointee
            format = AudioFormatInfo(sampleRate: pcm.format.sampleRate,
                                     bytesPerFrame: Double(description.mBytesPerFrame))
            audioFile = try? AVAudioFile(forWriting: outputURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: pcm.format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ])
        }
        let file = audioFile
        lock.unlock()

        guard let file else {
            finish(.failure(SynthesisError.audioFileCreationFailed))
            return
        }
        try? file.write(from: pcm)

        lock.lock()
        totalFrames += Int64(pcm.frameLength)
        // Conta os bytes com o formato de cada buffer, não com o do primeiro: é esta
        // medida que dá a escala de tempo dos markers.
        totalBytes += Int64(pcm.frameLength) * Int64(pcm.format.streamDescription.pointee.mBytesPerFrame)
        lock.unlock()
    }

    private func finishWithCollectedAudio() {
        lock.lock()
        let collected = markers
        let capturedFormat = format
        let frames = totalFrames
        let bytes = totalBytes
        lock.unlock()

        guard let capturedFormat, frames > 0 else {
            finish(.failure(SynthesisError.producedNoAudio))
            return
        }

        let alignment = AlignmentBuilder.build(text: text, markers: collected,
                                               format: capturedFormat, totalFrames: frames,
                                               totalBytes: bytes)
        finish(.success(SynthesizedSegment(audioURL: outputURL, alignment: alignment)))
    }

    private func finish(_ result: Result<SynthesizedSegment, Error>) {
        guard termination.claim() else { return }

        lock.lock()
        audioFile = nil          // fecha o arquivo antes de entregá-lo
        let callback = completion
        completion = nil
        lock.unlock()

        if case .failure = result { try? FileManager.default.removeItem(at: outputURL) }
        callback?(result)
    }
}
