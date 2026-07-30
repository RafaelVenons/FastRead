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

    public func mappedSegments(from rawText: String) -> [MappedSegment] {
        let source = rawText as NSString
        return paragraphRanges(in: source)
            .map { normalize(source, in: $0) }
            .filter { isSpeakable($0.text) }
            .flatMap(split(paragraph:))
    }

    // MARK: - Parágrafos

    /// Linha em branco é o único indício confiável de parágrafo em texto de PDF.
    private func paragraphRanges(in source: NSString) -> [NSRange] {
        let separators = try? NSRegularExpression(pattern: "\\n[ \\t]*\\n[ \\t\\n]*")
        let full = NSRange(location: 0, length: source.length)
        guard let separators else { return [full] }

        var ranges: [NSRange] = []
        var cursor = 0
        for match in separators.matches(in: source as String, range: full) {
            if match.range.location > cursor {
                ranges.append(NSRange(location: cursor, length: match.range.location - cursor))
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            ranges.append(NSRange(location: cursor, length: source.length - cursor))
        }
        return ranges
    }

    // MARK: - Normalização com rastreamento de origem

    /// Junta as linhas do parágrafo numa frase contínua, registrando a origem de cada
    /// caractere emitido.
    private func normalize(_ source: NSString, in range: NSRange) -> MappedSegment {
        var text = String.UnicodeScalarView()
        var indices: [Int] = []
        indices.reserveCapacity(range.length)

        var i = range.location
        let end = NSMaxRange(range)

        func emit(_ unit: unichar, from origin: Int) {
            guard let scalar = Unicode.Scalar(unit) else { return }
            text.append(scalar)
            indices.append(origin)
        }

        func lastIsSpace() -> Bool { text.last == " " }

        while i < end {
            let c = source.character(at: i)

            // espaço horizontal: colapsa a corrida inteira num único separador
            if c == 0x20 || c == 0x09 {
                let origin = i
                while i < end, source.character(at: i) == 0x20 || source.character(at: i) == 0x09 { i += 1 }
                if !text.isEmpty && !lastIsSpace() { emit(0x20, from: origin) }
                continue
            }

            // quebra de linha dentro do parágrafo
            if c == 0x0A || c == 0x0D {
                let origin = i
                while i < end, [0x0A, 0x0D, 0x20, 0x09].contains(source.character(at: i)) { i += 1 }

                let next: unichar? = i < end ? source.character(at: i) : nil
                let nextIsLowercase = next.flatMap { Unicode.Scalar($0) }
                    .map { Character($0).isLowercase } ?? false

                if text.last == "-" {
                    // Hífen no fim da linha seguido de minúscula é quebra silábica e some;
                    // seguido de maiúscula é nome composto e fica. Nos dois casos as
                    // metades se colam, sem espaço no meio.
                    if nextIsLowercase {
                        text.removeLast()
                        indices.removeLast()
                    }
                } else if !text.isEmpty && !lastIsSpace() {
                    emit(0x20, from: origin)
                }
                continue
            }

            emit(c, from: i)
            i += 1
        }

        // apara o separador final, se sobrou algum
        while text.last == " " { text.removeLast(); indices.removeLast() }

        return MappedSegment(text: String(text), sourceIndices: indices)
    }

    /// Números de página, filetes e marcas de diagramação não devem virar áudio.
    private func isSpeakable(_ text: String) -> Bool {
        text.count >= minCharacters && text.contains(where: \.isLetter)
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
