import CoreGraphics
import Foundation

/// Decide se a tela deve acompanhar a palavra que está sendo lida.
///
/// A voz segue o parágrafo mesmo depois que ele sai da tela, e ler acompanhando o destaque
/// deixa de funcionar. Trazer a palavra de volta é o que mantém o ritmo.
///
/// A decisão é geométrica e não depende do PDFKit, então dá para testá-la sem simulador.
/// Ambos os retângulos precisam estar no mesmo sistema de coordenadas; qual deles é
/// indiferente, porque as folgas são simétricas.
public enum ReadingFollower {

    /// Folga em volta da tela, como fração dela, em que ainda não se rola.
    ///
    /// Sem essa histerese cada palavra empurraria a tela um pouco e a leitura ficaria
    /// trepidando. Com ela, a rolagem acontece quando a palavra se aproxima da borda —
    /// antes de sumir, não depois.
    public static let defaultMargin: CGFloat = 0.15

    /// Retângulo que precisa ser revelado, ou `nil` se a palavra já está confortável.
    ///
    /// O retângulo devolvido é a palavra com folga dos dois lados: revelando-o por
    /// rolagem mínima, a palavra termina longe da borda em vez de colada nela.
    public static func rectToReveal(word: CGRect,
                                    visible: CGRect,
                                    margin: CGFloat = defaultMargin) -> CGRect? {
        guard visible.width > 0, visible.height > 0,
              word.width > 0, word.height > 0 else { return nil }

        let dx = visible.width * margin
        let dy = visible.height * margin
        let comfortable = visible.insetBy(dx: dx, dy: dy)
        guard comfortable.width > 0, comfortable.height > 0 else { return nil }

        if isSettled(word: word, in: comfortable) { return nil }
        return word.insetBy(dx: -dx, dy: -dy)
    }

    /// A palavra está acomodada dentro da zona confortável?
    ///
    /// Com zoom alto uma única palavra pode ser maior que a zona. Exigir que caiba
    /// inteira faria a tela rolar sem parar, então nesse caso o que vale é o centro.
    private static func isSettled(word: CGRect, in comfortable: CGRect) -> Bool {
        let cabe = word.width <= comfortable.width && word.height <= comfortable.height
        return cabe ? comfortable.contains(word) : comfortable.contains(center(of: word))
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
