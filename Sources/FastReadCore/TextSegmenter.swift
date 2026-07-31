import Foundation
import NaturalLanguage

/// Um trecho pronto para ler, junto com a rota de volta para o texto da página.
///
/// O sintetizador recebe `text` (normalizado), mas o destaque precisa cair sobre o
/// texto original do PDF. `sourceIndices` guarda, para cada unidade UTF-16 de `text`,
/// de onde ela veio — é o que permite converter o range de uma palavra do alinhamento
/// na posição correta dentro da página.
public struct MappedSegment: Sendable, Equatable {
    public let text: String
    /// Um índice na página por unidade UTF-16 de `text`.
    public let sourceIndices: [Int]

    public init(text: String, sourceIndices: [Int]) {
        self.text = text
        self.sourceIndices = sourceIndices
    }

    /// Posição no texto normalizado que corresponde a um índice da página.
    ///
    /// Caminho inverso do realce: serve para começar a leitura onde o dedo tocou, em vez
    /// de sempre do início do trecho. Índices sem correspondência exata — o hífen que
    /// sumiu, a quebra de linha virada espaço — resolvem para o caractere mais próximo.
    public func normalizedIndex(forSource sourceIndex: Int) -> Int? {
        guard !sourceIndices.isEmpty else { return nil }

        var best: Int?
        var bestDistance = Int.max
        for (normalized, source) in sourceIndices.enumerated() {
            let distance = abs(source - sourceIndex)
            if distance < bestDistance {
                bestDistance = distance
                best = normalized
            }
            if distance == 0 { break }
        }
        return best
    }

    /// Converte um range do texto normalizado no range correspondente da página.
    public func sourceRange(for range: NSRange) -> NSRange? {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= sourceIndices.count
        else { return nil }

        let slice = sourceIndices[range.location..<NSMaxRange(range)]
        guard let low = slice.min(), let high = slice.max() else { return nil }
        return NSRange(location: low, length: high - low + 1)
    }
}

/// Transforma o texto cru extraído de um PDF em trechos que fazem sentido ler em voz alta.
///
/// PDF não guarda parágrafos: guarda linhas posicionadas. O texto que sai do PDFKit vem
/// quebrado na largura da coluna e com palavras hifenizadas nas bordas, então ler
/// linha a linha soaria truncado.
public struct TextSegmenter: Sendable {

    /// Acima disto, o parágrafo é dividido em sentenças — segmentos enormes atrasam o
    /// primeiro som e tornam o toque menos preciso.
    public let maxCharacters: Int
    /// Abaixo disto, o trecho é tratado como ruído de diagramação.
    public let minCharacters: Int

    public init(maxCharacters: Int = 600, minCharacters: Int = 3) {
        self.maxCharacters = maxCharacters
        self.minCharacters = minCharacters
    }

    public func segments(from rawText: String) -> [String] {
        mappedSegments(from: rawText).map(\.text)
    }

    /// Percorre o texto uma única vez, decidindo em cada quebra de linha se ela encerra
    /// um trecho ou apenas continua o anterior.
    ///
    /// - Important: o PDFKit **colapsa linhas em branco**: um `\n\n` do documento
    ///   original chega aqui como `\n` simples (verificado gerando e reextraindo um PDF).
    ///   Por isso o limite de parágrafo não pode depender de linha em branco — se
    ///   dependesse, o documento inteiro viraria um segmento só.
    public func mappedSegments(from rawText: String) -> [MappedSegment] {
        let source = rawText as NSString
        var segments: [MappedSegment] = []

        var text = String.UnicodeScalarView()
        var indices: [Int] = []
        indices.reserveCapacity(source.length)

        func emit(_ unit: unichar, from origin: Int) {
            guard let scalar = Unicode.Scalar(unit) else { return }
            text.append(scalar)
            indices.append(origin)
        }

        func flush() {
            while text.last == " ", !indices.isEmpty {
                text.removeLast()
                indices.removeLast()
            }
            let candidate = MappedSegment(text: String(text), sourceIndices: indices)
            if isSpeakable(candidate.text) { segments.append(candidate) }
            text = String.UnicodeScalarView()
            indices = []
        }

        var i = 0
        while i < source.length {
            let c = source.character(at: i)

            // espaço horizontal: colapsa a corrida inteira num único separador
            if c == 0x20 || c == 0x09 {
                let origin = i
                while i < source.length,
                      source.character(at: i) == 0x20 || source.character(at: i) == 0x09 { i += 1 }
                if !text.isEmpty, text.last != " " { emit(0x20, from: origin) }
                continue
            }

            if c == 0x0A || c == 0x0D {
                let origin = i
                var newlines = 0
                while i < source.length, [0x0A, 0x0D, 0x20, 0x09].contains(source.character(at: i)) {
                    if source.character(at: i) == 0x0A { newlines += 1 }
                    i += 1
                }

                if text.last == "-" {
                    // Hífen no fim da linha seguido de minúscula é quebra silábica e some;
                    // seguido de maiúscula é nome composto e fica. Nos dois casos as
                    // metades se colam, sem espaço no meio.
                    let next = i < source.length ? source.character(at: i) : nil
                    let nextIsLowercase = next.flatMap { Unicode.Scalar($0) }
                        .map { Character($0).isLowercase } ?? false
                    if nextIsLowercase {
                        text.removeLast()
                        indices.removeLast()
                    }
                    continue
                }

                // Linha em branco separa quando sobrevive; senão, pontuação final é o
                // sinal disponível. Quebrar a mais só produz um segmento a mais — quebrar
                // a menos gruda parágrafos distintos num áudio só.
                if newlines >= 2 || endsSentence(text) {
                    flush()
                } else if !text.isEmpty, text.last != " " {
                    emit(0x20, from: origin)
                }
                continue
            }

            emit(c, from: i)
            i += 1
        }
        flush()

        return segments.flatMap(split(paragraph:))
    }

