import CoreGraphics
import Foundation
import PDFKit

/// Uma linha de texto da página, com onde ela está e o que ela cobre.
public struct PageLine: Sendable, Equatable {
    /// Intervalo em `page.string`.
    public let range: NSRange
    public let frame: CGRect
    /// Altura de referência dos glifos: o percentil 90, não a caixa nem a mediana.
    ///
    /// A caixa da linha infla com artefatos — medido, 21,1 contra 42,5 em duas linhas do
    /// mesmo parágrafo. E a mediana oscila com a composição da linha: só "acemnorsuvwxz"
    /// dá x-height, enquanto maiúsculas e parênteses dão altura de ascendente. O p90
    /// captura o ascendente, que é estável e é o que de fato reflete o corpo de letra.
    /// Medido nos artigos: mediana produzia 972 cortes indevidos de parágrafo, p90 produz 41.
    public let typicalHeight: CGFloat

    public init(range: NSRange, frame: CGRect, typicalHeight: CGFloat? = nil) {
        self.range = range
        self.frame = frame
        self.typicalHeight = typicalHeight ?? frame.height
    }
}

/// Um conjunto de linhas que formam uma unidade visual — um parágrafo, um título,
/// o bloco de autores.
public struct LayoutBlock: Sendable, Equatable {
    public let range: NSRange
    public let frame: CGRect
    public let lineCount: Int
}

/// Descobre a estrutura visual de uma página.
///
/// Existe porque a pontuação não basta para achar o fim de um parágrafo em artigo
/// científico: cabeçalho da revista, título, autores e afiliação são linhas que **não
/// terminam em ponto**. Sem geometria, todas se juntam num trecho só — medido num artigo
/// real, 1307 caracteres desde o aviso do editor até o meio da página, o que fazia tocar
/// em qualquer parágrafo começar a leitura no cabeçalho.
public enum PageLayoutAnalyzer {

    /// Linhas da página, na ordem de leitura, com a geometria de cada uma.
    public static func lines(of page: PDFPage) -> [PageLine] {
        guard let text = page.string as NSString?, text.length > 0 else { return [] }

        var result: [PageLine] = []
        var start = 0

        for i in 0...text.length {
            let isBreak = i == text.length || text.character(at: i) == 0x0A
            guard isBreak else { continue }

            let range = NSRange(location: start, length: i - start)
            if range.length > 0, let measured = measure(range, on: page, in: text) {
                result.append(PageLine(range: range, frame: measured.frame,
                                       typicalHeight: measured.typicalHeight))
            }
            start = i + 1
        }
        return result
    }

    /// Linhas agrupadas em blocos visuais.
    public static func blocks(of page: PDFPage) -> [LayoutBlock] {
        let lines = lines(of: page)
        guard !lines.isEmpty else { return [] }

        // A altura mediana representa o corpo do texto, que domina a página; usá-la como
        // referência evita que um título grande distorça os limiares.
        let heights = lines.map(\.typicalHeight).sorted()
        let bodyHeight = heights[heights.count / 2]

        let text = page.string as NSString? ?? ""
        var blocks: [LayoutBlock] = []
        var current: [PageLine] = [lines[0]]

        for (previous, line) in zip(lines, lines.dropFirst()) {
            if startsNewBlock(previous: previous, line: line,
                              bodyHeight: bodyHeight, text: text) {
                blocks.append(makeBlock(current))
                current = [line]
            } else {
                current.append(line)
            }
        }
        blocks.append(makeBlock(current))
        return blocks
    }

    // MARK: - Regras de quebra

    /// Por que duas linhas foram separadas — ou o que as manteve juntas.
    ///
    /// Exposto para diagnóstico: sem saber qual regra disparou, ajustar limiares vira
    /// tentativa e erro.
    public enum BreakReason: String, Sendable {
        case hyphenHeld          // palavra partida segurou
        case sentenceHeld        // frase inacabada segurou
        case sameBlock           // nenhuma regra disparou
        case typeSize            // corpo de letra diferente
        case column              // troca de coluna
        case verticalGap         // espaço vertical grande
        case indent              // recuo de primeira linha

        public var separates: Bool {
            switch self {
            case .hyphenHeld, .sentenceHeld, .sameBlock: false
            case .typeSize, .column, .verticalGap, .indent: true
            }
        }
    }

