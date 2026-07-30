import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FastReadCore

/// Layout de artigo: título, autores, corpo — o caso que quebrou no iPad.
private let artigo = """
Deep Learning for Document Understanding

Rafael Garcia, Maria Silva, John Smith, Ana Costa

Abstract. This paper presents a method for reading documents aloud.
The system aligns synthesized speech with the source text.
We evaluate the approach on a corpus of scientific articles.
"""

private func makePage(_ body: String) throws -> PDFPage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("loc-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    ctx.beginPDFPage(nil)
    let attr = NSAttributedString(string: body, attributes: [
        .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
    ])
    let fs = CTFramesetterCreateWithAttributedString(attr)
    CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0),
                                         CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil), nil), ctx)
    ctx.endPDFPage()
    ctx.closePDF()

    guard let page = PDFDocument(url: url)?.page(at: 0) else { throw CocoaError(.fileReadUnknown) }
    return page
}

@Suite("PageTextLocator")
struct PageTextLocatorTests {

    /// Medido: `characterBounds(at:)` não indexa igual a `page.string` — o desvio cresce
    /// com as quebras de linha, e nem sempre é exatamente o número delas.
    @Test("seleciona a palavra certa em qualquer posição da página")
    func selecionaPalavraCerta() throws {
        let page = try makePage(artigo)
        let texto = try #require(page.string) as NSString

        // "articles" é o caso que a fórmula ingênua erra por 1
        for alvo in ["Deep", "Rafael", "Garcia", "Abstract", "presents",
                     "system", "corpus", "articles", "text"] {
            let range = texto.range(of: alvo)
            #expect(range.location != NSNotFound, "\(alvo) não está na página")

            let selection = PageTextLocator.selection(on: page, matching: range, in: texto)
            #expect(selection?.string == alvo, "esperado \(alvo), obtido \(selection?.string ?? "nil")")
        }
    }

    @Test("range inválido não produz seleção")
    func rangeInvalido() throws {
        let page = try makePage(artigo)
        let texto = try #require(page.string) as NSString

        #expect(PageTextLocator.selection(on: page, matching: NSRange(location: NSNotFound, length: 3), in: texto) == nil)
        #expect(PageTextLocator.selection(on: page, matching: NSRange(location: 0, length: 0), in: texto) == nil)
        #expect(PageTextLocator.selection(on: page, matching: NSRange(location: 99_999, length: 4), in: texto) == nil)
    }

    @Test("seleciona um trecho de várias palavras")
    func trechoLongo() throws {
        let page = try makePage(artigo)
        let texto = try #require(page.string) as NSString
        let range = texto.range(of: "This paper presents")

        let selection = PageTextLocator.selection(on: page, matching: range, in: texto)
        #expect(selection?.string == "This paper presents")
    }

    // MARK: - Hit testing

    /// O bug do iPad: tocar no início de um parágrafo abria o bloco de autores, porque
    /// `characterIndex(at:)` devolve `NSNotFound` fora de um glifo e o código caía no
    /// primeiro segmento da página.
    @Test("toque sobre um glifo devolve o índice daquele caractere")
    func toqueSobreGlifo() throws {
        let page = try makePage(artigo)
        let texto = try #require(page.string) as NSString
        let range = texto.range(of: "Abstract")

        let bounds = try #require(PageTextLocator.selection(on: page, matching: range, in: texto)?
            .bounds(for: page))
        let indice = try #require(PageTextLocator.characterIndex(on: page,
                                                                at: CGPoint(x: bounds.midX, y: bounds.midY),
                                                                in: texto))
        // cai dentro da palavra "Abstract"
        #expect(indice >= range.location)
        #expect(indice < NSMaxRange(range))
    }

    @Test("toque na margem cai no texto mais próximo, não no início da página")
    func toqueNaMargem() throws {
        let page = try makePage(artigo)
        let texto = try #require(page.string) as NSString

        // altura da linha dos autores, mas na margem esquerda — fora de qualquer glifo
        let autores = texto.range(of: "Rafael")
        let bounds = try #require(PageTextLocator.selection(on: page, matching: autores, in: texto)?
            .bounds(for: page))
        let naMargem = CGPoint(x: 5, y: bounds.midY)

        #expect(page.characterIndex(at: naMargem) == NSNotFound, "premissa: PDFKit não resolve isto")

        let indice = try #require(PageTextLocator.characterIndex(on: page, at: naMargem, in: texto))
        let linhaDosAutores = texto.range(of: "Rafael Garcia, Maria Silva, John Smith, Ana Costa")
        #expect(NSLocationInRange(indice, linhaDosAutores),
                "devia cair na linha dos autores, caiu em \(indice)")
    }

    @Test("toque muito abaixo do texto ainda resolve para algum caractere")
    func toqueForaDoTexto() throws {
        let page = try makePage(artigo)
        let texto = try #require(page.string) as NSString
        let indice = PageTextLocator.characterIndex(on: page, at: CGPoint(x: 300, y: 15), in: texto)
        #expect(indice != nil)
        #expect(indice! >= 0)
        #expect(indice! < texto.length)
    }

    @Test("página sem texto não resolve toque")
    func paginaVazia() throws {
        let page = try makePage(" ")
        let texto = (page.string ?? "") as NSString
        #expect(PageTextLocator.characterIndex(on: page, at: CGPoint(x: 100, y: 100), in: texto) == nil)
    }
}
