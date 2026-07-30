import AVFoundation
import Foundation

public enum VoiceQuality: Int, Sendable, Comparable, CaseIterable {
    case standard
    case enhanced
    case premium

    public static func < (lhs: VoiceQuality, rhs: VoiceQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .standard: "Padrão"
        case .enhanced: "Aprimorada"
        case .premium: "Premium"
        }
    }
}

public struct VoiceOption: Sendable, Identifiable, Equatable {
    public let identifier: String
    public let name: String
    public let language: String
    public let quality: VoiceQuality

    public var id: String { identifier }

    public init(identifier: String, name: String, language: String, quality: VoiceQuality) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
    }
}

/// As vozes instaladas no dispositivo, por idioma.
///
/// Enumerar `speechVoices()` e escolher explicitamente também contorna uma regressão do
/// iOS 26 (FB20271264), em que `AVSpeechSynthesisVoice(language:)` ignora a voz que o
/// usuário escolheu nos Ajustes e devolve a padrão do sistema.
public enum VoiceCatalog {

    public static func voices(for language: String) -> [VoiceOption] {
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        guard !prefix.isEmpty else { return [] }

        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix.lowercased()) }
            .map {
                VoiceOption(identifier: $0.identifier,
                            name: $0.name,
                            language: $0.language,
                            quality: quality(of: $0.quality))
            }
            // Melhor primeiro; nome desempata para a lista não dançar entre execuções.
            .sorted { ($0.quality, $1.name) > ($1.quality, $0.name) }
    }

    public static func best(for language: String) -> VoiceOption? {
        voices(for: language).first
    }

    /// Há alguma voz acima da `compact` instalada? Serve para o app sugerir o download.
    public static func hasHighQualityVoice(for language: String) -> Bool {
        best(for: language).map { $0.quality > .standard } ?? false
    }

    public static func voice(withIdentifier identifier: String) -> VoiceOption? {
        AVSpeechSynthesisVoice.speechVoices()
            .first { $0.identifier == identifier }
            .map {
                VoiceOption(identifier: $0.identifier,
                            name: $0.name,
                            language: $0.language,
                            quality: quality(of: $0.quality))
            }
    }

    private static func quality(of quality: AVSpeechSynthesisVoiceQuality) -> VoiceQuality {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }
}
