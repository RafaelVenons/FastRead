import Testing
@testable import FastReadCore

// Medições que motivam estes testes (macOS 26.4, NLLanguageRecognizer):
//   "Figure 3."  -> 41.5% sem constraints, 92.4% com constraints
//   "The transformer architecture, proposto por Vaswani..." -> pt 97.9% (falso positivo)

private let english = "The quick analysis of neural networks reveals that gradient descent converges under mild assumptions on the loss surface."
private let portuguese = "O leitor de PDF destaca cada palavra enquanto a voz avança pelo parágrafo selecionado pelo usuário."
private let spanish = "El analisis de redes neuronales revela que el descenso de gradiente converge bajo supuestos moderados."

@Suite("LanguageDetector")
struct LanguageDetectorTests {

    @Test("identifica idioma de texto longo com alta confiança")
    func detectaTextoLongo() throws {
        let d = LanguageDetector()
        #expect(try #require(d.detect(english)).language == "en")
        #expect(try #require(d.detect(portuguese)).language == "pt")
        #expect(try #require(d.detect(spanish)).language == "es")
        #expect(try #require(d.detect(english)).confidence > 0.9)
    }

    @Test("constraints elevam a confiança em trechos curtos")
    func constraintsAjudamTextoCurto() throws {
        let irrestrito = LanguageDetector(constraints: [])
        let restrito = LanguageDetector(constraints: ["en", "pt", "es"])
        let curto = "Figure 3."

        let a = try #require(irrestrito.detect(curto))
        let b = try #require(restrito.detect(curto))
        #expect(b.confidence > a.confidence)
        #expect(b.language == "en")
    }

    @Test("texto vazio ou só pontuação não produz resultado")
    func textoVazio() {
        let d = LanguageDetector()
        #expect(d.detect("") == nil)
        #expect(d.detect("   \n  ") == nil)
        #expect(d.detect("...---") == nil)
    }

    // --- política documento vs segmento ---

    @Test("segmento curto herda o idioma do documento")
    func segmentoCurtoHerda() {
        let d = LanguageDetector()
        // "Table 2: Results" isolado daria "en", mas é curto demais para sobrepor um doc pt
        #expect(d.language(forSegment: "Table 2: Results", documentLanguage: "pt") == "pt")
        #expect(d.language(forSegment: "Figure 3.", documentLanguage: "pt") == "pt")
    }

    @Test("segmento longo e confiante sobrepõe o idioma do documento")
    func segmentoLongoSobrepoe() {
        let d = LanguageDetector()
        #expect(d.language(forSegment: portuguese, documentLanguage: "en") == "pt")
        #expect(d.language(forSegment: english, documentLanguage: "pt") == "en")
    }

    @Test("segmento vazio herda o idioma do documento")
    func segmentoVazioHerda() {
        let d = LanguageDetector()
        #expect(d.language(forSegment: "", documentLanguage: "en") == "en")
    }

    @Test("idioma do documento vem da amostragem de várias páginas")
    func idiomaDoDocumentoPorAmostragem() {
        let d = LanguageDetector()
        let paginas = ["Figure 1.", english, "Table 2: Results", english, "[12] Vaswani et al."]
        #expect(d.documentLanguage(sampling: paginas) == "en")
    }

    @Test("documento sem texto utilizável cai no fallback")
    func documentoSemTexto() {
        let d = LanguageDetector()
        #expect(d.documentLanguage(sampling: ["", "  ", "..."], fallback: "en") == "en")
        #expect(d.documentLanguage(sampling: [], fallback: "pt") == "pt")
    }

    @Test("amostragem respeita o limite de caracteres")
    func amostragemLimitada() {
        let d = LanguageDetector(sampleLimit: 100)
        let paginas = Array(repeating: english, count: 50)
        // não deve travar nem crescer com o número de páginas
        #expect(d.documentLanguage(sampling: paginas) == "en")
    }
}
