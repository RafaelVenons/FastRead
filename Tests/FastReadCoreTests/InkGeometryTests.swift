import CoreGraphics
import Testing
@testable import FastReadCore

/// A tela de desenho usa coordenadas do UIKit (origem no canto superior esquerdo, y para
/// baixo) e o PDF usa as suas (origem no inferior esquerdo, y para cima). Converter
/// errado espelha a anotação verticalmente — o traço aparece na parte oposta da página.
@Suite("InkGeometry")
struct InkGeometryTests {

    @Test("espelha o eixo vertical")
    func espelhaY() {
        let convertido = InkGeometry.pdfPoint(CGPoint(x: 100, y: 200), pageHeight: 792)
        #expect(convertido.x == 100)
        #expect(convertido.y == 592)
    }

    @Test("o topo da tela vira o topo da página")
    func topoViraTopo() {
        #expect(InkGeometry.pdfPoint(CGPoint(x: 0, y: 0), pageHeight: 792).y == 792)
    }

    @Test("o rodapé da tela vira a base da página")
    func rodapeViraBase() {
        #expect(InkGeometry.pdfPoint(CGPoint(x: 0, y: 792), pageHeight: 792).y == 0)
    }

    @Test("converter duas vezes devolve o ponto original")
    func idaEVolta() {
        let original = CGPoint(x: 42, y: 317)
        let ida = InkGeometry.pdfPoint(original, pageHeight: 792)
        let volta = InkGeometry.pdfPoint(ida, pageHeight: 792)
        #expect(volta == original)
    }

    // MARK: - Área da anotação

    @Test("envolve todos os pontos")
    func envolvePontos() {
        let pontos = [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 80), CGPoint(x: 30, y: 15)]
        let caixa = InkGeometry.bounds(of: pontos, lineWidth: 0)
        // Contém, não coincide: há sempre uma folga mínima para o traço não ser cortado.
        #expect(pontos.allSatisfy(caixa.contains))
        #expect(caixa.minX <= 10)
        #expect(caixa.maxY >= 80)
    }

    /// Sem folga, o PDFKit corta as bordas do traço: a caixa é do centro da linha, e
    /// metade da espessura fica para fora dela.
    @Test("abre folga proporcional à espessura")
    func folgaPelaEspessura() {
        let caixa = InkGeometry.bounds(of: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)], lineWidth: 4)
        #expect(caixa.minX <= 8)
        #expect(caixa.minY <= 8)
        #expect(caixa.maxX >= 22)
        #expect(caixa.maxY >= 22)
    }

    @Test("um único ponto ainda produz área desenhável")
    func pontoUnico() {
        let caixa = InkGeometry.bounds(of: [CGPoint(x: 30, y: 40)], lineWidth: 2)
        #expect(caixa.width > 0)
        #expect(caixa.height > 0)
        #expect(caixa.contains(CGPoint(x: 30, y: 40)))
    }

    @Test("sem pontos não há área")
    func semPontos() {
        #expect(InkGeometry.bounds(of: [], lineWidth: 2) == .null)
    }

    @Test("largura do traço vem da média das amostras, com mínimo utilizável")
    func larguraDoTraco() {
        #expect(InkGeometry.lineWidth(fromSizes: [4, 6, 8]) == 6)
        #expect(InkGeometry.lineWidth(fromSizes: []) >= 1)
        // uma pressão muito leve não pode produzir traço invisível
        #expect(InkGeometry.lineWidth(fromSizes: [0.05, 0.05]) >= 0.5)
    }
}
