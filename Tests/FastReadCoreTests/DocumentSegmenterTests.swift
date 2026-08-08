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

    @Test("toque fora de qualquer segmento cai no mais próximo, não no primeiro")
    func toqueForaDeSegmento() throws {
        // Reproduz o layout que falhou no iPad: autores no topo, corpo abaixo.
        let doc = try makePDF(pages: [
            "Rafael Garcia, Maria Silva, John Smith, Ana Costa.\n"
            + "Abstract. This paper presents a method for reading documents aloud.\n"
            + "We evaluate the approach on a corpus of scientific articles today.",
        ])
        let s = DocumentSegmenter()
        let segs = s.segments(of: doc, documentLanguage: "en")
        #expect(segs.count >= 3)

        // um índice logo depois do fim do último segmento não pode voltar ao topo
        let ultimo = try #require(segs.last)
        let logoDepois = NSMaxRange(try #require(ultimo.pageRange)) + 1
        #expect(s.segment(in: segs, pageIndex: 0, characterIndex: logoDepois)?.id == ultimo.id)

        // e um índice muito além também escolhe o último, não o bloco de autores
        #expect(s.segment(in: segs, pageIndex: 0, characterIndex: 99_999)?.id == ultimo.id)
    }

    @Test("toque dentro de um segmento resolve exatamente para ele")
    func toqueDentroDeCadaSegmento() throws {
        let doc = try makePDF(pages: [
            "First paragraph about alpha particles here.\n"
            + "Second paragraph about gamma radiation here.",
        ])
        let s = DocumentSegmenter()
        let segs = s.segments(of: doc, documentLanguage: "en")
        #expect(segs.count == 2)

        // Um caractere exatamente entre dois segmentos contíguos fica equidistante, e
        // qualquer escolha é defensável — o que não pode acontecer é voltar ao topo.
        for seg in segs {
            let range = try #require(seg.pageRange)
            let meio = range.location + range.length / 2
            #expect(s.segment(in: segs, pageIndex: 0, characterIndex: meio)?.id == seg.id)
        }
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

    // MARK: - Realce de um trecho com buraco

    /// Quando a fórmula sai do meio do trecho, o texto falado deixa de ser contíguo na
    /// página. `pageRange` sozinho vai do primeiro ao último índice e por isso cobre o
    /// que foi removido — o realce pintava a equação que a voz não lê.
    private func comBuraco() -> DocumentSegment {
        // "abc" nas posições 10..12 e "xyz" nas posições 30..32; 13..29 saíram.
        let mapa = [10, 11, 12, 30, 31, 32]
        return DocumentSegment(id: 0, pageIndex: 0,
                               segment: MappedSegment(text: "abcxyz", sourceIndices: mapa),
                               language: "en")
    }

    @Test("os trechos realçados pulam o que foi removido")
    func realcePulaBuraco() {
        let seg = comBuraco()
        #expect(seg.pageRanges == [NSRange(location: 10, length: 3),
                                   NSRange(location: 30, length: 3)])
    }

    @Test("texto contíguo continua um intervalo só")
    func contiguoIntervaloUnico() throws {
        let doc = try makePDF(pages: [
            "The reader highlights every word while the voice moves through the paragraph.",
        ])
        let seg = try #require(DocumentSegmenter().segments(of: doc, documentLanguage: "en").first)
        #expect(seg.pageRanges.count == 1)
        #expect(seg.pageRanges.first == seg.pageRange)
    }

    /// Tocar sobre a equação não pode resolver como se ela pertencesse ao trecho: o que
    /// vale é o texto que a voz realmente lê.
    @Test("índice dentro do buraco não conta como pertencente ao trecho")
    func buracoNaoPertence() {
        let seg = comBuraco()
        #expect(seg.contains(pageCharacterIndex: 11))
        #expect(seg.contains(pageCharacterIndex: 31))
        #expect(seg.contains(pageCharacterIndex: 20) == false)
    }
}
