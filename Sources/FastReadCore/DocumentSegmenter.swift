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
    ///
    /// Do primeiro ao último índice, sem olhar buracos — serve para localizar e ordenar o
    /// trecho. Para pintar o realce use `pageRanges`.
    public var pageRange: NSRange? {
        guard let low = segment.sourceIndices.min(),
              let high = segment.sourceIndices.max() else { return nil }
        return NSRange(location: low, length: high - low + 1)
    }

    /// Os trechos de página que a voz realmente lê, em ordem.
    ///
    /// Quando uma fórmula sai do meio do texto, o que sobra deixa de ser contíguo na
    /// página. `pageRange` sozinho iria de ponta a ponta e cobriria a equação removida —
    /// o realce pintava justamente o que não é falado.
    public var pageRanges: [NSRange] {
        var runs: [NSRange] = []
        for index in segment.sourceIndices {
            if let last = runs.last, index == NSMaxRange(last) {
                runs[runs.count - 1] = NSRange(location: last.location, length: last.length + 1)
            } else if let last = runs.last, NSLocationInRange(index, last) {
                continue  // o mapa repete um índice ao juntar pedaços; não abre trecho novo
            } else {
                runs.append(NSRange(location: index, length: 1))
            }
        }
        return runs
    }

    public func contains(pageCharacterIndex index: Int) -> Bool {
        pageRanges.contains { NSLocationInRange(index, $0) }
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
        return stitchHyphenated(result)
    }

    /// Costura trechos cuja última palavra ficou partida.
    ///
    /// A regra de linha do analisador resolve a hifenização dentro de um bloco, mas não
    /// quando o hífen cai na última linha dele — fim de coluna, fim de página. Sem esta
    /// costura a voz lê "relia-" e o trecho seguinte começa em "bility".
    private func stitchHyphenated(_ segments: [DocumentSegment]) -> [DocumentSegment] {
        var result: [DocumentSegment] = []

        for segment in segments {
            guard let previous = result.last,
                  previous.pageIndex == segment.pageIndex,
                  continues(previous, into: segment),
                  let joined = join(previous, segment)
            else {
                result.append(DocumentSegment(id: result.count,
                                              pageIndex: segment.pageIndex,
                                              segment: segment.segment,
                                              language: segment.language))
                continue
            }
            result[result.count - 1] = joined
        }
        return result
    }

    /// O segundo trecho continua a frase do primeiro?
    ///
    /// Duas situações levam a isso: palavra partida por hífen, e um bloco cortado pela
    /// análise de layout no meio de uma frase — uma equação em display entre dois pedaços
    /// do mesmo parágrafo, por exemplo.
    private func continues(_ first: DocumentSegment, into second: DocumentSegment) -> Bool {
        if endsHyphenated(first.text) { return true }

        let fim = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inicio = second.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ultima = fim.last, let primeira = inicio.first else { return false }

        // Frase fechada encerra o trecho; minúscula no início do seguinte é o sinal de
        // que a mesma frase prossegue.
        let fechada: Set<Character> = [".", "!", "?", "…", ":", ";"]
        return !fechada.contains(ultima) && primeira.isLowercase
    }

    private func endsHyphenated(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("-"), trimmed.count > 1 else { return false }
        return trimmed.dropLast().last?.isLetter == true
    }

    /// Junta dois trechos removendo o hífen de quebra, mantendo o mapa de índices.
    private func join(_ first: DocumentSegment, _ second: DocumentSegment) -> DocumentSegment? {
        var text = first.segment.text
        var indices = first.segment.sourceIndices
        guard !indices.isEmpty else { return nil }

        if text.hasSuffix("-") {
            // O hífen não existe na fala; sai do texto e do mapa junto, e as metades da
            // palavra se colam sem espaço.
            text.removeLast()
            indices.removeLast()
            if second.segment.text.first?.isLowercase != true {
                text += " "
                indices.append(indices.last ?? 0)
            }
        } else {
            // Frase que prossegue: as partes se separam por espaço, como estavam.
            text += " "
            indices.append(indices.last ?? 0)
        }
        text += second.segment.text
        indices += second.segment.sourceIndices

        return DocumentSegment(id: first.id,
                               pageIndex: first.pageIndex,
                               segment: MappedSegment(text: text, sourceIndices: indices),
                               language: first.language)
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
