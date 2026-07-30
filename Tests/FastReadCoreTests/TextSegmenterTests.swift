import Foundation
import Testing
@testable import FastReadCore

@Suite("TextSegmenter")
struct TextSegmenterTests {

    @Test("separa parágrafos por linha em branco")
    func separaParagrafos() {
        let s = TextSegmenter()
        let texto = """
        Primeiro parágrafo com conteúdo suficiente para valer a leitura.

        Segundo parágrafo, também com conteúdo relevante para o teste.
        """
        let segs = s.segments(from: texto)
        #expect(segs.count == 2)
        #expect(segs[0].hasPrefix("Primeiro"))
        #expect(segs[1].hasPrefix("Segundo"))
    }

    @Test("une as quebras de linha internas do PDF")
    func uneLinhasQuebradas() {
        let s = TextSegmenter()
        // PDF quebra a linha por largura de coluna, não por fim de frase
        let texto = "O leitor de PDF destaca cada\npalavra enquanto a voz avança\npelo parágrafo."
        let segs = s.segments(from: texto)

        #expect(segs.count == 1)
        #expect(segs[0].contains("cada palavra"))
        #expect(segs[0].contains("avança pelo"))
        #expect(segs[0].contains("\n") == false)
    }

    @Test("resolve palavra hifenizada no fim da linha")
    func resolveHifenizacao() {
        let s = TextSegmenter()
        let segs = s.segments(from: "Este é um exem-\nplo de hifeniza-\nção automática do PDF.")
        #expect(segs[0].contains("exemplo"))
        #expect(segs[0].contains("hifenização"))
        #expect(segs[0].contains("- ") == false)
    }

    @Test("preserva hífen legítimo antes de palavra capitalizada")
    func preservaHifenLegitimo() {
        let s = TextSegmenter()
        let segs = s.segments(from: "Trabalho publicado por Silva-\nSantos em duas mil e vinte.")
        #expect(segs[0].contains("Silva-Santos"))
    }

    @Test("quebra parágrafo longo em sentenças")
    func quebraParagrafoLongo() {
        let s = TextSegmenter(maxCharacters: 90)
        let texto = "Primeira sentença bastante longa para ocupar espaço. "
            + "Segunda sentença igualmente longa para forçar a quebra. "
            + "Terceira sentença para fechar o parágrafo inteiro."
        let segs = s.segments(from: texto)

        #expect(segs.count >= 2)
        #expect(segs.allSatisfy { $0.count <= 120 })
    }

    @Test("nunca corta no meio de uma palavra")
    func naoCortaPalavra() {
        let s = TextSegmenter(maxCharacters: 50)
        let texto = String(repeating: "palavra teste alinhamento sintetizador ", count: 10)
        let segs = s.segments(from: texto)

        for seg in segs {
            #expect(seg.hasPrefix(" ") == false)
            #expect(seg.hasSuffix(" ") == false)
        }
        // nenhuma palavra pode ter sido partida
        let reconstruido = segs.joined(separator: " ")
        #expect(reconstruido.split(separator: " ").allSatisfy {
            ["palavra", "teste", "alinhamento", "sintetizador"].contains(String($0))
        })
    }

    @Test("normaliza espaços redundantes")
    func normalizaEspacos() {
        let s = TextSegmenter()
        let segs = s.segments(from: "Texto   com     espaços \t irregulares no meio da frase.")
        #expect(segs[0] == "Texto com espaços irregulares no meio da frase.")
    }

    @Test("descarta ruído sem conteúdo falável")
    func descartaRuido() {
        let s = TextSegmenter()
        let texto = """
        Parágrafo de verdade com conteúdo que deve ser lido em voz alta.

        42

        ———

        Outro parágrafo real logo em seguida do ruído acima.
        """
        let segs = s.segments(from: texto)
        #expect(segs.count == 2)
        #expect(segs.contains { $0.contains("42") } == false)
    }

    @Test("texto vazio não gera segmentos")
    func textoVazio() {
        let s = TextSegmenter()
        #expect(s.segments(from: "").isEmpty)
        #expect(s.segments(from: "   \n\n  \t ").isEmpty)
    }

    @Test("não perde conteúdo ao segmentar")
    func naoPerdeConteudo() {
        let s = TextSegmenter(maxCharacters: 80)
        let texto = "Uma frase inicial. Outra frase no meio. E a frase final do bloco."
        let segs = s.segments(from: texto)

        let palavrasOriginais = texto.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        let palavrasSegmentadas = segs.flatMap { $0.split(separator: " ") }.count
        #expect(palavrasSegmentadas == palavrasOriginais)
    }

    @Test("um parágrafo curto continua inteiro")
    func paragrafoCurtoIntacto() {
        let s = TextSegmenter(maxCharacters: 600)
        let texto = "Frase curta e única."
        #expect(s.segments(from: texto) == [texto])
    }
}
