import Foundation
import Testing
@testable import FastReadCore

/// O TTS lê o texto normalizado, mas o destaque tem que cair sobre o texto original da
/// página do PDF. Sem o mapa de índices, o realce apareceria deslocado — e o desvio
/// cresce a cada quebra de linha e a cada hífen removido.
@Suite("MappedSegment")
struct MappedSegmentTests {

    @Test("mapa tem um índice por caractere do texto normalizado")
    func tamanhoDoMapa() {
        let s = TextSegmenter()
        let origem = "Uma frase simples de teste."
        let segs = s.mappedSegments(from: origem)

        #expect(segs.count == 1)
        #expect(segs[0].sourceIndices.count == (segs[0].text as NSString).length)
    }

    @Test("sem normalização, os índices são idênticos")
    func identidadeQuandoNaoMuda() throws {
        let s = TextSegmenter()
        let origem = "Uma frase simples de teste."
        let seg = try #require(s.mappedSegments(from: origem).first)
        #expect(seg.sourceIndices == Array(0..<(origem as NSString).length))
    }

    @Test("após unir linhas, a palavra aponta para sua posição original")
    func mapeiaAposUniaoDeLinhas() throws {
        let s = TextSegmenter()
        let origem = "O leitor destaca\ncada palavra agora."
        let seg = try #require(s.mappedSegments(from: origem).first)

        // localiza "cada" no texto normalizado e confirma que aponta para "cada" no original
        let normalized = seg.text as NSString
        let range = normalized.range(of: "cada")
        let origemNS = origem as NSString
        let indiceOriginal = seg.sourceIndices[range.location]

        #expect(origemNS.substring(with: NSRange(location: indiceOriginal, length: 4)) == "cada")
    }

    @Test("após resolver hifenização, a palavra aponta para a primeira metade")
    func mapeiaAposHifenizacao() throws {
        let s = TextSegmenter()
        let origem = "Este é um exem-\nplo de hifenização."
        let seg = try #require(s.mappedSegments(from: origem).first)

        let normalized = seg.text as NSString
        let range = normalized.range(of: "exemplo")
        #expect(range.location != NSNotFound)

        let indiceOriginal = seg.sourceIndices[range.location]
        #expect((origem as NSString).substring(with: NSRange(location: indiceOriginal, length: 4)) == "exem")
    }

    @Test("converte um range do alinhamento para o range da página")
    func converteRange() throws {
        let s = TextSegmenter()
        let origem = "O leitor destaca\ncada palavra agora."
        let seg = try #require(s.mappedSegments(from: origem).first)

        let normalized = seg.text as NSString
        let alvo = normalized.range(of: "palavra")
        let naPagina = try #require(seg.sourceRange(for: alvo))

        #expect((origem as NSString).substring(with: naPagina) == "palavra")
    }

    @Test("range fora dos limites não converte")
    func rangeInvalido() throws {
        let s = TextSegmenter()
        let seg = try #require(s.mappedSegments(from: "Uma frase simples aqui.").first)
        #expect(seg.sourceRange(for: NSRange(location: 900, length: 3)) == nil)
        #expect(seg.sourceRange(for: NSRange(location: NSNotFound, length: 3)) == nil)
        #expect(seg.sourceRange(for: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("segundo parágrafo mapeia para sua posição real na página")
    func offsetDoSegundoParagrafo() throws {
        let s = TextSegmenter()
        let origem = """
        Primeiro parágrafo do documento inteiro.

        Segundo parágrafo com outro conteúdo.
        """
        let segs = s.mappedSegments(from: origem)
        #expect(segs.count == 2)

        let segundo = segs[1]
        let normalized = segundo.text as NSString
        let alvo = normalized.range(of: "Segundo")
        let naPagina = try #require(segundo.sourceRange(for: alvo))

        #expect((origem as NSString).substring(with: naPagina) == "Segundo")
        #expect(naPagina.location > 30, "precisa refletir o deslocamento do parágrafo anterior")
    }

    @Test("parágrafo quebrado por tamanho preserva o mapeamento de cada pedaço")
    func mapeamentoAposQuebraPorTamanho() throws {
        let s = TextSegmenter(maxCharacters: 60)
        let origem = "Primeira sentença de teste aqui. Segunda sentença de teste aqui. Terceira sentença final."
        let segs = s.mappedSegments(from: origem)
        #expect(segs.count >= 2)

        let origemNS = origem as NSString
        for seg in segs {
            let normalized = seg.text as NSString
            let primeiraPalavra = normalized.substring(to: min(8, normalized.length))
            let range = NSRange(location: 0, length: primeiraPalavra.utf16.count)
            let naPagina = try #require(seg.sourceRange(for: range))
            #expect(origemNS.substring(with: naPagina) == primeiraPalavra)
        }
    }

    @Test("espaços redundantes não desalinham o mapa")
    func espacosRedundantes() throws {
        let s = TextSegmenter()
        let origem = "Texto   com     espaços irregulares."
        let seg = try #require(s.mappedSegments(from: origem).first)

        let normalized = seg.text as NSString
        let alvo = normalized.range(of: "espaços")
        let naPagina = try #require(seg.sourceRange(for: alvo))
        #expect((origem as NSString).substring(with: naPagina) == "espaços")
    }

    @Test("texto acentuado mantém correspondência em UTF-16")
    func acentuacao() throws {
        let s = TextSegmenter()
        let origem = "A voz avança\npelo parágrafo até o fim."
        let seg = try #require(s.mappedSegments(from: origem).first)

        let normalized = seg.text as NSString
        let alvo = normalized.range(of: "parágrafo")
        let naPagina = try #require(seg.sourceRange(for: alvo))
        #expect((origem as NSString).substring(with: naPagina) == "parágrafo")
    }

    @Test("segments(from:) continua entregando o mesmo texto")
    func compatibilidadeComApiSimples() {
        let s = TextSegmenter()
        let origem = "Primeiro trecho aqui.\n\nSegundo trecho ali."
        #expect(s.segments(from: origem) == s.mappedSegments(from: origem).map(\.text))
    }
}
