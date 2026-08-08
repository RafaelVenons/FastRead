import Foundation
import Testing
@testable import FastReadCore

/// Equações em display interrompem o parágrafo e seriam lidas em voz alta. Os casos
/// abaixo vieram dos artigos reais em `BESS/` — o filtro tira a fórmula e deixa a prosa.
@Suite("MathFilter")
struct MathFilterTests {

    // MARK: - O que deve sair

    @Test("remove equação colada ao texto que a segue")
    func removeEquacaoNoComeco() {
        let resultado = MathFilter.strippingMath(from: "m =k(Qset−Q) where Qset is the reference")
        #expect(resultado.text.contains("where Qset is the reference"))
        #expect(resultado.text.contains("=") == false)
        #expect(resultado.didStrip)
    }

    @Test("remove sequência de fórmulas seguidas")
    func removeVariasFormulas() {
        let resultado = MathFilter.strippingMath(from: "θ=ω (3a) Q=vq id−vd iq (3b) and the result follows")
        #expect(resultado.text.contains("and the result follows"))
        #expect(resultado.text.contains("θ=ω") == false)
        #expect(resultado.text.contains("vq") == false)
    }

    @Test("remove fórmula com letras gregas e subscritos")
    func removeGregoESubscrito() {
        let resultado = MathFilter.strippingMath(from: "we define the vector rβ =rmod αβ,R +rmod αβ,N here")
        #expect(resultado.text.contains("we define the vector"))
        #expect(resultado.text.contains("here"))
        #expect(resultado.text.contains("rmod") == false)
    }

    @Test("remove fórmula no fim do trecho")
    func removeNoFim() {
        let resultado = MathFilter.strippingMath(from: "the output is obtained as ωg =Kp e+Ki")
        #expect(resultado.text.contains("the output is obtained as"))
        #expect(resultado.text.contains("Kp") == false)
    }

    // MARK: - O que deve ficar

    /// Nomes de variável aparecem em prosa o tempo todo nesses artigos. Tirá-los deixaria
    /// a frase falada com buraco.
    @Test("variável isolada em prosa fica")
    func variavelIsoladaFica() {
        let original = "after a sudden change of R, m should also depend linearly on the input"
        let resultado = MathFilter.strippingMath(from: original)
        #expect(resultado.text == original)
        #expect(resultado.didStrip == false)
    }

    @Test("texto sem matemática passa intacto")
    func textoNormalIntacto() {
        let original = "The reader highlights every word while the voice moves through the paragraph."
        #expect(MathFilter.strippingMath(from: original).text == original)
    }

    @Test("referências numéricas não são fórmula")
    func referenciasFicam() {
        let original = "as reported in [12] and [28], the method converges in most cases"
        #expect(MathFilter.strippingMath(from: original).text == original)
    }

    @Test("unidades e números em prosa ficam")
    func unidadesFicam() {
        let original = "the plant delivers 150 MW during peak hours and 40 MW at night"
        #expect(MathFilter.strippingMath(from: original).text == original)
    }

    @Test("frase que sobra continua legível")
    func sobraLegivel() {
        let resultado = MathFilter.strippingMath(from: "then m is regulated by m =k(Qset−Q) where Qset is the setpoint")
        // sem espaços duplicados nem pontuação solta na emenda
        #expect(resultado.text.contains("  ") == false)
        #expect(resultado.text.hasPrefix(" ") == false)
        #expect(resultado.text.contains("then m is regulated by"))
        #expect(resultado.text.contains("where Qset is the setpoint"))
    }

