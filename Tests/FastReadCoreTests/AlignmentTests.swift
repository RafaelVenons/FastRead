import Foundation
import Testing
@testable import FastReadCore

// Tempos reais medidos com a voz compact pt-BR, para o texto
// "O leitor de PDF destaca cada palavra..."
private let sample = SegmentAlignment(
    words: [
        WordTiming(word: "O",       location: 0,  length: 1, start: 0.000),
        WordTiming(word: "leitor",  location: 2,  length: 6, start: 0.151),
        WordTiming(word: "de",      location: 9,  length: 2, start: 0.592),
        WordTiming(word: "PDF",     location: 12, length: 3, start: 0.778),
        WordTiming(word: "destaca", location: 16, length: 7, start: 1.416),
    ],
    duration: 2.0
)

@Suite("SegmentAlignment")
struct SegmentAlignmentTests {

    @Test("localiza a palavra ativa em um instante")
    func palavraAtiva() {
        #expect(sample.wordIndex(at: 0.000) == 0)
        #expect(sample.wordIndex(at: 0.100) == 0)
        #expect(sample.wordIndex(at: 0.151) == 1)   // limite exato pertence à nova palavra
        #expect(sample.wordIndex(at: 0.300) == 1)
        #expect(sample.wordIndex(at: 0.592) == 2)
        #expect(sample.wordIndex(at: 1.500) == 4)
        #expect(sample.wordIndex(at: 1.999) == 4)
    }

    @Test("fora do intervalo não retorna palavra")
    func foraDoIntervalo() {
        #expect(sample.wordIndex(at: -0.5) == nil)
        #expect(sample.wordIndex(at: 2.5) == nil)
        #expect(SegmentAlignment(words: [], duration: 1).wordIndex(at: 0.5) == nil)
    }

    @Test("expõe o range de texto para destacar")
    func rangeParaDestaque() throws {
        let r = try #require(sample.range(at: 0.300))
        #expect(r.location == 2)
        #expect(r.length == 6)
        #expect(sample.range(at: 99) == nil)
    }

    @Test("sobrevive a um roundtrip de JSON")
    func codableRoundtrip() throws {
        let data = try JSONEncoder().encode(sample)
        let back = try JSONDecoder().decode(SegmentAlignment.self, from: data)
        #expect(back == sample)
    }

    @Test("busca é consistente em alinhamento grande")
    func buscaEmAlinhamentoGrande() {
        let words = (0..<5_000).map {
            WordTiming(word: "w\($0)", location: $0 * 3, length: 2, start: Double($0) * 0.3)
        }
        let big = SegmentAlignment(words: words, duration: 5_000 * 0.3)
        #expect(big.wordIndex(at: 0.0) == 0)
        #expect(big.wordIndex(at: 750.0) == 2500)
        #expect(big.wordIndex(at: 1499.9) == 4999)
    }
}

@Suite("SegmentKey")
struct SegmentKeyTests {

    @Test("mesma entrada gera a mesma chave")
    func chaveEstavel() {
        let a = SegmentKey(text: "Hello world", voiceIdentifier: "com.apple.voice.compact.en-US.Samantha", rate: 0.5)
        let b = SegmentKey(text: "Hello world", voiceIdentifier: "com.apple.voice.compact.en-US.Samantha", rate: 0.5)
        #expect(a == b)
        #expect(a.value == b.value)
    }

    @Test("texto, voz ou velocidade diferentes geram chaves diferentes")
    func chaveDiscrimina() {
        let base = SegmentKey(text: "Hello world", voiceIdentifier: "voz.a", rate: 0.5)
        #expect(base != SegmentKey(text: "Hello worlds", voiceIdentifier: "voz.a", rate: 0.5))
        #expect(base != SegmentKey(text: "Hello world", voiceIdentifier: "voz.b", rate: 0.5))
        #expect(base != SegmentKey(text: "Hello world", voiceIdentifier: "voz.a", rate: 0.6))
    }

    @Test("chave é segura como nome de arquivo")
    func chaveUsavelComoNomeDeArquivo() {
        let k = SegmentKey(text: "Ação / caminho: \"aspas\" \n quebra", voiceIdentifier: "voz/../x", rate: 0.5)
        let permitido = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(k.value.unicodeScalars.allSatisfy(permitido.contains))
        #expect(k.value.count == 64)
    }

    @Test("espaços em volta não mudam a chave")
    func normalizaEspacos() {
        let a = SegmentKey(text: "Hello world", voiceIdentifier: "v", rate: 0.5)
        let b = SegmentKey(text: "  Hello world\n", voiceIdentifier: "v", rate: 0.5)
        #expect(a == b)
    }

    @Test("diferenças de velocidade abaixo da resolução audível não invalidam o cache")
    func rateArredondado() {
        let a = SegmentKey(text: "x y z", voiceIdentifier: "v", rate: 0.5000)
        let b = SegmentKey(text: "x y z", voiceIdentifier: "v", rate: 0.5001)
        #expect(a == b)
    }
}
