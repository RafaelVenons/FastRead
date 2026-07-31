import CoreGraphics
import Foundation

/// Converte um traço em geometria desenhável.
///
/// O resultado é o **contorno fechado** do traço, não uma linha: espessura que varia
/// ponto a ponto não cabe num caminho de largura fixa. Preenchido, o contorno dá largura
/// variável e continua vetorial — nítido em qualquer zoom por natureza, sem rasterizar
/// e reescalar.
public enum InkPath {

    // MARK: - Largura

    /// Quanto a pressão pode afastar a largura da base, para cada lado.
    private static let pressureRange: Double = 0.6
    /// Ganho extra com a caneta deitada, como um lápis inclinado espalha mais grafite.
    private static let tiltGain: Double = 0.5

    public static func width(for point: InkPoint, baseWidth: Double) -> Double {
        // Pressão neutra mantém a largura base; os extremos afastam para cada lado.
        let deviation: Double = point.force - InkPoint.neutralForce
        let pressure: Double = 1 + deviation * 2 * pressureRange

        // altitude π/2 = em pé (sem ganho), 0 = deitada (ganho máximo)
        let tilt = 1 - min(max(point.altitude, 0), .pi / 2) / (.pi / 2)
        let spread = 1 + tilt * tiltGain

        return max(baseWidth * pressure * spread, 0.2)
    }

    // MARK: - Suavização

    /// Quantos pontos gerar entre cada par de amostras.
    private static let subdivisions = 6

    /// Interpola os pontos capturados com Catmull-Rom.
    ///
    /// A curva passa pelas amostras — ao contrário de Bézier com controles arbitrários —
    /// então o traço não se afasta de onde a caneta esteve.
    public static func smoothed(_ points: [InkPoint]) -> [InkPoint] {
        guard points.count > 2 else { return points }

        var result: [InkPoint] = [points[0]]

        for index in 0..<(points.count - 1) {
            // Nas pontas, duplica o extremo para a curva continuar definida.
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]

            for step in 1...subdivisions {
                let t = Double(step) / Double(subdivisions)
                result.append(interpolate(p0, p1, p2, p3, t: t))
            }
        }
        return result
    }

    private static func interpolate(_ p0: InkPoint, _ p1: InkPoint,
                                    _ p2: InkPoint, _ p3: InkPoint, t: Double) -> InkPoint {
        func catmullRom(_ v0: Double, _ v1: Double, _ v2: Double, _ v3: Double) -> Double {
            let t2 = t * t
            let t3 = t2 * t
            return 0.5 * ((2 * v1)
                + (-v0 + v2) * t
                + (2 * v0 - 5 * v1 + 4 * v2 - v3) * t2
                + (-v0 + 3 * v1 - 3 * v2 + v3) * t3)
        }

        let location = CGPoint(x: catmullRom(p0.location.x, p1.location.x, p2.location.x, p3.location.x),
                               y: catmullRom(p0.location.y, p1.location.y, p2.location.y, p3.location.y))
        // Pressão e ângulos acompanham, senão a largura saltaria entre as amostras.
        return InkPoint(location: location,
                        force: min(max(catmullRom(p0.force, p1.force, p2.force, p3.force), 0.01), 1),
                        altitude: catmullRom(p0.altitude, p1.altitude, p2.altitude, p3.altitude),
                        azimuth: p2.azimuth,
                        roll: p2.roll)
    }

    // MARK: - Contorno

    /// Contorno fechado do traço, pronto para preencher.
    public static func outline(of stroke: InkStroke) -> CGPath? {
        guard !stroke.isEmpty else { return nil }

        let points = smoothed(stroke.points)
        guard points.count > 1 else {
            return dot(at: points[0], stroke: stroke)
        }

        var left: [CGPoint] = []
        var right: [CGPoint] = []

        for (index, point) in points.enumerated() {
            guard let direction = direction(at: index, in: points) else { continue }

            let half = width(for: point, baseWidth: stroke.baseWidth) / 2
            // Normal é a direção girada 90°.
            let normal = CGPoint(x: -direction.y * half, y: direction.x * half)

            left.append(CGPoint(x: point.location.x + normal.x, y: point.location.y + normal.y))
            right.append(CGPoint(x: point.location.x - normal.x, y: point.location.y - normal.y))
        }

        guard left.count > 1 else { return dot(at: points[0], stroke: stroke) }

        let path = CGMutablePath()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        // Volta pelo outro lado, fechando o contorno.
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()

        return path
    }

    /// Direção normalizada do traço naquele ponto.
    ///
    /// Usa os vizinhos para a direção não saltar entre segmentos. Amostras repetidas —
    /// a caneta parada sem levantar — deixam a direção indefinida e são puladas, senão o
    /// resultado seria NaN.
    private static func direction(at index: Int, in points: [InkPoint]) -> CGPoint? {
        let previous = points[max(index - 1, 0)].location
        let next = points[min(index + 1, points.count - 1)].location

        var dx = next.x - previous.x
        var dy = next.y - previous.y
        var length = (dx * dx + dy * dy).squareRoot()

        if length < 1e-6 {
            // Vizinhos coincidentes: tenta o segmento anterior antes de desistir.
            guard index > 0 else { return nil }
            let earlier = points[max(index - 2, 0)].location
            dx = points[index].location.x - earlier.x
            dy = points[index].location.y - earlier.y
            length = (dx * dx + dy * dy).squareRoot()
            guard length >= 1e-6 else { return nil }
        }
        return CGPoint(x: dx / length, y: dy / length)
    }

    /// Um toque sem arrasto ainda deixa marca.
    private static func dot(at point: InkPoint, stroke: InkStroke) -> CGPath {
        let radius = width(for: point, baseWidth: stroke.baseWidth) / 2
        return CGPath(ellipseIn: CGRect(x: point.location.x - radius,
                                        y: point.location.y - radius,
                                        width: radius * 2, height: radius * 2),
                      transform: nil)
    }
}
