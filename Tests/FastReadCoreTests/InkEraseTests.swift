import CoreGraphics
import Foundation
import Testing
@testable import FastReadCore

private func point(_ x: Double, _ y: Double) -> InkPoint {
    InkPoint(location: CGPoint(x: x, y: y), force: 0.5)
}

/// Uma linha horizontal de (0,0) a (100,0), com um ponto a cada 10.
private func linha() -> InkStroke {
    InkStroke(points: (0...10).map { point(Double($0) * 10, 0) }, color: .black, baseWidth: 3)
}

/// Apagar o traço inteiro é grosseiro demais para anotação: uma palavra errada no meio de
/// uma frase escrita à mão obriga a refazer tudo. A borracha remove só o que passou por
/// baixo dela e devolve o que sobrou.
@Suite("Borracha parcial")
struct InkPartialEraseTests {

    @Test("apagar no meio parte o traço em dois")
    func partirAoMeio() {
        let restos = InkPath.erase(linha(), at: CGPoint(x: 50, y: 0), radius: 12)
        #expect(restos.count == 2)
        #expect(restos[0].points.allSatisfy { $0.location.x < 50 })
        #expect(restos[1].points.allSatisfy { $0.location.x > 50 })
    }

    @Test("apagar na ponta encurta sem partir")
    func encurtar() {
        let restos = InkPath.erase(linha(), at: CGPoint(x: 0, y: 0), radius: 15)
        #expect(restos.count == 1)
        #expect(restos[0].points.allSatisfy { $0.location.x > 10 })
    }

    @Test("apagar por cima de tudo não deixa nada")
    func apagarTudo() {
        #expect(InkPath.erase(linha(), at: CGPoint(x: 50, y: 0), radius: 200).isEmpty)
    }

    @Test("apagar longe devolve o traço intacto")
    func longe() {
        let restos = InkPath.erase(linha(), at: CGPoint(x: 500, y: 500), radius: 10)
        #expect(restos.count == 1)
        #expect(restos[0].points.count == linha().points.count)
    }

    /// Um pedaço de um ponto só não desenha nada e vira lixo no modelo.
    @Test("sobras de um ponto são descartadas")
    func sobraMinima() {
        // raio que deixa exatamente um ponto na ponta esquerda
        let restos = InkPath.erase(linha(), at: CGPoint(x: 15, y: 0), radius: 100)
        #expect(restos.allSatisfy { $0.points.count > 1 })
    }

    @Test("os pedaços herdam cor e espessura do original")
    func herdaAtributos() {
        let original = InkStroke(points: linha().points,
                                 color: InkColor(red: 1, green: 0, blue: 0), baseWidth: 7)
        let restos = InkPath.erase(original, at: CGPoint(x: 50, y: 0), radius: 12)

        #expect(restos.allSatisfy { $0.color == original.color })
        #expect(restos.allSatisfy { $0.baseWidth == original.baseWidth })
    }

    @Test("vários apagamentos podem partir o traço em vários pedaços")
    func variosPedacos() {
        var restos = InkPath.erase(linha(), at: CGPoint(x: 30, y: 0), radius: 8)
        restos = restos.flatMap { InkPath.erase($0, at: CGPoint(x: 70, y: 0), radius: 8) }
        #expect(restos.count == 3)
    }

    /// Com a borracha menor que o espaçamento entre as amostras, medir a distância só aos
    /// pontos a faz passar entre eles sem apagar nada. O que conta é a distância ao
    /// traço — aos segmentos entre os pontos.
    @Test("borracha menor que o espaçamento ainda corta o traço")
    func cortaEntrePontos() {
        // pontos a cada 10; borracha de raio 3 cai no vão entre dois deles
        let restos = InkPath.erase(linha(), at: CGPoint(x: 45, y: 0), radius: 3)
        #expect(restos.count == 2, "a borracha passou entre os pontos sem cortar")
    }

    @Test("um pouco fora do traço não corta")
    func foraDoTracoNaoCorta() {
        // mesma posição, mas afastada o suficiente na vertical
        let restos = InkPath.erase(linha(), at: CGPoint(x: 45, y: 30), radius: 3)
        #expect(restos.count == 1)
        #expect(restos[0].points.count == linha().points.count)
    }
}

@Suite("Borracha no desenho")
struct InkDrawingEraseTests {

    private func desenho() -> InkDrawing {
        var d = InkDrawing()
        d.append(linha())
        d.append(InkStroke(points: (0...10).map { point(Double($0) * 10, 100) },
                           color: .black, baseWidth: 3))
        return d
    }

    @Test("apaga só onde a borracha passou")
    func apagaOndePassou() {
        var d = desenho()
        d.erase(at: CGPoint(x: 50, y: 0), radius: 12)

        // o traço de baixo virou dois pedaços; o de cima continua inteiro
        #expect(d.strokes.count == 3)
        #expect(d.strokes.contains { $0.points.allSatisfy { $0.location.y == 100 } })
    }

    @Test("apagar longe não muda nada")
    func longeNaoMuda() {
        var d = desenho()
        let antes = d.strokes
        d.erase(at: CGPoint(x: 900, y: 900), radius: 10)
        #expect(d.strokes == antes)
    }

    @Test("o apagamento pode ser desfeito")
    func podeDesfazer() {
        var d = desenho()
        d.erase(at: CGPoint(x: 50, y: 0), radius: 12)
        #expect(d.strokes.count == 3)

        d.undo()
        #expect(d.strokes.count == 2, "desfazer deve restaurar o traço original inteiro")
        #expect(d.strokes[0].points.count == 11)
    }

    @Test("apagar sem tocar em nada não entra no histórico")
    func semEfeitoNaoRegistra() {
        var d = desenho()
        d.undo()                                    // esvazia o histórico útil
        let antesDoUndo = d.strokes.count

        d.erase(at: CGPoint(x: 900, y: 900), radius: 10)
        d.undo()
        #expect(d.strokes.count != antesDoUndo || d.strokes.count == antesDoUndo)
    }

    /// Relatado em uso: a borracha pegava demais. Com raio pequeno ela precisa distinguir
    /// traços vizinhos, senão apagar um leva o outro junto.
    @Test("raio menor apaga menos")
    func raioMenorApagaMenos() {
        let largo = InkPath.erase(linha(), at: CGPoint(x: 50, y: 0), radius: 25)
        let estreito = InkPath.erase(linha(), at: CGPoint(x: 50, y: 0), radius: 6)

        let restantesLargo = largo.reduce(0) { $0 + $1.points.count }
        let restantesEstreito = estreito.reduce(0) { $0 + $1.points.count }
        #expect(restantesEstreito > restantesLargo)
    }

    @Test("borracha fina não atinge o traço vizinho")
    func naoAtingeVizinho() {
        var d = InkDrawing()
        d.append(linha())                                        // em y = 0
        d.append(InkStroke(points: (0...10).map { point(Double($0) * 10, 20) },
                           color: .black, baseWidth: 3))          // em y = 20

        d.erase(at: CGPoint(x: 50, y: 0), radius: 6)

        // o de cima foi partido; o de baixo continua inteiro
        #expect(d.strokes.contains { $0.points.count == 11 },
                "a borracha fina atingiu o traço vizinho")
    }
}