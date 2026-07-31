import FastReadCore
import PDFKit
import PencilKit
import UIKit

/// Transforma o traço do PencilKit em anotação de tinta do próprio PDF.
///
/// A tela do PencilKit é ótima para desenhar — pressão, inclinação, suavização — mas
/// rasteriza na resolução da página e fica borrada ao ampliar, limitação conhecida e sem
/// correção publicada. Como anotação do PDF o traço é vetorial e o PDFKit o redesenha
/// nítido em qualquer zoom.
///
/// O `PKDrawing` continua sendo o que se guarda: preserva o traço original e permite
/// reconverter quando o documento reabre.
enum InkAnnotator {

    /// Marca as anotações que este app criou, para poder substituí-las sem tocar nas
    /// que já vieram no arquivo.
    static let marker = "FastReadInk"

    static func annotations(from drawing: PKDrawing, pageHeight: CGFloat) -> [PDFAnnotation] {
        drawing.strokes.compactMap { annotation(from: $0, pageHeight: pageHeight) }
    }

    private static func annotation(from stroke: PKStroke, pageHeight: CGFloat) -> PDFAnnotation? {
        // Amostra a curva do PencilKit em passos regulares: o traço é uma spline, e os
        // pontos de controle sozinhos perderiam a curvatura.
        let path = stroke.path
        guard path.count > 0 else { return nil }

        var points: [CGPoint] = []
        var sizes: [CGFloat] = []
        let step = max(path.count / 128, 1)   // teto de amostras por traço

        for index in stride(from: 0, to: path.count, by: step) {
            let point = path[index]
            let transformed = point.location.applying(stroke.transform)
            points.append(InkGeometry.pdfPoint(transformed, pageHeight: pageHeight))
            sizes.append(point.size.width)
        }
        // O último ponto fecha o traço; sem ele a ponta some quando o passo não é exato.
        if let last = path.last {
            let transformed = last.location.applying(stroke.transform)
            points.append(InkGeometry.pdfPoint(transformed, pageHeight: pageHeight))
        }
        guard points.count > 1 else { return nil }

        let width = InkGeometry.lineWidth(fromSizes: sizes)
        let bounds = InkGeometry.bounds(of: points, lineWidth: width)
        guard !bounds.isNull else { return nil }

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)

        let bezier = UIBezierPath()
        bezier.move(to: points[0])
        for point in points.dropFirst() { bezier.addLine(to: point) }
        annotation.add(bezier)

        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.color = UIColor(cgColor: stroke.ink.color.cgColor)
        annotation.userName = marker

        return annotation
    }

    /// Substitui as anotações desta camada na página, preservando as demais.
    static func replaceAnnotations(on page: PDFPage, with drawing: PKDrawing) {
        for existing in page.annotations where existing.userName == marker {
            page.removeAnnotation(existing)
        }
        let height = page.bounds(for: .mediaBox).height
        for annotation in annotations(from: drawing, pageHeight: height) {
            page.addAnnotation(annotation)
        }
    }
}
