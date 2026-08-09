import CoreGraphics
import Foundation
import PDFKit

/// Traduz entre os índices de `page.string` e a geometria da página.
///
/// Existe porque o PDFKit usa **dois sistemas de índice diferentes** e não avisa:
/// `page.string` conta as quebras de linha, `characterBounds(at:)` e
/// `characterIndex(at:)` não. Medido num artigo de exemplo: a palavra na posição 41 de
/// `page.string` está na posição 40 dos bounds, a da posição 91 está na 89, e a da
/// posição 269 está na 264 — o desvio acompanha as quebras de linha, mas **nem sempre é
/// exatamente o número delas**. Por isso o resultado é sempre conferido contra o texto
/// esperado, em vez de confiar na conta.
public enum PageTextLocator {

    /// Desvios tentados em volta da estimativa, do mais provável ao menos.
    ///
    /// O alcance vai a ±16 porque a estimativa erra mais em trechos longos que em
    /// palavras soltas: medido nos artigos, o realce de parágrafo começava até 5
    /// caracteres depois do início, e um limite de ±4 deixava esses casos sem correção.
    private static let probes: [Int] = {
        var result = [0]
        for delta in 1...16 { result.append(-delta); result.append(delta) }
        return result
    }()

    // MARK: - Texto → seleção

    /// Seleção do PDFKit correspondente a um intervalo de `page.string`.
    ///
    /// Verifica a seleção obtida contra o texto esperado e corrige o desvio quando a
    /// estimativa erra, o que torna o realce imune às irregularidades da indexação.
    public static func selection(on page: PDFPage, matching range: NSRange, in pageText: NSString) -> PDFSelection? {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= pageText.length
        else { return nil }

        let expected = pageText.substring(with: range)
        let estimate = boundsIndex(for: range.location, in: pageText)

        let wanted = collapsed(expected)
        // Exigir o texto inteiro idêntico não funciona em trecho de várias linhas: a
        // seleção do PDFKit difere do `page.string` no espaçamento, a comparação falhava
        // sempre e o realce ficava no candidato errado. Alinhar pelo começo é o que
        // determina o deslocamento; o fim se resolve escolhendo a borda.
        let head = String(wanted.prefix(24))

        var best: (selection: PDFSelection, score: Int, delta: Int)?

        // O fim vem convertido, não somado ao comprimento: `range.length` conta as
        // quebras de linha de `page.string`, que não ocupam posição entre os glifos.
        // Somá-lo esticava a seleção uma posição por linha do trecho — a sobra de ~3
        // caracteres que aparecia no fim de cada parágrafo.
        let estimateEnd = boundsIndex(for: NSMaxRange(range) - 1, in: pageText)

        for delta in probes {
            let start = estimate + delta
            let end = estimateEnd + delta

            for edge in SelectionEdge.allCases {
                guard let candidate = selection(on: page, boundsStart: start,
                                                boundsEnd: end, edge: edge),
                      let text = candidate.string else { continue }

                let got = collapsed(text)
                if got == wanted { return candidate }

                // Sem correspondência exata: prefere quem começa igual e, entre esses,
                // quem tem o comprimento mais próximo — é o que evita sobrar ou faltar
                // texto na ponta.
                let alignedStart = got.hasPrefix(head) || wanted.hasPrefix(String(got.prefix(24)))
                let score = (alignedStart ? 0 : 10_000) + abs(got.count - wanted.count)
                if best == nil || score < best!.score { best = (candidate, score, delta) }
            }
        }
        // Segunda tentativa: a sonda curta não alcançou. Em vez de varrer mais longe — o
        // desvio medido nos artigos chega a 200, e isto roda a cada palavra — mede-se a
        // distância a partir do que veio errado, e sonda-se de novo em volta do corrigido.
        if let anterior = best,
           let shift = drift(from: anterior.selection, usedDelta: anterior.delta,
                             wanted: range.location, in: pageText), shift != 0 {

            for delta in probes {
                let start = estimate + shift + delta
                let end = estimateEnd + shift + delta

                for edge in SelectionEdge.allCases {
                    guard let candidate = selection(on: page, boundsStart: start,
                                                    boundsEnd: end, edge: edge),
                          let text = candidate.string else { continue }

                    let got = collapsed(text)
                    if got == wanted { return candidate }

                    let alignedStart = got.hasPrefix(head) || wanted.hasPrefix(String(got.prefix(24)))
                    let score = (alignedStart ? 0 : 10_000) + abs(got.count - wanted.count)
                    if best == nil || score < best!.score { best = (candidate, score, shift + delta) }
                }
            }
        }

        // Melhor um realce ligeiramente torto do que nenhum.
        return best?.selection
    }

