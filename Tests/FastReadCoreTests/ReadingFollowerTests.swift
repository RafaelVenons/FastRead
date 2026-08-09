import CoreGraphics
import Foundation
import Testing
@testable import FastReadCore

/// A tela acompanha a palavra que está sendo lida. A decisão é geométrica e não depende
/// do PDFKit, então mora aqui: o app só executa a rolagem que ela pedir.
///
/// Relatado em uso na primeira versão: o PDF "sambava" — a palavra ainda estava visível e
/// a tela já se mexia, e como a rolagem é mínima ela reaparecia colada na borda e pedia
/// outra. Duas regras saíram daí: só rola quando a palavra **não está visível**, e quando
/// rola, sobra caminho para as próximas.
@Suite("ReadingFollower")
struct ReadingFollowerTests {

    private let visivel = CGRect(x: 0, y: 0, width: 800, height: 1000)

    private func palavra(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 60, height: 16)
    }

    // MARK: - Não mexer enquanto dá para ler

    @Test("palavra no meio da tela não rola")
    func meioNaoRola() {
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 500), visible: visivel) == nil)
    }

    /// O pedido explícito: enquanto a palavra estiver na tela, a tela fica parada.
    @Test("palavra visível colada na borda não rola")
    func bordaVisivelNaoRola() {
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 2), visible: visivel) == nil)
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 980), visible: visivel) == nil)
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 735, y: 500), visible: visivel) == nil)
    }

    /// Trocar de linha dentro da área visível não é motivo para mexer na tela.
    @Test("linha seguinte ainda visível não rola")
    func linhaSeguinteNaoRola() {
        for y in stride(from: CGFloat(100), to: 900, by: 40) {
            #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: y), visible: visivel) == nil,
                    "rolou com a palavra visível em y=\(y)")
        }
    }

    // MARK: - Mexer quando a palavra sumiu

    @Test("palavra abaixo da tela pede rolagem")
    func abaixoRola() throws {
        let alvo = try #require(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 1400),
                                                            visible: visivel))
        #expect(alvo.contains(palavra(x: 400, y: 1400)))
    }

    @Test("palavra cortada pela borda pede rolagem")
    func cortadaRola() {
        // metade de fora embaixo
        #expect(ReadingFollower.rectToReveal(word: palavra(x: 400, y: 992), visible: visivel) != nil)
    }

    /// Artigo de duas colunas com zoom: a coluna seguinte fica fora na horizontal.
    @Test("palavra fora na horizontal pede rolagem")
    func lateralRola() throws {
        let alvo = try #require(ReadingFollower.rectToReveal(word: palavra(x: 1200, y: 500),
                                                            visible: visivel))
        #expect(alvo.contains(palavra(x: 1200, y: 500)))
    }

    // MARK: - Uma rolagem tem de durar

    /// Revelar só a palavra a deixaria de novo na borda, e a próxima já pediria outra
    /// rolagem — o "samba" relatado. O retângulo pedido é grande e centrado nela, então
    /// depois do salto sobra tela para muitas palavras.
    @Test("o alvo é centrado na palavra e grande o bastante para durar")
    func alvoCentradoEFolgado() throws {
        let fora = palavra(x: 400, y: 1400)
        let alvo = try #require(ReadingFollower.rectToReveal(word: fora, visible: visivel))

        #expect(abs(alvo.midY - fora.midY) < 0.001, "alvo não está centrado na palavra")
        #expect(abs(alvo.midX - fora.midX) < 0.001)
        #expect(alvo.height >= visivel.height * 0.4, "alvo curto demais: \(alvo.height)")
        #expect(alvo.height <= visivel.height, "alvo maior que a tela não cabe")
    }

    // MARK: - Casos de borda

    /// Com zoom alto uma palavra pode ser maior que a tela. Exigir que caiba inteira faria
    /// a tela rolar sem parar; o que vale então é o centro dela.
    @Test("palavra maior que a tela só rola quando o centro sai")
    func palavraEnorme() {
        let enorme = CGRect(x: -100, y: -100, width: 1000, height: 1200)
        #expect(ReadingFollower.rectToReveal(word: enorme, visible: visivel) == nil)

        let deslocada = CGRect(x: -100, y: 900, width: 1000, height: 1200)
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

/// Ao fim do trecho o `AVAudioPlayer` zera `currentTime`. Recalcular o realce a partir
/// dele salta para a primeira palavra — e a tela rola de volta junto.
@Suite("Realce ao fim do trecho")
struct HighlightAtEndTests {

    private let alinhamento = SegmentAlignment(
        words: [
            WordTiming(word: "um", location: 0, length: 2, start: 0),
            WordTiming(word: "dois", location: 3, length: 4, start: 1),
            WordTiming(word: "tres", location: 8, length: 4, start: 2),
        ],
        duration: 3)

    @Test("tocando, a palavra vem do tempo")
    func tocando() {
        let r = alinhamento.highlightRange(at: 1.5, isPlaying: true, previous: nil)
        #expect(r == NSRange(location: 3, length: 4))
    }

    @Test("parado, a última palavra permanece")
    func paradoMantem() {
        let ultima = NSRange(location: 8, length: 4)
        // `currentTime` zerado é o que o AVAudioPlayer entrega depois de terminar
        let r = alinhamento.highlightRange(at: 0, isPlaying: false, previous: ultima)
        #expect(r == ultima, "voltou para \(String(describing: r)) em vez de manter a última")
    }

    @Test("parado sem palavra anterior não inventa uma")
    func paradoSemAnterior() {
        #expect(alinhamento.highlightRange(at: 0, isPlaying: false, previous: nil) == nil)
    }
}
