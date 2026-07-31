import CoreGraphics
import Foundation
import Testing
@testable import FastReadCore

private func point(_ x: Double, _ y: Double, force: Double = 0.5) -> InkPoint {
    InkPoint(location: CGPoint(x: x, y: y), force: force)
}

private func line(_ n: Int) -> [InkPoint] {
    (0..<n).map { point(Double($0) * 3, sin(Double($0) / 5) * 20) }
}

/// Recalcular o contorno inteiro a cada frame faz a latência crescer com o tamanho do
/// traço: a suavização multiplica os pontos por seis, e um traço longo passa a custar
/// milhares de operações por quadro. A divisão em parte consolidada e cauda mantém o
/// custo por quadro constante.
@Suite("Traço incremental")
struct InkIncrementalTests {

    @Test("separa os pontos em parte consolidada e cauda")
    func separa() {
        let split = InkPath.split(line(100), tailLength: 24)
        #expect(split.settled.count > 0)
        #expect(split.tail.count >= 24)
    }

    @Test("a cauda tem tamanho limitado, independente do traço")
    func caudaConstante() {
        let curto = InkPath.split(line(40), tailLength: 24)
        let longo = InkPath.split(line(4000), tailLength: 24)
        #expect(longo.tail.count == curto.tail.count)
    }

    @Test("traço curto fica todo na cauda")
    func curtoTodoNaCauda() {
        let split = InkPath.split(line(10), tailLength: 24)
        #expect(split.settled.isEmpty)
        #expect(split.tail.count == 10)
    }

    /// As partes têm de se sobrepor num ponto, senão aparece uma falha na emenda.
    @Test("as partes se sobrepõem para não deixar buraco")
    func sobrepoe() throws {
        let pontos = line(100)
        let split = InkPath.split(pontos, tailLength: 24)

        let ultimoConsolidado = try #require(split.settled.last)
        let primeiroDaCauda = try #require(split.tail.first)
        #expect(ultimoConsolidado.location == primeiroDaCauda.location)
    }

    @Test("juntas, as partes cobrem o traço inteiro")
    func cobreTudo() {
        let pontos = line(100)
        let split = InkPath.split(pontos, tailLength: 24)
        // -1 pela sobreposição
        #expect(split.settled.count + split.tail.count - 1 == pontos.count)
    }

    @Test("lista vazia não quebra")
    func vazio() {
        let split = InkPath.split([], tailLength: 24)
        #expect(split.settled.isEmpty)
        #expect(split.tail.isEmpty)
    }

    /// O custo por quadro é o que determina a latência percebida.
    @Test("gerar a cauda custa o mesmo em traço longo e curto")
    func custoConstante() {
        let curto = InkPath.split(line(50), tailLength: 24)
        let longo = InkPath.split(line(5000), tailLength: 24)

        let stroke = { (pts: [InkPoint]) in
            InkStroke(points: pts, color: .black, baseWidth: 3)
        }

        let t0 = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { _ = InkPath.outline(of: stroke(curto.tail)) }
        let tempoCurto = ProcessInfo.processInfo.systemUptime - t0

        let t1 = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { _ = InkPath.outline(of: stroke(longo.tail)) }
        let tempoLongo = ProcessInfo.processInfo.systemUptime - t1

        // Sem a divisão, o traço longo seria ~100x mais caro.
        #expect(tempoLongo < tempoCurto * 3,
                "cauda de traço longo custou \(tempoLongo)s contra \(tempoCurto)s do curto")
    }
}

@Suite("Pontas do traço")
struct InkCapTests {

    /// Relatado em uso: o traço começava e terminava em corte reto, como se fosse
    /// cortado a faca.
    @Test("as pontas são arredondadas, não cortadas")
    func pontasArredondadas() throws {
        let stroke = InkStroke(points: [point(0, 0), point(100, 0)], color: .black, baseWidth: 10)
        let caminho = try #require(InkPath.outline(of: stroke))
        let caixa = caminho.boundingBox

        // Com tampa redonda, o contorno avança meia espessura além do último ponto.
        #expect(caixa.minX < -2, "sem tampa no início: \(caixa)")
        #expect(caixa.maxX > 102, "sem tampa no fim: \(caixa)")
    }

