import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FastReadCore

/// Reproduz a abertura de um artigo científico: aviso do editor, cabeçalho da revista,
/// título em corpo maior, autores, afiliação e só então o texto. Nenhuma dessas linhas
/// termina em ponto — é o layout que fazia tudo virar um único trecho.
private func makeArticleOpening() throws -> PDFPage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("layout-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    func draw(_ text: String, size: CGFloat, _ rect: CGRect) {
        let attr = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, size, nil),
        ])
        CTFrameDraw(CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attr),
            CFRange(location: 0, length: 0),
            CGPath(rect: rect, transform: nil), nil), ctx)
    }

    ctx.beginPDFPage(nil)
    draw("Journal of Energy Storage 73 (2023) 109144", size: 8,
         CGRect(x: 48, y: 742, width: 516, height: 20))
    draw("Contents lists available at ScienceDirect", size: 8,
         CGRect(x: 48, y: 716, width: 516, height: 20))
    draw("Optimize the operating range for improving the cycle life", size: 15,
         CGRect(x: 48, y: 650, width: 516, height: 40))
    draw("Seon Hyeog Kim, Yong-June Shin", size: 9,
         CGRect(x: 48, y: 612, width: 516, height: 20))
    draw("Digital Convergence Research Laboratory, Electronics and Telecommunications", size: 7,
         CGRect(x: 48, y: 586, width: 516, height: 20))
    draw("""
    BESS operators using time-of-use pricing need to operate the system effectively \
    to maximize revenue while responding to demand fluctuations. However, excessive \
    discharge depth can accelerate battery aging over the operating life.
    """, size: 9, CGRect(x: 48, y: 480, width: 250, height: 90))
    ctx.endPDFPage()
    ctx.closePDF()

    guard let page = PDFDocument(url: url)?.page(at: 0) else { throw CocoaError(.fileReadUnknown) }
    return page
}

@Suite("PageLayoutAnalyzer")
struct PageLayoutAnalyzerTests {

    @Test("extrai as linhas com a geometria de cada uma")
    func extraiLinhas() throws {
        let page = try makeArticleOpening()
        let linhas = PageLayoutAnalyzer.lines(of: page)

        #expect(linhas.count >= 6)
        #expect(linhas.allSatisfy { $0.frame.height > 0 })
        #expect(linhas.allSatisfy { $0.range.length > 0 })

        // vêm na ordem de leitura, de cima para baixo
        let tops = linhas.map(\.frame.midY)
        #expect(tops == tops.sorted(by: >))
    }

    /// O bug: sem geometria, cabeçalho + título + autores viravam um trecho de 1307
    /// caracteres, e tocar em qualquer parágrafo começava a leitura no aviso do editor.
    @Test("separa cabeçalho, título, autores e corpo em blocos distintos")
    func separaBlocosDaAbertura() throws {
        let page = try makeArticleOpening()
        let texto = try #require(page.string) as NSString
        let blocos = PageLayoutAnalyzer.blocks(of: page)

        #expect(blocos.count >= 4, "esperados ao menos 4 blocos, obtidos \(blocos.count)")

        func blocoContendo(_ trecho: String) throws -> Int {
            let range = texto.range(of: trecho)
            #expect(range.location != NSNotFound, "\(trecho) não está na página")
            let indice = blocos.firstIndex { NSLocationInRange(range.location, $0.range) }
            return try #require(indice, "\(trecho) não caiu em nenhum bloco")
        }

        let cabecalho = try blocoContendo("Journal of Energy Storage")
        let titulo = try blocoContendo("Optimize the operating range")
        let autores = try blocoContendo("Seon Hyeog Kim")
        let corpo = try blocoContendo("BESS operators using")

        #expect(cabecalho != titulo, "cabeçalho e título no mesmo bloco")
        #expect(titulo != autores, "título e autores no mesmo bloco")
        #expect(autores != corpo, "autores e corpo no mesmo bloco")
    }

    @Test("nenhum bloco engole a página inteira")
    func blocosNaoSaoGigantes() throws {
        let page = try makeArticleOpening()
        let texto = try #require(page.string) as NSString
        let blocos = PageLayoutAnalyzer.blocks(of: page)

        for bloco in blocos {
            #expect(bloco.range.length < texto.length / 2,
                    "bloco de \(bloco.range.length) chars numa página de \(texto.length)")
        }
    }

    @Test("blocos cobrem o texto sem se sobrepor")
    func blocosNaoSobrepoem() throws {
        let page = try makeArticleOpening()
        let blocos = PageLayoutAnalyzer.blocks(of: page)

        for (a, b) in zip(blocos, blocos.dropFirst()) {
            #expect(NSMaxRange(a.range) <= b.range.location,
                    "blocos se sobrepõem: \(a.range) e \(b.range)")
        }
    }

    @Test("corpo com várias linhas continua num bloco só")
    func corpoNaoFragmenta() throws {
        let page = try makeArticleOpening()
        let texto = try #require(page.string) as NSString
        let blocos = PageLayoutAnalyzer.blocks(of: page)

        let range = texto.range(of: "BESS operators using")
        let bloco = try #require(blocos.first { NSLocationInRange(range.location, $0.range) })
        // o parágrafo do corpo ocupa várias linhas e não pode virar um bloco por linha
        #expect(bloco.range.length > 80, "corpo fragmentado: \(bloco.range.length) chars")
    }

    @Test("página sem texto devolve lista vazia")
    func paginaVazia() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vazia-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()

        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        #expect(PageLayoutAnalyzer.lines(of: page).isEmpty)
        #expect(PageLayoutAnalyzer.blocks(of: page).isEmpty)
    }
}
