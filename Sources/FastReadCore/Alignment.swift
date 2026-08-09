import Foundation

/// Uma palavra e o instante em que o sintetizador começa a pronunciá-la.
public struct WordTiming: Codable, Sendable, Equatable {
    public let word: String
    /// Posição no texto original do segmento, em unidades de `NSString` (UTF-16).
    public let location: Int
    public let length: Int
    /// Segundos desde o início do áudio do segmento.
    public let start: TimeInterval

    public init(word: String, location: Int, length: Int, start: TimeInterval) {
        self.word = word
        self.location = location
        self.length = length
        self.start = start
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// Alinhamento palavra-a-palavra de um segmento — o que permite destacar o texto
/// em sincronia com o áudio. Serializado ao lado do `.m4a` no cache.
public struct SegmentAlignment: Codable, Sendable, Equatable {
    public let words: [WordTiming]
    public let duration: TimeInterval

    public init(words: [WordTiming], duration: TimeInterval) {
        self.words = words
        self.duration = duration
    }

    /// Índice da palavra sendo pronunciada em `time`, ou `nil` fora do áudio.
    ///
    /// Busca binária porque isto é chamado a cada frame durante a reprodução.
    public func wordIndex(at time: TimeInterval) -> Int? {
        guard time >= 0, time <= duration, !words.isEmpty else { return nil }

        var low = 0
        var high = words.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Range de texto a destacar em `time`.
    public func range(at time: TimeInterval) -> NSRange? {
        wordIndex(at: time).map { words[$0].range }
    }

    /// Palavra a destacar agora, considerando se a reprodução ainda está correndo.
    ///
    /// Ao terminar, o `AVAudioPlayer` zera `currentTime`. Recalcular a partir dele faria o
    /// realce saltar para a primeira palavra do trecho — e a tela, que acompanha o
    /// realce, rolar de volta com ele. Parado, a última palavra permanece onde estava.
    public func highlightRange(at time: TimeInterval,
                               isPlaying: Bool,
                               previous: NSRange?) -> NSRange? {
        isPlaying ? range(at: time) : previous
    }

    /// Instante em que a fala alcança uma posição do texto.
    ///
    /// Permite começar a leitura na frase que o leitor tocou, aproveitando o áudio do
    /// trecho inteiro que já está em cache — sem sintetizar nada de novo.
    public func time(atTextIndex index: Int) -> TimeInterval? {
        guard !words.isEmpty else { return nil }
        guard let word = words.last(where: { $0.location <= index }) else { return words[0].start }
        return word.start
    }
}