    @Test("a tampa acompanha a espessura daquele ponto")
    func tampaProporcional() throws {
        let fino = try #require(InkPath.outline(of: InkStroke(
            points: [point(0, 0, force: 0.1), point(100, 0, force: 0.1)],
            color: .black, baseWidth: 4)))
        let grosso = try #require(InkPath.outline(of: InkStroke(
            points: [point(0, 0, force: 1), point(100, 0, force: 1)],
            color: .black, baseWidth: 4)))

        #expect(grosso.boundingBox.minX < fino.boundingBox.minX)
    }
}

@Suite("Borracha")
struct InkEraserTests {

    private var desenho: InkDrawing {
        var d = InkDrawing()
        d.append(InkStroke(points: [point(10, 10), point(50, 10)], color: .black, baseWidth: 4))
        d.append(InkStroke(points: [point(10, 100), point(50, 100)], color: .black, baseWidth: 4))
        return d
    }

    @Test("encontra o traço sob o toque")
    func encontraTraco() {
        let alvo = InkPath.strokeIndex(at: CGPoint(x: 30, y: 10), in: desenho.strokes, tolerance: 8)
        #expect(alvo == 0)
    }

    @Test("distingue traços próximos")
    func distingue() {
        #expect(InkPath.strokeIndex(at: CGPoint(x: 30, y: 100), in: desenho.strokes, tolerance: 8) == 1)
    }

    @Test("toque longe não apaga nada")
    func longeNaoApaga() {
        #expect(InkPath.strokeIndex(at: CGPoint(x: 300, y: 300), in: desenho.strokes, tolerance: 8) == nil)
    }

    /// Com traços sobrepostos, apaga o de cima — é o que o usuário vê e espera atingir.
    @Test("sobrepostos, escolhe o mais recente")
    func escolheMaisRecente() {
        var d = desenho
        d.append(InkStroke(points: [point(20, 10), point(40, 10)], color: .black, baseWidth: 4))
        #expect(InkPath.strokeIndex(at: CGPoint(x: 30, y: 10), in: d.strokes, tolerance: 8) == 2)
    }

    @Test("a tolerância acompanha a espessura do traço")
    func toleranciaPelaEspessura() {
        let grosso = [InkStroke(points: [point(10, 10), point(50, 10)], color: .black, baseWidth: 20)]
        // um pouco fora do centro, mas dentro de um traço grosso
        #expect(InkPath.strokeIndex(at: CGPoint(x: 30, y: 18), in: grosso, tolerance: 2) == 0)
    }

    @Test("desenho vazio não tem o que apagar")
    func vazio() {
        #expect(InkPath.strokeIndex(at: .zero, in: [], tolerance: 8) == nil)
    }
}

@Suite("Remoção de traço")
struct InkRemovalTests {

    @Test("remover mantém o histórico consistente")
    func removeComHistorico() {
        var d = InkDrawing()
        d.append(InkStroke(points: [point(0, 0), point(10, 10)], color: .black, baseWidth: 3))
        d.append(InkStroke(points: [point(50, 50), point(60, 60)], color: .black, baseWidth: 3))

        d.remove(at: 0)
        #expect(d.strokes.count == 1)
        #expect(d.canUndo, "remover deve poder ser desfeito")

        d.undo()
        #expect(d.strokes.count == 2, "desfazer deve restaurar o traço apagado")
    }

    @Test("índice inválido não altera nada")
    func indiceInvalido() {
        var d = InkDrawing()
        d.append(InkStroke(points: [point(0, 0), point(10, 10)], color: .black, baseWidth: 3))
        d.remove(at: 99)
        #expect(d.strokes.count == 1)
    }
}
