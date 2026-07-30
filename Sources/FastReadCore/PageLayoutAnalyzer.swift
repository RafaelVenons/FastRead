import CoreGraphics
import Foundation
import PDFKit

/// Uma linha de texto da página, com onde ela está e o que ela cobre.
public struct PageLine: Sendable, Equatable {
    /// Intervalo em `page.string`.
    public let range: NSRange
    public let frame: CGRect
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
            if range.length > 0, let frame = frame(of: range, on: page, in: text) {
                result.append(PageLine(range: range, frame: frame))
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
        let heights = lines.map(\.frame.height).sorted()
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

    static func startsNewBlock(previous: PageLine, line: PageLine,
                               bodyHeight: CGFloat, text: NSString) -> Bool {
        // Palavra partida pelo diagramador amarra as duas linhas, inclusive através da
        // troca de coluna: separar aqui deixaria um trecho terminando em "relia-" e o
        // seguinte começando em "bility", que é como o leitor via o texto quebrar.
        if endsHyphenated(previous, in: text) { return false }

        // Corpo de letra diferente sempre separa — é título, legenda ou nota, mesmo que
        // a frase anterior tenha ficado sem ponto.
        if changesTypeSize(previous: previous, line: line) { return true }

        // Frase inacabada continuando em minúscula atravessa a coluna: um parágrafo que
        // termina "...from the technology and system" segue em "points of view.", e
        // cortar aí produzia dois trechos que só fazem sentido juntos. A exigência de
        // minúscula protege os títulos de seção, que também não terminam em ponto mas
        // começam maiúsculos.
        if !endsSentence(previous, in: text) && startsLowercase(line, in: text) { return false }

        return breaksLayout(previous: previous, line: line, bodyHeight: bodyHeight)
    }

    private static func changesTypeSize(previous: PageLine, line: PageLine) -> Bool {
        let ratio = line.frame.height / max(previous.frame.height, 0.01)
        return ratio > 1.25 || ratio < 0.8
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

    private static func breaksLayout(previous: PageLine, line: PageLine, bodyHeight: CGFloat) -> Bool {
        // Colunas diferentes: um salto horizontal grande com a linha subindo de volta ao
        // topo é troca de coluna, não continuação.
        if line.frame.minY > previous.frame.minY + bodyHeight { return true }

        // Espaço vertical maior que o entrelinhas normal separa parágrafos.
        let gap = previous.frame.minY - line.frame.maxY
        if gap > bodyHeight * 0.6 { return true }

        // Recuo de primeira linha, quando o parágrafo anterior já fechou a frase.
        let indent = line.frame.minX - previous.frame.minX
        if indent > bodyHeight * 0.8 { return true }

        return false
    }

    private static func makeBlock(_ lines: [PageLine]) -> LayoutBlock {
        let range = NSRange(location: lines[0].range.location,
                            length: NSMaxRange(lines[lines.count - 1].range) - lines[0].range.location)
        let frame = lines.dropFirst().reduce(lines[0].frame) { $0.union($1.frame) }
        return LayoutBlock(range: range, frame: frame, lineCount: lines.count)
    }

    // MARK: - Geometria

    /// Retângulo que cobre um intervalo de `page.string`.
    private static func frame(of range: NSRange, on page: PDFPage, in text: NSString) -> CGRect? {
        let start = PageTextLocator.boundsIndex(for: range.location, in: text)
        let end = PageTextLocator.boundsIndex(for: NSMaxRange(range) - 1, in: text)
        guard start >= 0, end >= start, end < page.numberOfCharacters else { return nil }

        var result: CGRect?
        for i in start...end {
            let rect = page.characterBounds(at: i)
            guard !rect.isNull, rect.width > 0 || rect.height > 0 else { continue }
            result = result.map { $0.union(rect) } ?? rect
        }
        return result
    }
}
