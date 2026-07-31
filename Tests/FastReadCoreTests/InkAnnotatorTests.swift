import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import Testing
@testable import FastReadCore

/// O teste que faltava: `InkGeometry` cobria a conta, mas a conversão em si — que é onde
/// o traço continuava borrado — não tinha nenhum.
private func makeStroke(from: CGPoint, to: CGPoint, width: CGFloat = 3) -> PKStroke {
    let pontos = stride(from: 0.0, through: 1.0, by: 0.1).map { t in
        PKStrokePoint(
            location: CGPoint(x: from.x + (to.x - from.x) * t,
                              y: from.y + (to.y - from.y) * t),
            timeOffset: t,
            size: CGSize(width: width, height: width),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.pen, color: .black),
                    path: PKStrokePath(controlPoints: pontos, creationDate: Date()))
}

private func makePage() throws -> PDFPage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ink-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    ctx.beginPDFPage(nil)
    ctx.endPDFPage()
    ctx.closePDF()
    guard let page = PDFDocument(url: url)?.page(at: 0) else { throw CocoaError(.fileReadUnknown) }
    return page
}

@Suite("InkAnnotator")
struct InkAnnotatorTests {

    @Test("um traço vira uma anotação")
    func tracoViraAnotacao() {
        let drawing = PKDrawing(strokes: [makeStroke(from: CGPoint(x: 100, y: 100),
                                                     to: CGPoint(x: 200, y: 150))])
        let anotacoes = InkAnnotator.annotations(from: drawing, pageHeight: 792)

        #expect(anotacoes.count == 1)
        #expect(anotacoes.first?.type == "Ink")
    }

    @Test("cada traço vira sua própria anotação")
    func varosTracos() {
        let drawing = PKDrawing(strokes: [
            makeStroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60)),
            makeStroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 160)),
            makeStroke(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 260, y: 260)),
        ])
        #expect(InkAnnotator.annotations(from: drawing, pageHeight: 792).count == 3)
    }

    @Test("desenho vazio não produz anotação")
    func desenhoVazio() {
        #expect(InkAnnotator.annotations(from: PKDrawing(), pageHeight: 792).isEmpty)
    }

    /// O UIKit tem origem no topo e o PDF na base: inverter errado joga a anotação para
    /// o lado oposto da página.
    @Test("a anotação cai na altura correspondente da página")
    func posicaoVertical() throws {
        // traço no terço superior da tela
        let drawing = PKDrawing(strokes: [makeStroke(from: CGPoint(x: 100, y: 100),
                                                     to: CGPoint(x: 200, y: 120))])
        let anotacao = try #require(InkAnnotator.annotations(from: drawing, pageHeight: 792).first)

        // deve aparecer no terço superior da página, onde y é grande
        #expect(anotacao.bounds.midY > 600)
        #expect(anotacao.bounds.midY < 750)
    }

    @Test("a anotação envolve o traço com folga")
    func areaEnvolve() throws {
        let drawing = PKDrawing(strokes: [makeStroke(from: CGPoint(x: 100, y: 200),
                                                     to: CGPoint(x: 300, y: 200), width: 4)])
        let anotacao = try #require(InkAnnotator.annotations(from: drawing, pageHeight: 792).first)

        #expect(anotacao.bounds.width >= 200)
        #expect(anotacao.bounds.height > 0)
        #expect(anotacao.bounds.minX <= 100)
        #expect(anotacao.bounds.maxX >= 300)
    }

    @Test("a espessura acompanha o traço")
    func espessura() throws {
        let fino = try #require(InkAnnotator.annotations(
            from: PKDrawing(strokes: [makeStroke(from: .zero, to: CGPoint(x: 50, y: 50), width: 1)]),
            pageHeight: 792).first)
        let grosso = try #require(InkAnnotator.annotations(
            from: PKDrawing(strokes: [makeStroke(from: .zero, to: CGPoint(x: 50, y: 50), width: 8)]),
            pageHeight: 792).first)

        #expect(grosso.border?.lineWidth ?? 0 > fino.border?.lineWidth ?? 0)
    }

    // MARK: - Aplicação na página

    @Test("as anotações entram na página")
    func entramNaPagina() throws {
        let page = try makePage()
        #expect(page.annotations.isEmpty)

        let drawing = PKDrawing(strokes: [makeStroke(from: CGPoint(x: 50, y: 50),
                                                     to: CGPoint(x: 150, y: 150))])
        InkAnnotator.replaceAnnotations(on: page, with: drawing)

        #expect(page.annotations.count == 1)
        #expect(page.annotations.first?.userName == InkAnnotator.marker)
    }

    @Test("reaplicar substitui em vez de acumular")
    func substituiNaoAcumula() throws {
        let page = try makePage()
        let drawing = PKDrawing(strokes: [makeStroke(from: .zero, to: CGPoint(x: 100, y: 100))])

        InkAnnotator.replaceAnnotations(on: page, with: drawing)
        InkAnnotator.replaceAnnotations(on: page, with: drawing)
        InkAnnotator.replaceAnnotations(on: page, with: drawing)

        #expect(page.annotations.count == 1)
    }

    /// Um PDF pode já trazer anotações suas; substituir as nossas não pode apagá-las.
    @Test("preserva anotações que já estavam no arquivo")
    func preservaAlheias() throws {
        let page = try makePage()
        let alheia = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
                                   forType: .highlight, withProperties: nil)
        page.addAnnotation(alheia)

        InkAnnotator.replaceAnnotations(on: page, with: PKDrawing(strokes: [
            makeStroke(from: .zero, to: CGPoint(x: 80, y: 80)),
        ]))

        #expect(page.annotations.count == 2)
        #expect(page.annotations.contains { $0.type == "Highlight" })
    }

    @Test("desenho vazio limpa as anotações desta camada")
    func vazioLimpa() throws {
        let page = try makePage()
        InkAnnotator.replaceAnnotations(on: page, with: PKDrawing(strokes: [
            makeStroke(from: .zero, to: CGPoint(x: 60, y: 60)),
        ]))
        #expect(page.annotations.count == 1)

        InkAnnotator.replaceAnnotations(on: page, with: PKDrawing())
        #expect(page.annotations.isEmpty)
    }
}
