import CoreGraphics

/// Em que densidade a tela de desenho deve rasterizar o traço.
///
/// A tela sobreposta a uma página de PDF tem o tamanho dela em pontos (612×792), e é o
/// PDFKit que a escala para caber. Deixá-la na densidade padrão faz o traço nascer na
/// resolução da página e ser ampliado depois — grosso e borrado, sem permitir escrita
/// miúda. Acompanhar a escala de exibição resolve.
public enum DrawingResolution {

    /// Teto de densidade. Cada página aloca por pixel, e um artigo tem dezenas delas;
    /// sem limite, ampliar bastante consumiria memória sem ganho visível.
    public static let maximumScale: CGFloat = 8

    public static func contentScale(pdfScale: CGFloat, screenScale: CGFloat) -> CGFloat {
        let screen = max(screenScale, 1)
        // Abaixo de 1 a página está reduzida na tela; manter a densidade dela evita que o
        // traço nasça pior do que ficará ao ampliar.
        let zoom = max(pdfScale, 1)
        return min(screen * zoom, maximumScale)
    }
}
