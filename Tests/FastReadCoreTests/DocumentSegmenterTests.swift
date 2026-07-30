import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FastReadCore

/// Gera um PDF real em memória para exercitar a extração de texto do PDFKit.
private func makePDF(pages: [String]) throws -> PDFDocument {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("doc-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)

    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    for body in pages {
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: body, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
    }
    context.closePDF()

    guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadUnknown) }
    return document
}

@Suite("DocumentSegmenter")
struct DocumentSegmenterTests {

    @Test("extrai segmentos de um PDF de verdade")
    func extraiSegmentos() throws {
        let doc = try makePDF(pages: [
            "The reader highlights every word while the voice moves through the paragraph.\n\nA second paragraph follows with more content to read aloud.",
        ])
        let s = DocumentSegmenter()
        let segs = s.segments(of: doc, documentLanguage: "en")

        #expect(segs.count >= 2)
        #expect(segs.allSatisfy { $0.pageIndex == 0 })
        #expect(segs.map(\.id) == Array(0..<segs.count))
    }

    @Test("mantém o número da página em documento de várias páginas")
    func varioasPaginas() throws {
        let doc = try makePDF(pages: [
            "First page content that should be read aloud by the synthesizer.",
            "Second page content that also deserves to be read aloud here.",
        ])
        let segs = DocumentSegmenter().segments(of: doc, documentLanguage: "en")

        #expect(segs.contains { $0.pageIndex == 0 })
        #expect(segs.contains { $0.pageIndex == 1 })
    }

    @Test("detecta o idioma do documento")
    func detectaIdioma() throws {
        let doc = try makePDF(pages: [
            "The quick analysis of neural networks reveals that gradient descent converges under mild assumptions.",
        ])
        #expect(DocumentSegmenter().documentLanguage(of: doc) == "en")
    }

    @Test("documento sem texto cai no fallback")
    func documentoVazio() throws {
        let doc = try makePDF(pages: [" "])
        #expect(DocumentSegmenter().documentLanguage(of: doc, fallback: "pt") == "pt")
        #expect(DocumentSegmenter().segments(of: doc, documentLanguage: "pt").isEmpty)
    }

    @Test("pageRange aponta para dentro do texto da página")
    func pageRangeValido() throws {
        let doc = try makePDF(pages: [
            "The reader highlights every word while the voice moves through the paragraph.",
        ])
        let segs = DocumentSegmenter().segments(of: doc, documentLanguage: "en")
        let first = try #require(segs.first)
        let pageText = try #require(doc.page(at: 0)?.string) as NSString
        let range = try #require(first.pageRange)

        #expect(NSMaxRange(range) <= pageText.length)
        // o texto da página naquele intervalo tem que conter as palavras do segmento
        let trecho = pageText.substring(with: range)
        #expect(trecho.contains("reader"))
    }

    @Test("toque no meio do texto resolve para o segmento certo")
    func toqueResolveSegmento() throws {
        let doc = try makePDF(pages: [
            "First paragraph about alpha and beta particles in the lab.\n\nSecond paragraph about gamma radiation and its uses.",
        ])
        let s = DocumentSegmenter()
        let segs = s.segments(of: doc, documentLanguage: "en")
        #expect(segs.count >= 2)

        let alvo = segs[1]
        let meio = try #require(alvo.pageRange).location + 2
        let encontrado = try #require(s.segment(in: segs, pageIndex: 0, characterIndex: meio))

        #expect(encontrado.id == alvo.id)
    }

    @Test("toque fora de qualquer segmento cai no primeiro da página")
    func toqueForaDeSegmento() throws {
        let doc = try makePDF(pages: ["Only one paragraph exists on this page for now."])
        let s = DocumentSegmenter()
        let segs = s.segments(of: doc, documentLanguage: "en")
        let encontrado = s.segment(in: segs, pageIndex: 0, characterIndex: 99_999)
        #expect(encontrado?.id == segs.first?.id)
    }

    @Test("o range de uma palavra do alinhamento cai sobre a palavra na página")
    func rangeDePalavraNaPagina() throws {
        let doc = try makePDF(pages: [
            "The reader highlights every word while the voice moves through the paragraph.",
        ])
        let segs = DocumentSegmenter().segments(of: doc, documentLanguage: "en")
        let seg = try #require(segs.first)

        let normalized = seg.text as NSString
        let alvo = normalized.range(of: "highlights")
        #expect(alvo.location != NSNotFound)

        let naPagina = try #require(seg.segment.sourceRange(for: alvo))
        let pageText = try #require(doc.page(at: 0)?.string) as NSString
        #expect(pageText.substring(with: naPagina) == "highlights")
    }
}
