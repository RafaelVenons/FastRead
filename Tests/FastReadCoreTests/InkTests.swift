import CoreGraphics
import Foundation
import Testing
@testable import FastReadCore

@Suite("InkPoint")
struct InkPointTests {

    @Test("guarda o que a Pencil informa")
    func guardaAtributos() {
        let ponto = InkPoint(location: CGPoint(x: 10, y: 20), force: 0.7,
                             altitude: .pi / 4, azimuth: 1.2, roll: 0.3)
        #expect(ponto.location == CGPoint(x: 10, y: 20))
        #expect(ponto.force == 0.7)
        #expect(ponto.altitude == .pi / 4)
    }

    /// Um toque sem força relatada (dedo, ou Pencil antes da estimativa chegar) não pode
    /// produzir traço invisível.
    @Test("força ausente vira pressão neutra")
    func forcaAusente() {
        #expect(InkPoint(location: .zero, force: 0).force > 0)
    }

    @Test("valores fora de faixa são contidos")
    func faixaLimitada() {
        #expect(InkPoint(location: .zero, force: 99).force <= 1)
        #expect(InkPoint(location: .zero, force: -5).force >= 0)
    }

    @Test("sobrevive a um roundtrip de JSON")
    func codable() throws {
        let original = InkPoint(location: CGPoint(x: 3, y: 4), force: 0.5,
                                altitude: 1, azimuth: 2, roll: 0.1)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(InkPoint.self, from: data) == original)
    }
}

@Suite("InkStroke")
struct InkStrokeTests {

    private func stroke(_ n: Int) -> InkStroke {
        InkStroke(points: (0..<n).map {
            InkPoint(location: CGPoint(x: Double($0) * 10, y: 0), force: 0.5)
        }, color: .init(red: 0, green: 0, blue: 0, alpha: 1), baseWidth: 3)
    }

    @Test("conhece sua extensão")
    func extensao() {
        let traco = stroke(5)
        #expect(traco.points.count == 5)
        #expect(traco.bounds.width > 0)
    }

    @Test("traço vazio não tem área")
    func vazio() {
        let vazio = InkStroke(points: [], color: .black, baseWidth: 2)
        #expect(vazio.bounds == .null)
        #expect(vazio.isEmpty)
    }

    @Test("um ponto só ainda desenha")
    func pontoUnico() {
        let ponto = InkStroke(points: [InkPoint(location: CGPoint(x: 5, y: 5), force: 1)],
                              color: .black, baseWidth: 4)
        #expect(!ponto.isEmpty)
        #expect(ponto.bounds.contains(CGPoint(x: 5, y: 5)))
    }

    @Test("a área envolve a espessura, não só os pontos")
    func areaIncluiEspessura() {
        let fino = InkStroke(points: stroke(3).points, color: .black, baseWidth: 1)
        let grosso = InkStroke(points: stroke(3).points, color: .black, baseWidth: 20)
        #expect(grosso.bounds.height > fino.bounds.height)
    }

    @Test("sobrevive a um roundtrip de JSON")
    func codable() throws {
        let original = stroke(4)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(InkStroke.self, from: data) == original)
    }
}

@Suite("InkDrawing")
struct InkDrawingTests {

    private func stroke(at x: Double) -> InkStroke {
        InkStroke(points: [InkPoint(location: CGPoint(x: x, y: 0), force: 0.5),
                           InkPoint(location: CGPoint(x: x + 10, y: 10), force: 0.5)],
                  color: .black, baseWidth: 2)
    }

    @Test("acumula traços na ordem em que foram feitos")
    func acumula() {
        var desenho = InkDrawing()
        desenho.append(stroke(at: 0))
        desenho.append(stroke(at: 50))

        #expect(desenho.strokes.count == 2)
        #expect(desenho.strokes[0].bounds.minX < desenho.strokes[1].bounds.minX)
    }

    @Test("desfazer remove o último e permite refazer")
    func desfazerRefazer() {
        var desenho = InkDrawing()
        desenho.append(stroke(at: 0))
        desenho.append(stroke(at: 50))

        #expect(desenho.canUndo)
        desenho.undo()
        #expect(desenho.strokes.count == 1)

        #expect(desenho.canRedo)
        desenho.redo()
        #expect(desenho.strokes.count == 2)
    }

    /// Um traço novo invalida o histórico de refazer, como em qualquer editor.
    @Test("desenhar depois de desfazer descarta o refazer")
    func novoTracoDescartaRefazer() {
        var desenho = InkDrawing()
        desenho.append(stroke(at: 0))
        desenho.undo()
        #expect(desenho.canRedo)

        desenho.append(stroke(at: 100))
        #expect(!desenho.canRedo)
        #expect(desenho.strokes.count == 1)
    }

    @Test("desfazer com desenho vazio não faz nada")
    func desfazerVazio() {
        var desenho = InkDrawing()
        #expect(!desenho.canUndo)
        desenho.undo()
        #expect(desenho.strokes.isEmpty)
    }

    @Test("limpar remove tudo, inclusive o histórico")
    func limpar() {
        var desenho = InkDrawing()
        desenho.append(stroke(at: 0))
        desenho.removeAll()

        #expect(desenho.strokes.isEmpty)
        #expect(!desenho.canUndo)
        #expect(!desenho.canRedo)
    }

    @Test("sobrevive a um roundtrip de JSON")
    func codable() throws {
        var original = InkDrawing()
        original.append(stroke(at: 0))
        original.append(stroke(at: 30))

        let data = try JSONEncoder().encode(original)
        let volta = try JSONDecoder().decode(InkDrawing.self, from: data)
        #expect(volta.strokes == original.strokes)
    }

    /// O histórico é de sessão: o que se guarda em disco são os traços.
    @Test("o histórico não é persistido")
    func historicoNaoPersiste() throws {
        var original = InkDrawing()
        original.append(stroke(at: 0))
        original.undo()

        let volta = try JSONDecoder().decode(InkDrawing.self,
                                             from: try JSONEncoder().encode(original))
        #expect(!volta.canRedo)
    }
}
