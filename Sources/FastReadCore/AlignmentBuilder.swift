import Foundation

/// Formato do áudio produzido pelo sintetizador, necessário para traduzir offsets em tempo.
public struct AudioFormatInfo: Sendable, Equatable {
    public let sampleRate: Double
    /// Bytes por frame — 4 para float32 mono, que é o que as vozes do sistema entregam.
    public let bytesPerFrame: Double

    public init(sampleRate: Double, bytesPerFrame: Double) {
        self.sampleRate = sampleRate
        self.bytesPerFrame = bytesPerFrame
    }
}

/// Marker cru vindo do sintetizador, antes de virar tempo.
public struct RawMarker: Sendable, Equatable {
    public let byteSampleOffset: Int
    public let range: NSRange

    public init(byteSampleOffset: Int, range: NSRange) {
        self.byteSampleOffset = byteSampleOffset
        self.range = range
    }
}

/// Traduz os markers do sintetizador em um alinhamento palavra-a-palavra.
public enum AlignmentBuilder {

    /// - Important: `byteSampleOffset` é medido em **bytes**, apesar do nome sugerir
    ///   índice de sample. Dividir apenas pelo sample rate infla todos os tempos por
    ///   `bytesPerFrame` (4× no formato das vozes do sistema): o último marker de um
    ///   áudio de 5,42 s aparecia em 18,297 s antes da correção.
    public static func build(
        text: String,
        markers: [RawMarker],
        format: AudioFormatInfo,
        totalFrames: Int64
    ) -> SegmentAlignment {

        let bytesPerSecond = format.sampleRate * format.bytesPerFrame
        let nsText = text as NSString

        let words: [WordTiming] = markers.compactMap { marker in
            let range = marker.range
            guard range.location != NSNotFound,
                  range.length > 0,
                  range.location >= 0,
                  NSMaxRange(range) <= nsText.length
            else { return nil }

            let start = bytesPerSecond > 0 ? Double(marker.byteSampleOffset) / bytesPerSecond : 0
            return WordTiming(word: nsText.substring(with: range),
                              location: range.location,
                              length: range.length,
                              start: start)
        }
        .sorted { $0.start < $1.start }

        let duration = format.sampleRate > 0 ? Double(totalFrames) / format.sampleRate : 0
        return SegmentAlignment(words: words, duration: duration)
    }
}

/// Deixa passar apenas a primeira finalização.
///
/// O `bufferCallback` do `AVSpeechSynthesizer` sinaliza o fim da síntese com um buffer
/// de `frameLength == 0`, e ele chega **duas vezes** (medido: 326 invocações, sendo as
/// duas últimas vazias). Sem esta guarda, cada segmento seria gravado no cache em
/// duplicidade e as continuações chamadas duas vezes.
public final class TerminationGuard: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    public init() {}

    /// `true` apenas na primeira chamada.
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