    /// Quanto a estimativa errou, lido do próprio texto que ela trouxe.
    ///
    /// A seleção obtida cobre algum ponto da página; achando esse ponto em `page.string`,
    /// a diferença até onde ela deveria começar é a correção — um cálculo, não uma
    /// varredura.
    ///
    /// A distância do token até o começo da seleção entra na conta. Sem ela a correção
    /// saía com o sinal trocado sempre que a âncora não era a primeira palavra: medido,
    /// o realce continuava abrindo na equação anterior.
    private static func drift(from candidate: PDFSelection,
                              usedDelta: Int,
                              wanted location: Int,
                              in pageText: NSString) -> Int? {
        guard let text = candidate.string as NSString? else { return nil }

        // Um token curto como "the" apareceria em toda parte; o primeiro longo o bastante
        // identifica a posição sem ambiguidade.
        var anchor: (token: String, offset: Int)?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: .byWords) { sub, range, _, stop in
            guard let sub, sub.count >= 5 else { return }
            anchor = (sub, range.location)
            stop.pointee = true
        }

        guard let anchor,
              let found = nearestOccurrence(of: anchor.token, to: location, in: pageText)
        else { return nil }

        return usedDelta + anchor.offset
            + boundsIndex(for: location, in: pageText)
            - boundsIndex(for: found, in: pageText)
    }

    /// Ocorrência mais próxima de `target`, não a primeira da página.
    ///
    /// Procurar a primeira já custou um realce deslocado ~70 caracteres antes: a palavra
    /// existia várias vezes na página e a busca parava na errada.
    private static func nearestOccurrence(of token: String, to target: Int, in pageText: NSString) -> Int? {
        let window = 3_000
        let start = max(0, target - window)
        let length = min(pageText.length - start, window * 2)
        guard length > 0 else { return nil }

        var best: Int?
        var searchFrom = start
        while searchFrom < start + length {
            let remaining = NSRange(location: searchFrom, length: start + length - searchFrom)
            let hit = pageText.range(of: token, options: [], range: remaining)
            guard hit.location != NSNotFound else { break }
            if best == nil || abs(hit.location - target) < abs(best! - target) { best = hit.location }
            searchFrom = hit.location + 1
        }
        return best
    }

    private enum SelectionEdge: CaseIterable {
        /// Encosta no começo do último glifo — não invade o caractere seguinte.
        case leading
        /// Encosta no fim do último glifo — garante incluir o último caractere.
        case trailing
    }

    /// Compara ignorando espaçamento.
    ///
    /// Um trecho de várias linhas nunca bate caractere a caractere: `page.string` traz as
    /// quebras onde a seleção do PDFKit traz espaços. Comparar cru fazia a verificação
    /// falhar sempre em parágrafos, cair no primeiro candidato e o realce "passar um
    /// pouco" do trecho lido.
    private static func sameText(_ candidate: String?, _ expected: String) -> Bool {
        guard let candidate else { return false }
        return collapsed(candidate) == collapsed(expected)
    }

    private static func collapsed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Estimativa do índice de bounds: as quebras de linha de `page.string` não ocupam
    /// posição na numeração dos glifos.
    static func boundsIndex(for stringIndex: Int, in pageText: NSString) -> Int {
        var breaks = 0
        for i in 0..<min(stringIndex, pageText.length) {
            let c = pageText.character(at: i)
            if c == 0x0A || c == 0x0D { breaks += 1 }
        }
        return stringIndex - breaks
    }

    private static func selection(on page: PDFPage, boundsStart: Int, boundsEnd: Int,
                                  edge: SelectionEdge) -> PDFSelection? {
        guard boundsStart >= 0, boundsEnd >= boundsStart,
              boundsEnd < page.numberOfCharacters else { return nil }

        let first = page.characterBounds(at: boundsStart)
        let last = page.characterBounds(at: boundsEnd)
        guard !first.isNull, !last.isNull else { return nil }

        let end = switch edge {
        case .leading: last.minX + min(1, last.width * 0.5)
        case .trailing: last.maxX
        }

        return page.selection(from: CGPoint(x: first.minX, y: first.midY),
                              to: CGPoint(x: end, y: last.midY))
    }

    // MARK: - Toque → texto

    /// Índice em `page.string` do caractere sob o ponto — ou do mais próximo dele.
    ///
    /// `PDFPage.characterIndex(at:)` devolve `NSNotFound` para qualquer toque que não
    /// caia exatamente sobre um glifo: margens, entrelinhas, o espaço entre colunas.
    /// Como o usuário mira no parágrafo e não na letra, quase todo toque cai fora — e
    /// tratar isso como "nada encontrado" fazia a leitura começar sempre no topo da
    /// página.
    public static func characterIndex(on page: PDFPage, at point: CGPoint, in pageText: NSString) -> Int? {
        guard page.numberOfCharacters > 0, pageText.length > 0 else { return nil }

        let direct = page.characterIndex(at: point)
        if direct != NSNotFound, direct >= 0, direct < page.numberOfCharacters {
            return stringIndex(forBounds: direct, on: page, in: pageText)
        }
        guard let nearest = nearestBoundsIndex(on: page, to: point) else { return nil }
        return stringIndex(forBounds: nearest, on: page, in: pageText)
    }

    /// Converte índice de bounds em índice de `page.string`, conferindo pelo texto.
    ///
    /// A estimativa por contagem de quebras erra — medido, às vezes por mais de uma
    /// posição — e aqui não há texto esperado para comparar como em `selection`. A saída
    /// é ler no PDF a palavra que começa naquele índice e procurá-la em volta da
    /// estimativa: o texto lido é a única fonte confiável.
    static func stringIndex(forBounds boundsIndex: Int, on page: PDFPage, in pageText: NSString) -> Int? {
        let estimate = stringIndex(forBounds: boundsIndex, in: pageText)

        let anchorLength = min(16, page.numberOfCharacters - boundsIndex)
        guard anchorLength > 2,
              let read = selection(on: page, boundsStart: boundsIndex,
                                   boundsEnd: boundsIndex + anchorLength - 1,
                                   edge: .trailing)?.string
        else { return estimate }

        // Só até o primeiro espaço: uma palavra não tem espaçamento interno para divergir.
        let anchor = String(read.prefix { !$0.isWhitespace })
        guard anchor.count >= 3, let estimate else { return estimate }

        let window = 200
        let low = max(0, estimate - window)
        let high = min(pageText.length, estimate + window)
        guard high > low else { return estimate }

        // A ocorrência MAIS PRÓXIMA da estimativa, não a primeira da janela: num artigo a
        // mesma palavra se repete a cada parágrafo, e pegar a primeira jogava a leitura
        // para o bloco anterior — o cabeçalho da revista, no caso relatado.
        var cursor = low
        var best: Int?
        while cursor < high {
            let found = pageText.range(of: anchor, options: [],
                                       range: NSRange(location: cursor, length: high - cursor))
            guard found.location != NSNotFound else { break }

            if best == nil || abs(found.location - estimate) < abs(best! - estimate) {
                best = found.location
            }
            cursor = found.location + 1
        }
        return best ?? estimate
    }

    /// Caractere cujo retângulo está mais perto do ponto.
    ///
    /// Percorre a página inteira, mas só quando o toque não acerta um glifo — uma vez
    /// por toque, sobre alguns milhares de caracteres.
    private static func nearestBoundsIndex(on page: PDFPage, to point: CGPoint) -> Int? {
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude

        for i in 0..<page.numberOfCharacters {
            let rect = page.characterBounds(at: i)
            guard !rect.isNull, rect.width > 0 || rect.height > 0 else { continue }

            let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
            let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
            // Distância vertical pesa mais: o usuário mira numa linha, e a coluna certa
            // importa menos do que a linha certa.
            let distance = Double(dx * dx) + Double(dy * dy) * 4

            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    /// Inverso de `boundsIndex(for:in:)`: reintroduz as quebras de linha puladas.
    static func stringIndex(forBounds boundsIndex: Int, in pageText: NSString) -> Int? {
        var seen = 0
        for i in 0..<pageText.length {
            let c = pageText.character(at: i)
            if c == 0x0A || c == 0x0D { continue }
            if seen == boundsIndex { return i }
            seen += 1
        }
        return pageText.length > 0 ? pageText.length - 1 : nil
    }
}
