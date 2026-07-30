import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FastReadCore

@Suite("Hifenização entre blocos")
struct HyphenBlockTests {

    private func line(_ range: NSRange, _ frame: CGRect) -> PageLine {
        PageLine(range: range, frame: frame)
    }

    /// Medido num artigo real: 15 de 89 linhas terminam com hífen. Uma delas caía na
    /// fronteira de coluna, e o trecho terminava em "relia-" com o seguinte começando
    /// em "bility".
    @Test("linha terminada em hífen não encerra o bloco")
    func hifenSeguraOBloco() {
        let texto = "voltage, frequency, and relia-\nbility profiles of power grids." as NSString
        let anterior = line(NSRange(location: 0, length: 30), CGRect(x: 48, y: 700, width: 200, height: 10))
        // a linha seguinte está longe e mais acima — geometria de troca de coluna
        let seguinte = line(NSRange(location: 31, length: 31), CGRect(x: 320, y: 740, width: 200, height: 10))

        #expect(PageLayoutAnalyzer.startsNewBlock(previous: anterior, line: seguinte,
                                                  bodyHeight: 10, text: texto) == false)
    }

    @Test("sem hífen e com frase fechada, a troca de coluna encerra o bloco")
    func semHifenQuebra() {
        let texto = "voltage, frequency, and safety.\nBility profiles of power grids." as NSString
        let anterior = line(NSRange(location: 0, length: 30), CGRect(x: 48, y: 700, width: 200, height: 10))
        let seguinte = line(NSRange(location: 31, length: 31), CGRect(x: 320, y: 740, width: 200, height: 10))

        #expect(PageLayoutAnalyzer.startsNewBlock(previous: anterior, line: seguinte,
                                                  bodyHeight: 10, text: texto) == true)
    }

    /// Relatado no artigo: um trecho terminava em "...from the technology and system" e o
    /// seguinte era só "points of view." — a frase seguia na outra coluna.
    @Test("frase inacabada continua na outra coluna")
    func fraseInacabadaAtravessaColuna() {
        let texto = "examined from the technology and system\npoints of view." as NSString
        let anterior = line(NSRange(location: 0, length: 38), CGRect(x: 48, y: 420, width: 200, height: 10))
        let seguinte = line(NSRange(location: 39, length: 15), CGRect(x: 320, y: 740, width: 200, height: 10))

        #expect(PageLayoutAnalyzer.startsNewBlock(previous: anterior, line: seguinte,
                                                  bodyHeight: 10, text: texto) == false)
    }

    @Test("frase fechada permite a quebra por coluna")
    func fraseFechadaQuebra() {
        let texto = "examined from the technology and systems.\npoints of view here." as NSString
        let anterior = line(NSRange(location: 0, length: 41), CGRect(x: 48, y: 420, width: 200, height: 10))
        let seguinte = line(NSRange(location: 42, length: 20), CGRect(x: 320, y: 740, width: 200, height: 10))

        #expect(PageLayoutAnalyzer.startsNewBlock(previous: anterior, line: seguinte,
                                                  bodyHeight: 10, text: texto) == true)
    }

    /// Um título de seção também não termina em ponto; o que o distingue de uma frase
    /// interrompida é começar em maiúscula.
    @Test("título de seção não gruda no parágrafo anterior")
    func tituloNaoGruda() {
        let texto = "reduced congestions and costs\n2 Introduction to the method" as NSString
        let anterior = line(NSRange(location: 0, length: 29), CGRect(x: 48, y: 420, width: 200, height: 10))
        let seguinte = line(NSRange(location: 30, length: 27), CGRect(x: 320, y: 740, width: 200, height: 10))

        #expect(PageLayoutAnalyzer.startsNewBlock(previous: anterior, line: seguinte,
                                                  bodyHeight: 10, text: texto) == true)
    }

    @Test("mudança de corpo de letra separa mesmo com frase aberta")
    func fonteMaiorSempreSepara() {
        let texto = "authors and affiliation listed above\ntitle of the article here" as NSString
        let anterior = line(NSRange(location: 0, length: 35), CGRect(x: 48, y: 700, width: 200, height: 8))
        let seguinte = line(NSRange(location: 36, length: 25), CGRect(x: 48, y: 670, width: 200, height: 15))

        #expect(PageLayoutAnalyzer.startsNewBlock(previous: anterior, line: seguinte,
                                                  bodyHeight: 8, text: texto) == true)
    }

    @Test("hífen isolado não é palavra partida")
    func hifenIsoladoNaoSegura() {
        let texto = "item um -\nItem dois aqui" as NSString
        let anterior = line(NSRange(location: 0, length: 9), CGRect(x: 48, y: 700, width: 200, height: 10))
        let seguinte = line(NSRange(location: 10, length: 14), CGRect(x: 320, y: 740, width: 200, height: 10))

        #expect(PageLayoutAnalyzer.startsNewBlock(previous: anterior, line: seguinte,
                                                  bodyHeight: 10, text: texto) == true)
    }
}

