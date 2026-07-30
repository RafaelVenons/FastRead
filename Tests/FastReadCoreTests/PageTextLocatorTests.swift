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

    /// Bug relatado no iPad: tocar no primeiro parágrafo começava a leitura no cabeçalho
    /// da revista. Numa página densa o erro da fórmula acumula linha a linha, até pular
    /// para o bloco anterior.
    @Test("índice continua exato no fim de uma página densa")
    func precisaoEmPaginaDensa() throws {
        let cabecalho = "Journal of Document Engineering, Vol. 12, No. 3, 2026, pp. 45-67.\n"
        let corpo = (1...25).map {
            "Paragraph number \($0) discusses an aspect of the alignment problem in detail."
        }.joined(separator: "\n")
        let page = try makePage(cabecalho + corpo)
        let texto = try #require(page.string) as NSString

        // palavras espalhadas, inclusive bem no fim da página
        for alvo in ["Journal", "number 1 ", "number 12", "number 25"] {
            let range = texto.range(of: alvo)
            guard range.location != NSNotFound else { continue }

            let bounds = try #require(PageTextLocator.selection(on: page, matching: range, in: texto)?
                .bounds(for: page))
            let indice = try #require(PageTextLocator.characterIndex(
                on: page, at: CGPoint(x: bounds.midX, y: bounds.midY), in: texto))

            #expect(NSLocationInRange(indice, range),
                    "\(alvo.debugDescription): esperado dentro de \(range), obtido \(indice)")
        }
    }

    /// O destaque "passava um pouco" do parágrafo: para um trecho de várias linhas o
    /// texto da seleção difere do de `page.string` no espaçamento, a verificação sempre
    /// falhava e caía num candidato desalinhado.
    @Test("seleção de trecho multi-linha não extrapola o trecho")
    func trechoMultiLinha() throws {
        let page = try makePage(artigo)
        let texto = try #require(page.string) as NSString
        let range = texto.range(of: "Abstract. This paper presents a method for reading documents aloud.")
        #expect(range.location != NSNotFound)

        let selection = try #require(PageTextLocator.selection(on: page, matching: range, in: texto))
        let obtido = selection.string ?? ""

        // pode diferir em espaçamento, mas não pode invadir o parágrafo vizinho
        #expect(obtido.contains("Abstract"))
        #expect(obtido.contains("aloud"))
        #expect(obtido.contains("The system") == false, "invadiu o parágrafo seguinte")
        #expect(obtido.contains("Rafael") == false, "invadiu o bloco anterior")
    }

    /// Propriedade que não depende de reproduzir um layout específico: sair de um índice
    /// de `page.string`, ir até a geometria e voltar tem que cair na mesma palavra.
    /// É o que garante que o toque resolve o trecho certo em qualquer PDF.
    @Test("ida e volta entre índice e geometria preserva a palavra")
    func roundTripIndiceGeometria() throws {
        let cabecalho = "Journal of Document Engineering, Vol. 12, No. 3, 2026, pp. 45-67.\n"
        let corpo = (1...20).map {
            "Paragraph \($0) discusses one aspect of the alignment problem in some detail."
        }.joined(separator: "\n")
        let page = try makePage(cabecalho + corpo)
        let texto = try #require(page.string) as NSString

        var verificadas = 0
        for palavra in ["Journal", "Engineering", "Paragraph", "alignment", "detail"] {
            var busca = NSRange(location: 0, length: texto.length)
            while true {
                let range = texto.range(of: palavra, options: [], range: busca)
                guard range.location != NSNotFound else { break }
                busca = NSRange(location: NSMaxRange(range),
                                length: texto.length - NSMaxRange(range))

                guard let selection = PageTextLocator.selection(on: page, matching: range, in: texto),
                      let bounds = selection.bounds(for: page) as CGRect?, !bounds.isNull
                else { continue }

                let volta = try #require(PageTextLocator.characterIndex(
                    on: page, at: CGPoint(x: bounds.midX, y: bounds.midY), in: texto))

                // tem que cair na mesma ocorrência, não numa anterior nem no cabeçalho
                #expect(NSLocationInRange(volta, range),
                        "\(palavra) em \(range.location): voltou \(volta)")
                verificadas += 1
                if verificadas > 40 { break }
            }
        }
        #expect(verificadas > 20, "poucas amostras verificadas: \(verificadas)")
    }

    /// Layout de duas colunas com cabeçalho de largura total — o formato do artigo que
    /// o usuário estava lendo.
    private func makeTwoColumnPage() throws -> PDFPage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("col-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        func draw(_ text: String, _ rect: CGRect) {
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            CTFrameDraw(CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(attr),
                CFRange(location: 0, length: 0),
                CGPath(rect: rect, transform: nil), nil), ctx)
        }
        ctx.beginPDFPage(nil)
        draw("Journal of Document Engineering, Vol. 12, No. 3, 2026, pp. 45-67.",
             CGRect(x: 48, y: 730, width: 516, height: 30))
        draw("""
        LEFT-A First paragraph of the left column discusses the alignment problem in detail here.

        LEFT-B Second paragraph of the left column continues the discussion with more content.
        """, CGRect(x: 48, y: 400, width: 240, height: 320))
        draw("""
        RIGHT-A First paragraph of the right column presents the evaluation of our method.

        RIGHT-B Second paragraph of the right column reports the results we obtained.
        """, CGRect(x: 320, y: 400, width: 240, height: 320))
        ctx.endPDFPage()
        ctx.closePDF()

        guard let page = PDFDocument(url: url)?.page(at: 0) else { throw CocoaError(.fileReadUnknown) }
        return page
    }

    /// Bug relatado: o realce ia "até a primeira palavra depois do ponto", acendendo
    /// texto que a voz não lia.
    @Test("realce não invade o parágrafo seguinte")
    func realceNaoInvadeProximoParagrafo() throws {
        let page = try makeTwoColumnPage()
        let texto = try #require(page.string) as NSString

        for alvo in ["LEFT-A First paragraph of the left column discusses\nthe alignment problem in detail here.",
                     "RIGHT-A First paragraph of the right column presents\nthe evaluation of our method.",
                     "Journal of Document Engineering, Vol. 12, No. 3, 2026, pp. 45-67."] {
            let range = texto.range(of: alvo)
            guard range.location != NSNotFound else { continue }

            let obtido = try #require(PageTextLocator.selection(on: page, matching: range, in: texto)?.string)
            let semQuebras = obtido.replacingOccurrences(of: "\n", with: " ")
            let esperado = alvo.replacingOccurrences(of: "\n", with: " ")

            #expect(semQuebras == esperado,
                    "sobrou \(semQuebras.dropFirst(esperado.count).debugDescription)")
        }
    }

    @Test("realce de uma coluna não pega texto da outra")
    func realceNaoAtravessaColunas() throws {
        let page = try makeTwoColumnPage()
        let texto = try #require(page.string) as NSString
        let range = texto.range(of: "LEFT-B Second paragraph of the left column")
        guard range.location != NSNotFound else { return }

        let obtido = try #require(PageTextLocator.selection(on: page, matching: range, in: texto)?.string)
        #expect(obtido.contains("RIGHT") == false, "vazou para a coluna direita")
    }

    @Test("toque em cada coluna resolve para a coluna certa")
    func toqueRespeitaColuna() throws {
        let page = try makeTwoColumnPage()
        let texto = try #require(page.string) as NSString

        for marca in ["LEFT-A", "LEFT-B", "RIGHT-A", "RIGHT-B"] {
            let range = texto.range(of: marca)
            guard range.location != NSNotFound else { continue }

            let bounds = try #require(PageTextLocator.selection(on: page, matching: range, in: texto)?
                .bounds(for: page))
            let indice = try #require(PageTextLocator.characterIndex(
                on: page, at: CGPoint(x: bounds.midX, y: bounds.midY), in: texto))

            #expect(NSLocationInRange(indice, range),
                    "\(marca): toque resolveu para \(indice), esperado dentro de \(range)")
        }
    }

    /// O toque do usuário raramente acerta um glifo: cai na entrelinha, na margem
    /// interna, no recuo do parágrafo. Em duas colunas isso é perigoso, porque na mesma
    /// altura existe texto da outra coluna — e ele pertence a outra parte do documento.
    @Test("toque fora de glifo não pula para a outra coluna")
    func toqueForaDeGlifoNaoTrocaDeColuna() throws {
        let page = try makeTwoColumnPage()
        let texto = try #require(page.string) as NSString

        let direita = texto.range(of: "RIGHT-A")
        let esquerda = texto.range(of: "LEFT-A")
        let boundsDireita = try #require(PageTextLocator.selection(on: page, matching: direita, in: texto)?
            .bounds(for: page))

        // logo à esquerda do início da coluna direita — no vão entre as colunas,
        // exatamente na altura em que a coluna esquerda também tem texto
        let noVao = CGPoint(x: boundsDireita.minX - 12, y: boundsDireita.midY)
        #expect(page.characterIndex(at: noVao) == NSNotFound, "premissa: está fora de um glifo")

        let indice = try #require(PageTextLocator.characterIndex(on: page, at: noVao, in: texto))
        #expect(indice > esquerda.location,
                "caiu no começo da coluna esquerda (\(indice)) em vez da direita")

        // e um toque logo acima da primeira linha da coluna direita, no recuo
        let acima = CGPoint(x: boundsDireita.midX, y: boundsDireita.maxY + 4)
        let indiceAcima = try #require(PageTextLocator.characterIndex(on: page, at: acima, in: texto))
        #expect(indiceAcima >= direita.location - 4,
                "toque acima da coluna direita resolveu para \(indiceAcima)")
    }

    @Test("página sem texto não resolve toque")
    func paginaVazia() throws {
        let page = try makePage(" ")
        let texto = (page.string ?? "") as NSString
        #expect(PageTextLocator.characterIndex(on: page, at: CGPoint(x: 100, y: 100), in: texto) == nil)
    }
}