    /// O trecho termina numa fronteira de frase, ignorando fechamentos de citação.
    private func endsSentence(_ text: String.UnicodeScalarView) -> Bool {
        let closing: Set<Unicode.Scalar> = ["\"", "'", ")", "]", "}", "»", "”", "’"]
        let terminal: Set<Unicode.Scalar> = [".", "!", "?", "…"]

        for scalar in text.reversed() {
            if closing.contains(scalar) { continue }
            return terminal.contains(scalar)
        }
        return false
    }

    /// O trecho vale como fala?
    ///
    /// Além de números de página e filetes, descarta equações em display e texto
    /// rotacionado de figuras. Ler "ômega LPF L" ou "θ=ω (3a)" no meio de um parágrafo
    /// atrapalha mais do que ajuda, e esses blocos são justamente os que sobram cortando
    /// o texto corrido ao redor.
    private func isSpeakable(_ text: String) -> Bool {
        guard text.count >= minCharacters, text.contains(where: \.isLetter) else { return false }

        // Precisa de palavras de verdade, não símbolos soltos separados por espaço.
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        let realWords = words.filter { word in
            word.count >= 3 && word.filter(\.isLetter).count >= 3
        }
        guard realWords.count >= 2 else { return false }

        // E a maior parte do conteúdo tem de ser linguística.
        let meaningful = text.filter { $0.isLetter || $0.isWhitespace || $0.isPunctuation }
        return Double(meaningful.count) / Double(text.count) >= 0.75
    }

    // MARK: - Divisão por tamanho

    /// Divide por sentença, agrupando até `maxCharacters`, sem partir palavras.
    ///
    /// Cada pedaço é uma fatia contígua do parágrafo — assim o mapa de índices é apenas
    /// recortado, nunca recalculado.
    private func split(paragraph: MappedSegment) -> [MappedSegment] {
        let ns = paragraph.text as NSString
        guard paragraph.text.count > maxCharacters else { return [paragraph] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph.text

        var pieces: [NSRange] = []
        var current: NSRange?

        tokenizer.enumerateTokens(in: paragraph.text.startIndex..<paragraph.text.endIndex) { range, _ in
            let sentence = NSRange(range, in: paragraph.text)
            guard sentence.length > 0 else { return true }

            if let open = current {
                let merged = NSRange(location: open.location,
                                     length: NSMaxRange(sentence) - open.location)
                if merged.length <= self.maxCharacters {
                    current = merged
                } else {
                    pieces.append(open)
                    current = sentence
                }
            } else {
                current = sentence
            }
            return true
        }
        if let open = current { pieces.append(open) }

        // Uma única sentença acima do limite continua inteira: cortá-la partiria a frase.
        guard !pieces.isEmpty else { return [paragraph] }

        return pieces.compactMap { piece -> MappedSegment? in
            guard NSMaxRange(piece) <= ns.length,
                  NSMaxRange(piece) <= paragraph.sourceIndices.count else { return nil }
            let text = ns.substring(with: piece).trimmingCharacters(in: .whitespaces)
            guard isSpeakable(text) else { return nil }

            // o trim pode ter comido espaços à esquerda; realinha o recorte do mapa
            let leading = ns.substring(with: piece).prefix { $0 == " " }.count
            let start = piece.location + leading
            let length = (text as NSString).length
            guard start + length <= paragraph.sourceIndices.count else { return nil }

            return MappedSegment(text: text,
                                 sourceIndices: Array(paragraph.sourceIndices[start..<(start + length)]))
        }
    }
}
