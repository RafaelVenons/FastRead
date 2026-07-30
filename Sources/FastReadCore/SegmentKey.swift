import CryptoKit
import Foundation

/// Identidade de um segmento sintetizado: o mesmo texto lido com a mesma voz e a mesma
/// velocidade produz o mesmo áudio, então pode reusar o mesmo cache.
///
/// O valor é hexadecimal justamente para servir de nome de arquivo — texto de PDF traz
/// barras, aspas e quebras de linha que não podem vazar para o sistema de arquivos.
public struct SegmentKey: Hashable, Sendable {
    public let value: String

    public init(text: String, voiceIdentifier: String, rate: Float) {
        // Espaços nas bordas vêm da extração do PDF e não mudam a fala.
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Duas casas bastam: diferenças menores não são audíveis e só invalidariam cache.
        let normalizedRate = String(format: "%.2f", rate)

        let payload = "\(normalizedText)|\(voiceIdentifier)|\(normalizedRate)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        self.value = digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SegmentKey: CustomStringConvertible {
    public var description: String { value }
}
