import Foundation
import PDFKit

/// Um segmento localizado dentro do documento.
public struct DocumentSegment: Sendable, Equatable, Identifiable {
    public let id: Int
    public let pageIndex: Int
    public let segment: MappedSegment
    public let language: String

    public init(id: Int, pageIndex: Int, segment: MappedSegment, language: String) {
        self.id = id
        self.pageIndex = pageIndex
        self.segment = segment
        self.language = language
    }

    public var text: String { segment.text }

    /// Área de texto que este segmento ocupa na página, em índices de `page.string`.
    public var pageRange: NSRange? {
        guard let low = segment.sourceIndices.min(),
              let high = segment.sourceIndices.max() else { return nil }
        return NSRange(location: low, length: high - low + 1)
    }

    public func contains(pageCharacterIndex index: Int) -> Bool {
        guard let range = pageRange else { return false }
        return NSLocationInRange(index, range)
    }
}

/// Quebra um PDF inteiro em segmentos legíveis, já com idioma resolvido.
public struct DocumentSegmenter: Sendable {

    private let segmenter: TextSegmenter
    private let detector: LanguageDetector

    public init(segmenter: TextSegmenter = TextSegmenter(),
                detector: LanguageDetector = LanguageDetector()) {
        self.segmenter = segmenter
        self.detector = detector
    }

    /// Idioma do documento, amostrado de páginas espalhadas.
    ///
    /// Amostra páginas distribuídas em vez das primeiras: capa, sumário e folha de rosto
    /// não representam o corpo do texto.
    public func documentLanguage(of document: PDFDocument, fallback: String = "en") -> String {
        let count = document.pageCount
        guard count > 0 else { return fallback }

        let wanted = min(8, count)
        let step = max(1, count / wanted)
        let pages = stride(from: 0, to: count, by: step)
            .prefix(wanted)
            .compactMap { document.page(at: $0)?.string }

        return detector.documentLanguage(sampling: pages, fallback: fallback)
    }

    public func segments(of document: PDFDocument, documentLanguage: String) -> [DocumentSegment] {
        var result: [DocumentSegment] = []

        for pageIndex in 0..<document.pageCount {
            guard let text = document.page(at: pageIndex)?.string else { continue }

            for mapped in segmenter.mappedSegments(from: text) {
                let language = detector.language(forSegment: mapped.text,
                                                 documentLanguage: documentLanguage)
                result.append(DocumentSegment(id: result.count,
                                              pageIndex: pageIndex,
                                              segment: mapped,
                                              language: language))
            }
        }
        return result
    }

    /// Segmento tocado, a partir do índice de caractere na página.
    public func segment(in segments: [DocumentSegment],
                        pageIndex: Int,
                        characterIndex: Int) -> DocumentSegment? {
        segments.first { $0.pageIndex == pageIndex && $0.contains(pageCharacterIndex: characterIndex) }
            ?? segments.first { $0.pageIndex == pageIndex }
    }
}
