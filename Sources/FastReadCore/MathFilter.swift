import Foundation

/// Tira equações de dentro de um trecho de texto.
///
/// Uma fórmula em display costuma vir colada ao texto que a segue — `"m =k(Qset−Q) where
/// Qset is the reference"` — e passa pelo filtro de conteúdo por trazer palavras reais
/// suficientes. O resultado é um parágrafo partido *e* uma fórmula sendo lida em voz alta.
///
/// Remover só a sequência devolve o parágrafo inteiro e cala a fórmula de uma vez.
public enum MathFilter {

    public struct Result: Sendable {
        public let text: String
        /// Quais posições do texto original sobreviveram, na ordem — para o mapa de
        /// índices do trecho acompanhar a remoção.
        public let keptRanges: [NSRange]
        public let didStrip: Bool
    }

    /// Quantos tokens matemáticos seguidos caracterizam uma fórmula.
    ///
    /// Dois, e não um: nomes de variável como `R`, `m` e `ω` aparecem em prosa o tempo
    /// todo nesses artigos, e remover um isolado deixaria buraco audível na frase.
    private static let minimumRun = 2

    // MARK: - Remoção

    public static func strippingMath(from text: String) -> Result {
        let ns = text as NSString
        let tokens = tokenize(ns)
        guard !tokens.isEmpty else {
            return Result(text: text, keptRanges: [NSRange(location: 0, length: ns.length)],
                          didStrip: false)
        }

        let removed = mathRuns(in: tokens, text: ns)
        guard !removed.isEmpty else {
            return Result(text: text, keptRanges: [NSRange(location: 0, length: ns.length)],
                          didStrip: false)
        }

        // Monta o que sobra, preservando de onde veio cada pedaço.
        var kept: [NSRange] = []
        var cursor = 0
        for range in removed {
            if range.location > cursor {
                kept.append(NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = NSMaxRange(range)
        }
        if cursor < ns.length {
            kept.append(NSRange(location: cursor, length: ns.length - cursor))
        }

        let joined = kept.map { ns.substring(with: $0) }
            .joined(separator: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return Result(text: joined, keptRanges: kept, didStrip: true)
    }

    /// O trecho contém uma fórmula? Usado pelo invariante que mede o conteúdo falado.
    public static func containsMathRun(_ text: String) -> Bool {
        let ns = text as NSString
        return !mathRuns(in: tokenize(ns), text: ns).isEmpty
    }

    // MARK: - Detecção

    private static func tokenize(_ text: NSString) -> [NSRange] {
        var tokens: [NSRange] = []
        var start: Int?

        for index in 0..<text.length {
            let isSpace = CharacterSet.whitespacesAndNewlines
                .contains(Unicode.Scalar(text.character(at: index)) ?? " ")
            if isSpace {
                if let begin = start { tokens.append(NSRange(location: begin, length: index - begin)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { tokens.append(NSRange(location: begin, length: text.length - begin)) }
        return tokens
    }

    /// Intervalos do texto ocupados por fórmulas.
    ///
    /// Uma sequência só conta se tiver ao menos um sinal forte: `"R, m"` em prosa são dois
    /// tokens que parecem variável, mas sem operador nenhum não formam equação.
    private static func mathRuns(in tokens: [NSRange], text: NSString) -> [NSRange] {
        var runs: [NSRange] = []
        var runStart: Int?
        var runLength = 0
        var runHasStrongSignal = false

        func closeRun(endingAt index: Int) {
            defer { runStart = nil; runLength = 0; runHasStrongSignal = false }
            guard let begin = runStart, runLength >= minimumRun, runHasStrongSignal else { return }
            let from = tokens[begin].location
            let to = NSMaxRange(tokens[index - 1])
            runs.append(NSRange(location: from, length: to - from))
        }

        for (index, range) in tokens.enumerated() {
            let token = text.substring(with: range)
            // Dentro de uma sequência já iniciada, tokens curtos são absorvidos: fazem
            // parte da equação mesmo quando isolados pareceriam palavra.
            let belongs = isMathematical(token) || (runStart != nil && absorbableIntoRun(token))

            if belongs {
                if runStart == nil { runStart = index }
                runLength += 1
                if isStrongMath(token) { runHasStrongSignal = true }
            } else {
                closeRun(endingAt: index)
            }
        }
        closeRun(endingAt: tokens.count)
        return runs
    }

    private static let mathSymbols = Set("=±∓×÷∑∫∂∇▽√≈≠≤≥⋅·∗∞→←↔∈∀∃−–—′^_|<>+")
    private static let greek = Set("αβγδεζηθικλμνξπρστυφχψωϵΓΔΘΛΞΠΣΦΨΩ")

    /// Operadores que chegam disfarçados de letra.
    ///
    /// Nem todo PDF entrega `=` e `+`: compostos com certas fontes Type1, o texto que o
    /// PDFKit devolve troca `=` por `¼`, `+` por `þ` e os parênteses por `ð…Þ`. Contados
    /// no corpus de artigos, esses caracteres aparecem **só** dentro de fórmula — em prosa
    /// científica em inglês eles não ocorrem, então valem como sinal forte.
    ///
    /// Sem isto a equação (1) de Bevrani 2014 passava inteira para a fala.
    private static let misdecodedOperators = Set("¼½¾þðÞ")

    /// Pedaços de chave e colchete de fórmula em display, que vêm como caracteres soltos.
    private static let displayBrackets = Set("⏞⏟⎧⎨⎩⎪⎡⎢⎣⎤⎦⃒")

    /// `y` conta como vogal aqui: sem isso "by" e "my" passariam por variável.
    private static let vowels = Set("aeiouyAEIOUY")

    /// Letras matemáticas do Unicode: itálico de fórmula, nunca palavra.
    ///
    /// `𝑃𝐵𝐸𝑆𝑆` e `𝑆𝑂𝐶𝑡` são compostos deste bloco (U+1D400…U+1D7FF), que também traz o
    /// grego matemático. Um caractere daqui basta para caracterizar fórmula.
    private static func isMathAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0x1D400...0x1D7FF).contains(Int(scalar.value))
    }

    /// Sinal forte: sozinho já caracteriza fórmula.
    ///
    /// Separado do fraco porque uma sequência de tokens curtos — `"R, m"` em prosa — não
    /// pode virar fórmula sem um operador ou letra grega por perto.
    static func isStrongMath(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        guard !trimmed.isEmpty else { return false }

        // Um intervalo de citação ou de páginas — `[1–3]`, `244–254` — traz travessão sem
        // ser fórmula. É o único uso de travessão que aparece cercado só de dígitos.
        if isNumericRange(trimmed) { return false }

        if trimmed.unicodeScalars.contains(where: isMathAlphanumeric) { return true }
        if trimmed.contains(where: { mathSymbols.contains($0) }) { return true }
        if trimmed.contains(where: { greek.contains($0) }) { return true }
        if trimmed.contains(where: { misdecodedOperators.contains($0) }) { return true }
        if trimmed.contains(where: { displayBrackets.contains($0) }) { return true }
        return false
    }

    private static func isNumericRange(_ token: String) -> Bool {
        let inner = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        guard inner.contains(where: { $0 == "–" || $0 == "—" || $0 == "-" }) else { return false }
        return inner.allSatisfy { $0.isNumber || $0 == "–" || $0 == "—" || $0 == "-" || $0 == "," }
    }

    /// Sinal fraco: parece variável, mas só entra na fórmula se houver um sinal forte
    /// na mesma sequência.
    static func isWeakMath(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        guard !trimmed.isEmpty else { return false }

        // Referência bibliográfica e numeração de equação são prosa.
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("(") {
            let inner = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
            if inner.allSatisfy({ $0.isNumber || $0 == "," || $0 == "-" }) { return false }
        }

        let letters = trimmed.filter(\.isLetter)
        guard !letters.isEmpty else { return false }

        // Sem vogal parece variável: `rβ`, `vq`, `Kp`, `id`, `rmod`.
        if !letters.contains(where: { vowels.contains($0) }) { return true }

        // Letra colada a dígito, curta demais para ser palavra com unidade: `h2`.
        let digits = trimmed.filter(\.isNumber).count
        if digits > 0 && letters.count <= 2 { return true }

        return false
    }

    static func isMathematical(_ token: String) -> Bool {
        isStrongMath(token) || isWeakMath(token)
    }

    /// Palavras curtas que carregam sentido na frase e nunca são variável.
    private static let functionWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "be", "of", "in", "on", "at", "to", "by",
        "as", "and", "or", "if", "it", "we", "he", "do", "so", "no", "not", "but", "for",
        "its", "our", "all", "can", "has", "may", "one", "two", "per", "via", "new", "use",
    ]

    /// Um token curto encostado numa fórmula quase sempre faz parte dela.
    ///
    /// `iq` e `id` em `"Q=vq id−vd iq"` têm vogal e escapariam da regra de variável, mas
    /// estão no meio da equação. Só as palavras funcionais resistem a essa absorção.
    private static func absorbableIntoRun(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]"))
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return !functionWords.contains(trimmed.lowercased())
    }
}
