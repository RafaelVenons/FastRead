import CoreGraphics
import Foundation
import Testing
@testable import FastReadCore

/// A tela acompanha a palavra que está sendo lida. A decisão é geométrica e não depende
/// do PDFKit, então mora aqui: o app só executa a rolagem que ela pedir.
@Suite("ReadingFollower")
struct ReadingFollowerTests {

    /// Uma página inteira à vista, do tamanho de uma tela.
    private let visivel = CGRect(x: 0, y: 0, width: 800, height: 1000)

    private func palavra(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 60, height: 16)
    }

    // MARK: - Quando não deve mexer

    @Test("palavra no meio da tela não rola")
    func meioNaoRola() {
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 500), visible: visivel) == nil)
    }

    /// Sem folga, cada palavra empurraria a tela um pouco e a leitura ficaria trepidando.
    @Test("palavra visível perto da borda, mas dentro da folga, não rola")
    func dentroDaFolgaNaoRola() {
        // margem padrão de 15% → zona confortável começa em y=150
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 200), visible: visivel) == nil)
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 800), visible: visivel) == nil)
    }

    // MARK: - Quando deve mexer

    @Test("palavra abaixo da tela pede rolagem")
    func abaixoRola() throws {
        let alvo = try #require(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 1400),
                                                            visible: visivel))
        // O retângulo pedido contém a palavra com folga dos dois lados, para ela não
        // encostar na borda depois que a rolagem mínima acontecer.
        #expect(alvo.contains(palavra(x: 400, y: 1400)))
        #expect(alvo.height > 16)
    }

    @Test("palavra acima da tela pede rolagem")
    func acimaRola() throws {
        let alvo = try #require(ReadingFollower.rectToReveal(word: palavra(x: 400, y: -200),
                                                            visible: visivel))
        #expect(alvo.contains(palavra(x: 400, y: -200)))
    }

    /// Artigo de duas colunas com zoom: a coluna seguinte fica fora da tela na horizontal.
    @Test("palavra fora na horizontal pede rolagem")
    func lateralRola() throws {
        let alvo = try #require(ReadingFollower.rectToReveal(word: palavra(x: 1200, y: 500),
                                                            visible: visivel))
        #expect(alvo.contains(palavra(x: 1200, y: 500)))
    }

    @Test("palavra logo dentro da borda ainda rola, antes de sumir")
    func bordaRola() {
        // y=60 está dentro da tela mas fora da zona confortável (que começa em 150)
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 60), visible: visivel) != nil)
    }

    // MARK: - Casos de borda

    /// Com zoom alto uma única palavra pode ser maior que a zona confortável. Exigir que
    /// caiba inteira faria a tela rolar sem parar; o que vale então é o centro dela.
    @Test("palavra maior que a zona confortável só rola quando o centro sai")
    func palavraEnorme() {
        let enorme = CGRect(x: 0, y: 100, width: 900, height: 900)
        #expect(ReadingFollower.rectToReveal(word: enorme, visible: visivel) == nil)

        let deslocada = CGRect(x: 0, y: 900, width: 900, height: 900)
        #expect(ReadingFollower.rectToReveal(word: deslocada, visible: visivel) != nil)
    }

    @Test("tela sem tamanho não pede rolagem")
    func telaVazia() {
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 10, y: 10), visible: .zero) == nil)
    }

    @Test("palavra vazia não pede rolagem")
    func palavraVazia() {
        #expect(ReadingFollower.rectToReveal(word: .zero, visible: visivel) == nil)
    }
}
