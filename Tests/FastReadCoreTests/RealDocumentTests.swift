import Foundation
import PDFKit
import Testing
@testable import FastReadCore

/// Valida contra PDFs de verdade, quando houver algum apontado por `FASTREAD_SAMPLE_PDFS`.
///
/// Os PDFs não entram no repositório — são artigos de terceiros. Sem a variável, a suíte
/// pula estes testes; com ela, eles cobrem o que nenhum PDF sintético reproduziu: a
/// abertura de um artigo científico, onde cabeçalho, título e autores não têm pontuação
/// final e por isso viravam um único trecho de 1307 caracteres.
///
///     FASTREAD_SAMPLE_PDFS=/caminho/para/pasta swift test
/// Localiza PDFs reais apontados por `FASTREAD_SAMPLE_PDFS`.
///
/// Fica fora da suíte porque o trait `.enabled(if:)` é avaliado ao construir o tipo —
/// consultá-lo de dentro dele mesmo é referência circular.
enum SamplePDFs {
    static var files: [URL] {
        guard let root = ProcessInfo.processInfo.environment["FASTREAD_SAMPLE_PDFS"] else { return [] }
        let base = URL(fileURLWithPath: root)
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

@Suite("Documentos reais", .enabled(if: !SamplePDFs.files.isEmpty))
struct RealDocumentTests {


    @Test("nenhum trecho engole a abertura inteira do artigo")
    func aberturaNaoViraTrechoUnico() throws {
        let arquivos = SamplePDFs.files

        let segmenter = DocumentSegmenter()
        var analisados = 0

        for arquivo in arquivos.prefix(12) {
            guard let doc = PDFDocument(url: arquivo),
                  let pageText = doc.page(at: 0)?.string, pageText.count > 500 else { continue }

            let segs = segmenter.segments(of: doc, documentLanguage: "en")
                .filter { $0.pageIndex == 0 }
            guard !segs.isEmpty else { continue }
            analisados += 1

            let maior = segs.map(\.text.count).max() ?? 0
            #expect(maior < 900,
                    "\(arquivo.lastPathComponent): maior trecho da página 1 tem \(maior) chars")

            // O primeiro trecho não pode ir do aviso do editor até o meio da página.
            let primeiro = segs[0].text.count
            #expect(primeiro < 700, "\(arquivo.lastPathComponent): trecho inicial de \(primeiro) chars")
        }
        #expect(analisados > 0, "nenhum PDF com texto utilizável")
    }

    @Test("tocar no corpo não resolve para o cabeçalho")
    func toqueNoCorpoNaoVaiParaCabecalho() throws {
        let arquivos = SamplePDFs.files

        let segmenter = DocumentSegmenter()
        var verificados = 0

        for arquivo in arquivos.prefix(12) {
            guard let doc = PDFDocument(url: arquivo),
                  let page = doc.page(at: 0),
                  let pageText = page.string as NSString?, pageText.length > 1000 else { continue }

            let segs = segmenter.segments(of: doc, documentLanguage: "en")
            guard segs.count > 3 else { continue }

            // Escolhe um trecho do corpo — bem depois da abertura — e toca no meio dele.
            let corpo = segs.filter { $0.pageIndex == 0 }.dropFirst(3).first
            guard let corpo, let range = corpo.pageRange else { continue }

            let meio = range.location + range.length / 2
            let encontrado = segmenter.segment(in: segs, pageIndex: 0, characterIndex: meio)

            #expect(encontrado?.id == corpo.id,
                    "\(arquivo.lastPathComponent): toque no trecho #\(corpo.id) abriu #\(encontrado?.id ?? -1)")
            verificados += 1
        }
        #expect(verificados > 0)
    }

    @Test("a palavra realçada é a mesma que o alinhamento aponta")
    func realceBateComOAlinhamento() throws {
        let arquivos = SamplePDFs.files

        let segmenter = DocumentSegmenter()
        var conferidas = 0
        var divergentes: [String] = []

        for arquivo in arquivos.prefix(8) {
            guard let doc = PDFDocument(url: arquivo),
                  let page = doc.page(at: 0),
                  let pageText = page.string as NSString? else { continue }

            for seg in segmenter.segments(of: doc, documentLanguage: "en")
                .filter({ $0.pageIndex == 0 }).prefix(6) {

                let texto = seg.text as NSString
                // amostra palavras ao longo do trecho
                for fracao in [0.1, 0.4, 0.8] {
                    let pos = Int(Double(texto.length) * fracao)
                    let busca = texto.rangeOfCharacter(from: .letters,
                                                       options: [],
                                                       range: NSRange(location: pos, length: texto.length - pos))
                    guard busca.location != NSNotFound else { continue }
                    let fim = texto.rangeOfCharacter(from: .whitespaces, options: [],
                                                     range: NSRange(location: busca.location,
                                                                    length: texto.length - busca.location))
                    let comprimento = (fim.location == NSNotFound ? texto.length : fim.location) - busca.location
                    guard comprimento > 3 else { continue }

                    let noTrecho = NSRange(location: busca.location, length: comprimento)
                    let palavra = texto.substring(with: noTrecho)
                    guard let naPagina = seg.segment.sourceRange(for: noTrecho),
                          NSMaxRange(naPagina) <= pageText.length else { continue }

                    let realcada = PageTextLocator.selection(on: page, matching: naPagina, in: pageText)?.string
                    conferidas += 1
                    if realcada?.trimmingCharacters(in: .whitespacesAndNewlines) != palavra {
                        divergentes.append("\(palavra) -> \(realcada ?? "nil")")
                    }
                }
            }
        }

        #expect(conferidas > 10, "poucas amostras: \(conferidas)")
        let taxa = Double(divergentes.count) / Double(max(conferidas, 1))
        #expect(taxa < 0.1,
                "\(divergentes.count)/\(conferidas) divergiram: \(divergentes.prefix(5))")
    }
}
