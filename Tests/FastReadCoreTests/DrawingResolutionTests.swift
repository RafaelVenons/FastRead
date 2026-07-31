import CoreGraphics
import Testing
@testable import FastReadCore

/// A tela de desenho tem o tamanho da página em pontos de PDF (612×792), mas aparece
/// escalada. Sem acompanhar essa escala, o traço é rasterizado na resolução da página e
/// depois ampliado — sai grosso e borrado, sem permitir escrita miúda.
@Suite("DrawingResolution")
struct DrawingResolutionTests {

    @Test("sem zoom, acompanha a densidade da tela")
    func semZoom() {
        #expect(DrawingResolution.contentScale(pdfScale: 1, screenScale: 2) == 2)
        #expect(DrawingResolution.contentScale(pdfScale: 1, screenScale: 3) == 3)
    }

    @Test("com zoom, multiplica para manter o traço nítido")
    func comZoom() {
        #expect(DrawingResolution.contentScale(pdfScale: 2, screenScale: 2) == 4)
        #expect(DrawingResolution.contentScale(pdfScale: 1.5, screenScale: 2) == 3)
    }

    /// Página inteira na tela reduz a escala; manter a densidade da tela evita que o
    /// traço nasça em resolução menor que a exibida depois de ampliar.
    @Test("com a página reduzida, não desce abaixo da densidade da tela")
    func paginaReduzida() {
        #expect(DrawingResolution.contentScale(pdfScale: 0.5, screenScale: 2) == 2)
        #expect(DrawingResolution.contentScale(pdfScale: 0.2, screenScale: 3) == 3)
    }

    /// Memória: a tela de cada página aloca por pixel, e um artigo tem dezenas delas.
    @Test("respeita um teto")
    func teto() {
        #expect(DrawingResolution.contentScale(pdfScale: 20, screenScale: 3) <= DrawingResolution.maximumScale)
        #expect(DrawingResolution.contentScale(pdfScale: 100, screenScale: 3) == DrawingResolution.maximumScale)
    }

    @Test("valores degenerados não produzem escala inválida")
    func degenerados() {
        #expect(DrawingResolution.contentScale(pdfScale: 0, screenScale: 2) == 2)
        #expect(DrawingResolution.contentScale(pdfScale: -3, screenScale: 2) == 2)
        #expect(DrawingResolution.contentScale(pdfScale: 1, screenScale: 0) == 1)
    }

    @Test("é monotônica no zoom até o teto")
    func monotonica() {
        let escalas = [0.5, 1.0, 1.5, 2.0, 2.5].map {
            DrawingResolution.contentScale(pdfScale: $0, screenScale: 2)
        }
        #expect(escalas == escalas.sorted())
    }
}
