import Foundation
import NaturalLanguage

/// Identifica o idioma de um PDF e de seus segmentos, para escolher a voz do TTS.
///
/// A política de dois níveis existe porque a detecção isolada erra feio em texto curto
/// e em texto misto — medido: `"Figure 3."` sai com 41,5% de confiança sem restrição de
/// candidatos, e uma frase que começa em inglês mas cita termos em português é
/// classificada como `pt` com 97,9%. Trocar de voz por causa de uma legenda seria pior
/// que ler tudo com a voz do documento.
public struct LanguageDetector: Sendable {

    public struct Detection: Sendable, Equatable {
        public let language: String
        public let confidence: Double
    }

    /// Candidatos considerados. Vazio = sem restrição (pior em trechos curtos).
    public let constraints: [String]
    /// Abaixo disso, um segmento nunca sobrepõe o idioma do documento.
    public let minSegmentLength: Int
    /// Confiança mínima para um segmento sobrepor o idioma do documento.
    public let minOverrideConfidence: Double
    /// Teto de caracteres amostrados ao classificar o documento inteiro.
    public let sampleLimit: Int

    public init(
        constraints: [String] = ["en", "pt", "es"],
        minSegmentLength: Int = 40,
        minOverrideConfidence: Double = 0.85,
        sampleLimit: Int = 2000
    ) {
        self.constraints = constraints
        self.minSegmentLength = minSegmentLength
        self.minOverrideConfidence = minOverrideConfidence
        self.sampleLimit = sampleLimit
    }

    /// Idioma dominante do texto, ou `nil` se não houver conteúdo classificável.
    public func detect(_ text: String) -> Detection? {
        guard text.contains(where: \.isLetter) else { return nil }

        let recognizer = NLLanguageRecognizer()
        if !constraints.isEmpty {
            recognizer.languageConstraints = constraints.map(NLLanguage.init(rawValue:))
        }
        recognizer.processString(text)

        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else {
            return nil
        }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        return Detection(language: dominant.rawValue, confidence: confidence)
    }

    /// Idioma a usar num segmento, herdando o do documento quando a evidência é fraca.
    public func language(forSegment text: String, documentLanguage: String) -> String {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minSegmentLength,
              let detection = detect(text),
              detection.confidence >= minOverrideConfidence
        else { return documentLanguage }

        return detection.language
    }

    /// Idioma do documento, a partir de uma amostra de páginas.
    ///
    /// Amostra o começo de cada página em vez de uma página inteira: capas, sumários e
    /// páginas de referências enviesam a classificação quando lidas isoladamente.
    public func documentLanguage(sampling pages: [String], fallback: String = "en") -> String {
        var sample = ""
        sample.reserveCapacity(sampleLimit)

        for page in pages {
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sample += trimmed.prefix(sampleLimit - sample.count)
            sample += " "
            if sample.count >= sampleLimit { break }
        }

        return detect(sample)?.language ?? fallback
    }
}
