import CoreGraphics
import Foundation

/// Converte o traço da tela de desenho para o sistema de coordenadas do PDF.
///
/// Existe para que a anotação vire conteúdo vetorial da página, em vez de um bitmap
/// sobreposto: `PKCanvasView` rasteriza na resolução da página e fica borrado ao ampliar
/// — limitação conhecida e sem correção publicada. Como anotação do PDF, o traço é
/// redesenhado nitidamente em qualquer zoom.
public enum InkGeometry {

    /// Espessura mínima: uma amostra de pressão muito leve produziria traço invisível.
    public static let minimumLineWidth: CGFloat = 0.5

    /// Do espaço da tela (origem no topo, y para baixo) para o do PDF (origem embaixo).
    ///
    /// A conversão é a própria inversa, então aplicar duas vezes devolve o original.
    public static func pdfPoint(_ point: CGPoint, pageHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: pageHeight - point.y)
    }

    /// Retângulo da anotação, com folga para a espessura do traço.
    ///
    /// A caixa justa cortaria as bordas: ela acompanha o centro da linha, e metade da
    /// espessura fica de fora.
    public static func bounds(of points: [CGPoint], lineWidth: CGFloat) -> CGRect {
        guard let first = points.first else { return .null }

        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }

        let padding = max(lineWidth, minimumLineWidth)
        return CGRect(x: minX - padding, y: minY - padding,
                      width: (maxX - minX) + padding * 2,
                      height: (maxY - minY) + padding * 2)
    }

    /// Quanto do tamanho do pincel vira espessura da anotação.
    ///
    /// O PencilKit desenha o traço com bordas suaves; a anotação do PDF desenha uma
    /// linha cheia. Usar o tamanho do estampo direto produz traço bem mais grosso do que
    /// o que estava na tela, e escrita miúda fica ilegível.
    public enum Calibration: String, Sendable, CaseIterable {
        case fine
        case medium
        case bold

        public var factor: CGFloat {
            switch self {
            case .fine: 0.35
            case .medium: 0.55
            case .bold: 0.8
            }
        }
    }

    /// Espessura representativa de um traço, a partir das amostras de pressão.
    public static func lineWidth(fromSizes sizes: [CGFloat],
                                 calibration: Calibration = .medium) -> CGFloat {
        guard !sizes.isEmpty else { return minimumLineWidth }
        let average = sizes.reduce(0, +) / CGFloat(sizes.count)
        return max(average * calibration.factor, minimumLineWidth)
    }
}
