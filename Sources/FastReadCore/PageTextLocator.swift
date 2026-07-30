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

    /// Desvios tentados em volta da estimativa, em ordem de plausibilidade.
    private static let probes = [0, -1, 1, -2, 2, -3, 3, -4, 4]

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

        var fallback: PDFSelection?
        for delta in probes {
            let start = estimate + delta
            guard start >= 0, start + range.length <= page.numberOfCharacters else { continue }
            guard let candidate = selection(on: page, boundsStart: start, length: range.length) else { continue }

            if candidate.string == expected { return candidate }
            if fallback == nil { fallback = candidate }
        }
        // Melhor um realce ligeiramente torto do que nenhum.
        return fallback
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

    private static func selection(on page: PDFPage, boundsStart: Int, length: Int) -> PDFSelection? {
        let first = page.characterBounds(at: boundsStart)
        let last = page.characterBounds(at: boundsStart + length - 1)
        guard !first.isNull, !last.isNull else { return nil }

        return page.selection(from: CGPoint(x: first.minX, y: first.midY),
                              to: CGPoint(x: last.maxX, y: last.midY))
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
            return stringIndex(forBounds: direct, in: pageText)
        }
        return nearestCharacterIndex(on: page, to: point, in: pageText)
    }

    /// Caractere cujo retângulo está mais perto do ponto.
    ///
    /// Percorre a página inteira, mas só quando o toque não acerta um glifo — uma vez
    /// por toque, sobre alguns milhares de caracteres.
    private static func nearestCharacterIndex(on page: PDFPage, to point: CGPoint, in pageText: NSString) -> Int? {
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
        return best.flatMap { stringIndex(forBounds: $0, in: pageText) }
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