    @Test("trecho só de fórmula fica vazio")
    func soFormula() {
        let resultado = MathFilter.strippingMath(from: "θ=ω (3a) Q=vq id−vd iq")
        #expect(resultado.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("texto vazio não quebra")
    func vazio() {
        #expect(MathFilter.strippingMath(from: "").text.isEmpty)
        #expect(MathFilter.strippingMath(from: "   ").didStrip == false)
    }

    // MARK: - Fonte matemática mal decodificada

    /// Nem todo PDF entrega `=` e `+`. Em artigos compostos com certas fontes Type1 o
    /// PDFKit devolve `¼` no lugar de `=`, `þ` no lugar de `+` e `ð…Þ` no lugar dos
    /// parênteses. Contados no corpus, esses quatro caracteres aparecem **só** dentro de
    /// fórmula — em prosa científica em inglês eles não ocorrem.
    @Test("reconhece operadores de fonte mal decodificada")
    func operadoresMojibake() {
        #expect(MathFilter.isStrongMath("¼"))
        #expect(MathFilter.isStrongMath("þ"))
        #expect(MathFilter.isStrongMath("ð1Þ"))
    }

    /// Relatado em uso: Bevrani 2014, equação (1). O trecho começava com a fórmula inteira
    /// colada em "Since, actually…" e a voz recitava a notação antes do parágrafo.
    @Test("remove equação de PDF com fonte mal decodificada")
    func removeEquacaoMojibake() {
        let origem = "2HPg0 KI ¼ dDx dt þ KP Dx ð1Þ ð2Þ x0 Since, actually the initial rate "
            + "of frequency change just provide an error signal"
        let resultado = MathFilter.strippingMath(from: origem)

        #expect(resultado.text.hasPrefix("Since, actually the initial rate"))
        #expect(resultado.text.contains("¼") == false)
        #expect(resultado.text.contains("þ") == false)
        #expect(resultado.text.contains("ð1Þ") == false)
    }

    /// Letras matemáticas do Unicode (U+1D400…U+1D7FF) são itálico de fórmula, não texto:
    /// `𝑃𝐵𝐸𝑆𝑆` e `𝑆𝑂𝐶` não têm como ser palavra.
    @Test("reconhece letras matemáticas do Unicode")
    func letrasMatematicas() {
        #expect(MathFilter.isStrongMath("𝑃𝐵𝐸𝑆𝑆"))
        #expect(MathFilter.containsMathRun("the stored energy 𝑆𝑂𝐶𝑡+1 = 𝑃𝐺 𝑡 follows"))
        #expect(MathFilter.isStrongMath("SOC") == false)
    }

    /// Um intervalo de citação ou de páginas traz travessão e não é fórmula.
    @Test("intervalo com travessão não é fórmula")
    func travessaoNaoEhFormula() {
        #expect(MathFilter.containsMathRun("as reported in [1–3]. One of the fast responses") == false)
        #expect(MathFilter.containsMathRun("Energy Systems 54 (2014) 244–254 covers the topic") == false)
    }

    // MARK: - Detecção de trecho matemático

    /// Usado pelo invariante que mede o conteúdo falado, não a fronteira entre trechos.
    @Test("reconhece um trecho que contém fórmula")
    func reconheceFormula() {
        #expect(MathFilter.containsMathRun("the value is rβ =rmod αβ,R +rmod here"))
        #expect(MathFilter.containsMathRun("θ=ω (3a) Q=vq id−vd iq"))
    }

    @Test("não confunde prosa com fórmula")
    func naoConfundeProsa() {
        #expect(MathFilter.containsMathRun("after a sudden change of R, m should also depend") == false)
        #expect(MathFilter.containsMathRun("the plant delivers 150 MW during peak hours") == false)
        #expect(MathFilter.containsMathRun("as reported in [12] and [28], the method converges") == false)
    }
}

/// O filtro roda dentro da segmentação, então o mapa de índices tem de acompanhar: o
/// realce aponta para a página, e remover texto sem ajustar o mapa desloca o destaque.
@Suite("MathFilter no segmentador")
struct MathFilterSegmentationTests {

    private let segmenter = TextSegmenter()

    @Test("o trecho falado não traz a fórmula")
    func trechoSemFormula() throws {
        let origem = "The controller is tuned so that m =k(Qset−Q) where Qset is the reference value."
        let seg = try #require(segmenter.mappedSegments(from: origem).first)

        #expect(seg.text.contains("The controller is tuned so that"))
        #expect(seg.text.contains("where Qset is the reference value"))
        #expect(seg.text.contains("=") == false)
    }

    @Test("o mapa continua apontando para a página")
    func mapaAjustado() throws {
        let origem = "The controller is tuned so that m =k(Qset−Q) where Qset is the reference value."
        let seg = try #require(segmenter.mappedSegments(from: origem).first)
        let origemNS = origem as NSString

        // cada palavra do texto falado tem de cair sobre ela mesma na página
        let texto = seg.text as NSString
        for palavra in ["controller", "tuned", "reference"] {
            let noTrecho = texto.range(of: palavra)
            guard noTrecho.location != NSNotFound else { continue }
            let naPagina = try #require(seg.sourceRange(for: noTrecho))
            #expect(origemNS.substring(with: naPagina) == palavra,
                    "\(palavra) aponta para \(origemNS.substring(with: naPagina))")
        }
    }

    @Test("o mapa tem um índice por caractere, mesmo depois de remover")
    func mapaConsistente() throws {
        let seg = try #require(segmenter.mappedSegments(
            from: "we define rβ =rmod αβ,R +rmod αβ,N and proceed with the analysis").first)
        #expect(seg.sourceIndices.count == (seg.text as NSString).length)
    }
}
