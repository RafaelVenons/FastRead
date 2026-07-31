import CoreGraphics
import Foundation
import Testing
@testable import FastReadCore

private func point(_ x: Double, _ y: Double, force: Double = 0.5,
                   altitude: Double = .pi / 2) -> InkPoint {
    InkPoint(location: CGPoint(x: x, y: y), force: force, altitude: altitude)
}

private func stroke(_ points: [InkPoint], baseWidth: Double = 4) -> InkStroke {
    InkStroke(points: points, color: .black, baseWidth: baseWidth)
}

@Suite("Largura por ponto")
struct InkWidthTests {

    @Test("mais pressão, traço mais largo")
    func pressaoAumentaLargura() {
        let leve = InkPath.width(for: point(0, 0, force: 0.2), baseWidth: 4)
        let forte = InkPath.width(for: point(0, 0, force: 1.0), baseWidth: 4)
        #expect(forte > leve)
    }

    @Test("a espessura base escala o resultado")
    func baseEscala() {
        let fina = InkPath.width(for: point(0, 0, force: 0.5), baseWidth: 2)
        let grossa = InkPath.width(for: point(0, 0, force: 0.5), baseWidth: 8)
        #expect(grossa > fina)
    }

    /// Caneta deitada espalha mais tinta, como um lápis inclinado.
    @Test("caneta deitada alarga o traço")
    func inclinacaoAlarga() {
        let empe = InkPath.width(for: point(0, 0, altitude: .pi / 2), baseWidth: 4)
        let deitada = InkPath.width(for: point(0, 0, altitude: .pi / 8), baseWidth: 4)
        #expect(deitada > empe)
    }

    @Test("nenhuma combinação produz traço invisível ou absurdo")
    func faixaUtilizavel() {
        for force in [0.0, 0.01, 0.5, 1.0] {
            for altitude in [0.0, Double.pi / 4, Double.pi / 2] {
                let largura = InkPath.width(for: point(0, 0, force: force, altitude: altitude),
                                            baseWidth: 4)
                #expect(largura > 0)
                #expect(largura < 40, "largura \(largura) para força \(force), altitude \(altitude)")
            }
        }
    }
}

@Suite("Suavização")
struct InkSmoothingTests {

    @Test("acrescenta pontos entre as amostras")
    func densifica() {
        let cru = [point(0, 0), point(10, 10), point(20, 0), point(30, 10)]
        let suave = InkPath.smoothed(cru)
        #expect(suave.count > cru.count)
    }

    @Test("preserva as extremidades")
    func preservaPontas() throws {
        let cru = [point(0, 0), point(10, 10), point(20, 0)]
        let suave = InkPath.smoothed(cru)

        let primeiro = try #require(suave.first)
        let ultimo = try #require(suave.last)
        #expect(primeiro.location == cru[0].location)
        #expect(ultimo.location == cru[cru.count - 1].location)
    }

    @Test("poucos pontos passam sem alteração")
    func poucosPontos() {
        #expect(InkPath.smoothed([]).isEmpty)
        #expect(InkPath.smoothed([point(1, 1)]).count == 1)
        #expect(InkPath.smoothed([point(1, 1), point(2, 2)]).count == 2)
    }

    @Test("a curva não escapa da vizinhança dos pontos originais")
    func naoExtrapola() {
        let cru = [point(0, 0), point(10, 0), point(20, 0), point(30, 0)]
        let suave = InkPath.smoothed(cru)
        // reta horizontal: a suavização não pode inventar desvio vertical
        #expect(suave.allSatisfy { abs($0.location.y) < 0.5 })
    }

    @Test("a pressão é interpolada junto com a posição")
    func interpolaPressao() {
        let cru = [point(0, 0, force: 0.1), point(10, 0, force: 0.9),
                   point(20, 0, force: 0.9), point(30, 0, force: 0.1)]
        let suave = InkPath.smoothed(cru)
        #expect(suave.allSatisfy { $0.force > 0 && $0.force <= 1 })
        #expect(suave.contains { $0.force > 0.5 })
    }
}

@Suite("Contorno do traço")
struct InkOutlineTests {

    @Test("um traço vira um caminho fechado")
    func caminhoFechado() throws {
        let caminho = try #require(InkPath.outline(of: stroke([point(0, 0), point(50, 0)])))
        #expect(!caminho.isEmpty)
        // um contorno fechado tem área; um traço de linha não teria
        #expect(caminho.boundingBox.height > 0)
        #expect(caminho.boundingBox.width > 0)
    }

    @Test("o contorno envolve todos os pontos do traço")
    func envolvePontos() throws {
        let pontos = [point(10, 10), point(40, 30), point(70, 10)]
        let caminho = try #require(InkPath.outline(of: stroke(pontos)))

        for ponto in pontos {
            #expect(caminho.boundingBox.contains(ponto.location),
                    "\(ponto.location) fora de \(caminho.boundingBox)")
        }
    }

    /// É o ponto da arquitetura: largura variável exige contorno preenchido, não uma
    /// linha de espessura fixa.
    @Test("mais pressão engrossa o contorno naquele trecho")
    func larguraVariaComPressao() throws {
        let leve = try #require(InkPath.outline(of: stroke([
            point(0, 0, force: 0.1), point(100, 0, force: 0.1),
        ])))
        let forte = try #require(InkPath.outline(of: stroke([
            point(0, 0, force: 1.0), point(100, 0, force: 1.0),
        ])))
        #expect(forte.boundingBox.height > leve.boundingBox.height)
    }

    @Test("um ponto só vira um disco")
    func pontoUnicoViraDisco() throws {
        let caminho = try #require(InkPath.outline(of: stroke([point(20, 20)], baseWidth: 6)))
        let caixa = caminho.boundingBox

        #expect(caixa.contains(CGPoint(x: 20, y: 20)))
        #expect(abs(caixa.width - caixa.height) < 1, "deveria ser aproximadamente redondo")
        #expect(caixa.width > 1)
    }

    @Test("traço vazio não gera caminho")
    func vazio() {
        #expect(InkPath.outline(of: stroke([])) == nil)
    }

    /// Amostras repetidas acontecem quando a caneta para sem levantar: a perpendicular
    /// entre dois pontos idênticos é indefinida e produziria NaN.
    @Test("pontos coincidentes não geram coordenada inválida")
    func pontosCoincidentes() throws {
        let caminho = try #require(InkPath.outline(of: stroke([
            point(10, 10), point(10, 10), point(10, 10), point(30, 30),
        ])))
        #expect(caminho.boundingBox.origin.x.isFinite)
        #expect(caminho.boundingBox.width.isFinite)
        #expect(!caminho.boundingBox.isNull)
    }

    @Test("o contorno acompanha a direção do traço")
    func acompanhaDirecao() throws {
        let horizontal = try #require(InkPath.outline(of: stroke([point(0, 0), point(100, 0)])))
        let vertical = try #require(InkPath.outline(of: stroke([point(0, 0), point(0, 100)])))

        #expect(horizontal.boundingBox.width > horizontal.boundingBox.height)
        #expect(vertical.boundingBox.height > vertical.boundingBox.width)
    }

    @Test("uma curva fechada não colapsa o contorno")
    func curvaFechada() throws {
        // um laço: volta perto de onde começou
        let pontos = (0...20).map { i -> InkPoint in
            let t = Double(i) / 20 * 2 * .pi
            return point(50 + cos(t) * 30, 50 + sin(t) * 30)
        }
        let caminho = try #require(InkPath.outline(of: stroke(pontos)))
        #expect(caminho.boundingBox.width > 50)
        #expect(caminho.boundingBox.height > 50)
    }
}