    static func breakReason(previous: PageLine, line: PageLine,
                            bodyHeight: CGFloat, text: NSString) -> BreakReason {
        if endsHyphenated(previous, in: text) { return .hyphenHeld }
        if changesTypeSize(previous: previous, line: line) { return .typeSize }
        if !endsSentence(previous, in: text) && startsLowercase(line, in: text) { return .sentenceHeld }

        if line.frame.minY > previous.frame.minY + bodyHeight { return .column }
        let gap = previous.frame.minY - line.frame.maxY
        if gap > bodyHeight * 0.6 { return .verticalGap }
        let indent = line.frame.minX - previous.frame.minX
        if indent > bodyHeight * 0.8 { return .indent }

        return .sameBlock
    }

    static func startsNewBlock(previous: PageLine, line: PageLine,
                               bodyHeight: CGFloat, text: NSString) -> Bool {
        breakReason(previous: previous, line: line, bodyHeight: bodyHeight, text: text).separates
    }

    /// Tolerância larga de propósito: a altura medida varia entre linhas do mesmo
    /// parágrafo, e apertá-la corta texto corrido. Um título contra o corpo passa bem de
    /// 1,4 — no artigo de exemplo, 15 pt contra 9 pt dá 1,67.
    private static let typeSizeTolerance: CGFloat = 1.4

    private static func changesTypeSize(previous: PageLine, line: PageLine) -> Bool {
        let ratio = line.typicalHeight / max(previous.typicalHeight, 0.01)
        return ratio > typeSizeTolerance || ratio < 1 / typeSizeTolerance
    }

    /// A linha fecha uma frase?
    private static func endsSentence(_ line: PageLine, in text: NSString) -> Bool {
        guard NSMaxRange(line.range) <= text.length, line.range.length > 0 else { return true }
        let content = text.substring(with: line.range).trimmingCharacters(in: .whitespacesAndNewlines)

        let closing: Set<Character> = ["\"", "'", ")", "]", "}", "»", "”", "’"]
        let terminal: Set<Character> = [".", "!", "?", "…", ":", ";"]
        for c in content.reversed() {
            if closing.contains(c) { continue }
            return terminal.contains(c)
        }
        return true   // linha vazia não segura nada
    }

    private static func startsLowercase(_ line: PageLine, in text: NSString) -> Bool {
        guard NSMaxRange(line.range) <= text.length, line.range.length > 0 else { return false }
        let content = text.substring(with: line.range).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.first?.isLowercase == true
    }

    /// A linha termina com hífen de quebra silábica?
    private static func endsHyphenated(_ line: PageLine, in text: NSString) -> Bool {
        guard NSMaxRange(line.range) <= text.length, line.range.length > 0 else { return false }
        let content = text.substring(with: line.range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.hasSuffix("-") else { return false }
        // "-" isolado é travessão ou marcador de lista, não palavra partida.
        return content.count > 1 && content.dropLast().last?.isLetter == true
    }

    private static func makeBlock(_ lines: [PageLine]) -> LayoutBlock {
        let range = NSRange(location: lines[0].range.location,
                            length: NSMaxRange(lines[lines.count - 1].range) - lines[0].range.location)
        let frame = lines.dropFirst().reduce(lines[0].frame) { $0.union($1.frame) }
        return LayoutBlock(range: range, frame: frame, lineCount: lines.count)
    }

    // MARK: - Geometria

    /// Caixa que cobre um intervalo de `page.string` e a altura típica dos seus glifos.
    ///
    /// A mediana ignora o glifo esticado ocasional que inflaria a caixa e faria a linha
    /// passar por outro corpo de letra.
    private static func measure(_ range: NSRange, on page: PDFPage,
                                in text: NSString) -> (frame: CGRect, typicalHeight: CGFloat)? {
        let start = PageTextLocator.boundsIndex(for: range.location, in: text)
        let end = PageTextLocator.boundsIndex(for: NSMaxRange(range) - 1, in: text)
        guard start >= 0, end >= start, end < page.numberOfCharacters else { return nil }

        var box: CGRect?
        var heights: [CGFloat] = []
        for i in start...end {
            let rect = page.characterBounds(at: i)
            guard !rect.isNull, rect.width > 0 || rect.height > 0 else { continue }
            box = box.map { $0.union(rect) } ?? rect
            if rect.height > 0 { heights.append(rect.height) }
        }
        guard let box else { return nil }

        heights.sort()
        let typical = heights.isEmpty
            ? box.height
            : heights[min(heights.count - 1, Int(Double(heights.count) * 0.9))]
        return (box, typical)
    }
}
