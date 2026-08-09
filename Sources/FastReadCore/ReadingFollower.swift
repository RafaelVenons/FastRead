import CoreGraphics
import Foundation

/// Decide se a tela deve acompanhar a palavra que está sendo lida.
///
/// A voz segue o parágrafo mesmo depois que ele sai da tela, e ler acompanhando o destaque
/// deixa de funcionar. Trazer a palavra de volta é o que mantém o ritmo.
///
/// A decisão é geométrica e não depende do PDFKit, então dá para testá-la sem simulador.
/// Ambos os retângulos precisam estar no mesmo sistema de coordenadas.
public enum ReadingFollower {

    /// Quanto da tela o alvo ocupa quando é preciso rolar, como fração dela.
    ///
    /// Revelar só a palavra a deixaria de novo colada na borda — o PDFKit faz o
    /// deslocamento mínimo — e a palavra seguinte já pediria outra rolagem. Foi o "samba"
    /// relatado em uso. Pedindo uma área generosa centrada na palavra, o salto a leva para
    /// perto do meio e sobra tela para muitas palavras antes da próxima rolagem.
    public static let defaultSettle: CGFloat = 0.5

    /// Retângulo que precisa ser revelado, ou `nil` se a palavra está visível.
    ///
    /// O critério é esse mesmo, sem folga: enquanto der para ler a palavra onde ela está,
    /// mexer na tela só atrapalha — inclusive na troca de linha.
    public static func rectToReveal(word: CGRect,
                                    visible: CGRect,
                                    settle: CGFloat = defaultSettle) -> CGRect? {
        guard visible.width > 0, visible.height > 0,
              word.width > 0, word.height > 0 else { return nil }
        guard !isVisible(word: word, in: visible) else { return nil }

        // Centrado na palavra e do tamanho de boa parte da tela, sem passar dela: um alvo
        // maior que a área visível não teria como ser revelado por inteiro.
        let size = CGSize(width: min(visible.width, max(word.width, visible.width * settle)),
                          height: min(visible.height, max(word.height, visible.height * settle)))
        return CGRect(x: word.midX - size.width / 2,
                      y: word.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    /// A palavra dá para ser lida onde está?
    ///
    /// Com zoom alto uma palavra pode ser maior que a própria tela. Exigir que caiba
    /// inteira faria a tela rolar sem parar, então nesse caso o que vale é o centro.
    private static func isVisible(word: CGRect, in visible: CGRect) -> Bool {
        let cabe = word.width <= visible.width && word.height <= visible.height
        return cabe ? visible.contains(word)
                    : visible.contains(CGPoint(x: word.midX, y: word.midY))
    }
}
