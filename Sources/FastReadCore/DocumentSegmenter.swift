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

    /// Quebra o documento em trechos legíveis.
    ///
    /// A divisão parte dos blocos visuais da página, não do texto corrido: num artigo
    /// científico o cabeçalho da revista, o título, os autores e a afiliação são linhas
    /// que não terminam em ponto, e sem a geometria todas se fundem num trecho só.
    public func segments(of document: PDFDocument, documentLanguage: String) -> [DocumentSegment] {
        var result: [DocumentSegment] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string as NSString?, pageText.length > 0 else { continue }

            let blocks = PageLayoutAnalyzer.blocks(of: page)
            // Página sem geometria utilizável ainda pode ser lida pelo texto puro.
            let ranges = blocks.isEmpty
                ? [NSRange(location: 0, length: pageText.length)]
                : blocks.map(\.range)

            for blockRange in ranges {
                guard blockRange.length > 0, NSMaxRange(blockRange) <= pageText.length else { continue }
                let blockText = pageText.substring(with: blockRange)

                for mapped in segmenter.mappedSegments(from: blockText) {
                    // Os índices vêm relativos ao bloco; reposiciona-os na página.
                    let onPage = MappedSegment(
                        text: mapped.text,
                        sourceIndices: mapped.sourceIndices.map { $0 + blockRange.location })

                    let language = detector.language(forSegment: mapped.text,
                                                     documentLanguage: documentLanguage)
                    result.append(DocumentSegment(id: result.count,
                                                  pageIndex: pageIndex,
                                                  segment: onPage,
                                                  language: language))
                }
            }
        }
        return result
    }

    /// Segmento tocado, a partir do índice de caractere na página.
    ///
    /// Quando o toque não cai dentro de nenhum segmento — entre dois parágrafos, numa
    /// legenda descartada como ruído — vale o segmento mais próximo. Voltar ao primeiro
    /// da página fazia tocar num parágrafo do meio começar a leitura no bloco de autores.
    public func segment(in segments: [DocumentSegment],
                        pageIndex: Int,
                        characterIndex: Int) -> DocumentSegment? {
        let onPage = segments.filter { $0.pageIndex == pageIndex }
        guard !onPage.isEmpty else { return nil }

        if let exact = onPage.first(where: { $0.contains(pageCharacterIndex: characterIndex) }) {
            return exact
        }
        return onPage.min { distance(from: $0, to: characterIndex) < distance(from: $1, to: characterIndex) }
    }

    private func distance(from segment: DocumentSegment, to index: Int) -> Int {
        guard let range = segment.pageRange else { return .max }
        if index < range.location { return range.location - index }
        if index >= NSMaxRange(range) { return index - NSMaxRange(range) + 1 }
        return 0
    }
}