@Suite("Começar no ponto tocado")
struct SeekTests {

    private let segmenter = TextSegmenter()

    @Test("converte índice da página em posição no texto do trecho")
    func indiceInverso() throws {
        let origem = "O leitor destaca\ncada palavra agora."
        let seg = try #require(segmenter.mappedSegments(from: origem).first)

        let origemNS = origem as NSString
        let naPagina = origemNS.range(of: "palavra")
        let noTrecho = try #require(seg.normalizedIndex(forSource: naPagina.location))

        let texto = seg.text as NSString
        #expect(texto.substring(from: noTrecho).hasPrefix("palavra"))
    }

    @Test("ida e volta entre trecho e página é consistente")
    func idaEVolta() throws {
        let origem = "Primeira frase do bloco.\nSegunda frase do mesmo bloco aqui."
        let seg = try #require(segmenter.mappedSegments(from: origem).first)
        let texto = seg.text as NSString

        for palavra in ["Primeira", "bloco", "Segunda", "aqui"] {
            let noTrecho = texto.range(of: palavra)
            guard noTrecho.location != NSNotFound else { continue }
            let naPagina = try #require(seg.sourceRange(for: noTrecho))
            let volta = try #require(seg.normalizedIndex(forSource: naPagina.location))
            #expect(volta == noTrecho.location, "\(palavra): \(noTrecho.location) -> \(volta)")
        }
    }

    @Test("índice sem correspondência exata cai no mais próximo")
    func indiceAproximado() throws {
        // o hífen desaparece na normalização e não tem posição própria no trecho
        let seg = try #require(segmenter.mappedSegments(from: "Este é um exem-\nplo de texto.").first)
        let hifen = 14   // posição do "-" no original
        let aproximado = try #require(seg.normalizedIndex(forSource: hifen))
        #expect(aproximado >= 0)
        #expect(aproximado < (seg.text as NSString).length)
    }

    @Test("trecho vazio não resolve índice")
    func trechoVazio() {
        #expect(MappedSegment(text: "", sourceIndices: []).normalizedIndex(forSource: 5) == nil)
    }

    // MARK: - Tempo a partir da posição

    private let alinhamento = SegmentAlignment(
        words: [
            WordTiming(word: "Primeira", location: 0, length: 8, start: 0.0),
            WordTiming(word: "frase", location: 9, length: 5, start: 0.5),
            WordTiming(word: "do", location: 15, length: 2, start: 0.9),
            WordTiming(word: "bloco.", location: 18, length: 6, start: 1.2),
        ],
        duration: 2.0)

    @Test("encontra o instante da palavra numa posição do texto")
    func tempoDaPosicao() throws {
        #expect(try #require(alinhamento.time(atTextIndex: 0)) == 0.0)
        #expect(try #require(alinhamento.time(atTextIndex: 10)) == 0.5)   // dentro de "frase"
        #expect(try #require(alinhamento.time(atTextIndex: 16)) == 0.9)   // dentro de "do"
        #expect(try #require(alinhamento.time(atTextIndex: 20)) == 1.2)
    }

    @Test("posição antes da primeira palavra começa do início")
    func antesDoInicio() throws {
        #expect(try #require(alinhamento.time(atTextIndex: -5)) == 0.0)
    }

    @Test("posição além do fim usa a última palavra")
    func alemDoFim() throws {
        #expect(try #require(alinhamento.time(atTextIndex: 999)) == 1.2)
    }

    @Test("alinhamento vazio não devolve instante")
    func alinhamentoVazio() {
        #expect(SegmentAlignment(words: [], duration: 1).time(atTextIndex: 0) == nil)
    }
}
