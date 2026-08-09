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

    /// Nos artigos medidos, 15 de 89 linhas de uma página terminam com hífen. Um trecho
    /// que termine assim significa que a palavra foi partida entre dois trechos — a voz
    /// lê "relia-" e o trecho seguinte começa em "bility".
    @Test("nenhum trecho termina com palavra partida")
    func nenhumTrechoTerminaEmHifen() throws {
        let arquivos = SamplePDFs.files
        let segmenter = DocumentSegmenter()
        var partidos: [String] = []
        var analisados = 0

        for arquivo in arquivos.prefix(12) {
            guard let doc = PDFDocument(url: arquivo) else { continue }
            let segs = segmenter.segments(of: doc, documentLanguage: "en")

            // O último trecho de uma página pode terminar partido de forma legítima: a
            // continuação está na página seguinte, e juntá-las faria um trecho com texto
            // de duas páginas — o realce só sabe pintar uma.
            let ultimoDeCadaPagina = Set(Dictionary(grouping: segs, by: \.pageIndex)
                .compactMap { $0.value.last?.id })

            for seg in segs where !ultimoDeCadaPagina.contains(seg.id) {
                analisados += 1
                let fim = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard fim.hasSuffix("-"), fim.count > 1,
                      fim.dropLast().last?.isLetter == true else { continue }
                partidos.append("\(arquivo.lastPathComponent) #\(seg.id): ...\(fim.suffix(28))")
            }
        }

        #expect(analisados > 50, "poucos trechos analisados: \(analisados)")
        #expect(partidos.isEmpty, "\(partidos.count) trechos partidos: \(partidos.prefix(4))")
    }

    /// A assinatura do bug: um parágrafo longo cortado, com a cauda virando trecho
    /// próprio — foi assim que "points of view." apareceu sozinho, separado da frase que
    /// terminava. Só conta texto corrido: sumários e tabelas têm linhas soltas em caixa
    /// baixa por natureza, e não é disso que se trata.
    /// Prova independente da costura: mede o CONTEÚDO do que será falado, não a fronteira
    /// entre trechos. Unir trechos demais zeraria o invariante de cortes sem melhorar
    /// nada — este aqui só passa se as fórmulas de fato saírem do texto.
    @Test("nenhum trecho falado contém fórmula")
    func nenhumaFormulaNaFala() throws {
        let arquivos = SamplePDFs.files
        let segmenter = DocumentSegmenter()
        var comFormula: [String] = []
        var analisados = 0

        for arquivo in arquivos.prefix(12) {
            guard let doc = PDFDocument(url: arquivo) else { continue }
            for seg in segmenter.segments(of: doc, documentLanguage: "en") {
                analisados += 1
                guard MathFilter.containsMathRun(seg.text) else { continue }
                comFormula.append(String(seg.text.prefix(48)))
            }
        }

        #expect(analisados > 100, "poucos trechos analisados: \(analisados)")
        let taxa = Double(comFormula.count) / Double(max(analisados, 1))
        let amostra = comFormula.prefix(4).joined(separator: " ## ")
        #expect(taxa < 0.02, "\(comFormula.count)/\(analisados) trechos com fórmula: \(amostra)")
    }

    /// O realce de um trecho é desenhado um pedaço por vez, e cada pedaço passa pela
    /// autocorreção do localizador por conta própria — então partir o trecho sem motivo
    /// não é só desperdício, é destaque errado. Só a fórmula removida justifica partir.
    ///
    /// Medido quando o corte era ingênuo: 33 partições em três páginas, todas em `"-\n"`,
    /// o hífen de quebra de linha.
    @Test("o realce não se estilhaça em palavra hifenizada")
    func realceNaoEstilhaca() throws {
        let arquivos = SamplePDFs.files
        let segmenter = DocumentSegmenter()
        var inteiros = 0, partidos = 0
        var exemplos: [String] = []

        for arquivo in arquivos.prefix(12) {
            guard let doc = PDFDocument(url: arquivo) else { continue }
            for seg in segmenter.segments(of: doc, documentLanguage: "en") {
                let partes = seg.pageRanges
                guard !partes.isEmpty else { continue }
                if partes.count == 1 { inteiros += 1; continue }
                partidos += 1

                // Onde parte, o buraco tem de ser conteúdo retirado — não normalização.
                for (a, b) in zip(partes, partes.dropFirst()) {
                    let buraco = b.location - NSMaxRange(a)
                    if buraco < 3, exemplos.count < 4 {
                        exemplos.append("\(arquivo.lastPathComponent) #\(seg.id): buraco de \(buraco)")
                    }
                }
            }
        }

        #expect(inteiros > 100, "poucos trechos analisados: \(inteiros)")
        #expect(exemplos.isEmpty, "\(exemplos.count) partições por normalização: \(exemplos)")

        // Partir é a exceção, e vem só de equação retirada do meio do texto. Medido neste
        // corpus de artigos de engenharia: 8,0%. O limite deixa folga para variação entre
        // documentos, mas pega de volta o dia em que a normalização voltar a partir.
        let taxa = Double(partidos) / Double(max(inteiros + partidos, 1))
        #expect(taxa < 0.12, "\(partidos) trechos partidos de \(inteiros + partidos)")
    }

    @Test("parágrafo longo não é cortado deixando a cauda solta")
    func caudaDeParagrafoNaoViraTrecho() throws {
        let arquivos = SamplePDFs.files
        let segmenter = DocumentSegmenter()
        var cortados: [String] = []
        var pares = 0

        for arquivo in arquivos.prefix(12) {
            guard let doc = PDFDocument(url: arquivo) else { continue }
            let segs = segmenter.segments(of: doc, documentLanguage: "en")

            for (anterior, atual) in zip(segs, segs.dropFirst()) {
                guard anterior.pageIndex == atual.pageIndex else { continue }

                let fim = anterior.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let inicio = atual.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // texto corrido de verdade, não linha de sumário nem célula de tabela
                guard fim.count > 200, !fim.contains("...."), !inicio.contains("....") else { continue }
                pares += 1

                let fraseAberta = ![".", "!", "?", "…", ":", ";"].contains(String(fim.suffix(1)))
                guard fraseAberta, inicio.first?.isLowercase == true else { continue }
                cortados.append("...\(fim.suffix(24)) || \(inicio.prefix(24))...")
            }
        }

        #expect(pares > 20, "poucos pares de texto corrido: \(pares)")

        let amostra = cortados.prefix(6).joined(separator: " ## ")
        #expect(cortados.isEmpty, "\(cortados.count)/\(pares) cortados: \(amostra)")
    }

    /// O realce do trecho tem de cobrir exatamente o que a voz lê. Relatado em uso: o
    /// destaque "pega um pouco do trecho seguinte" e às vezes "começa um pouco depois".
    /// Medido antes da correção: 144 exatos de 360; depois, 312.
    @Test("realce do trecho coincide com o texto lido")
    func realceDoTrechoCoincide() throws {
        let arquivos = SamplePDFs.files
        let segmenter = DocumentSegmenter()

        func limpo(_ s: String) -> String {
            s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }

        var exatos = 0, total = 0, comecamCerto = 0
        var desvios: [String] = []

        // Documento inteiro, não os primeiros trechos: o desvio entre os dois sistemas de
        // índice do PDFKit cresce ao longo da página, então amostrar só o começo esconde
        // exatamente os casos que falham. Relatado em uso num parágrafo da página 3, cujo
        // realce começava na equação anterior.
        for arquivo in arquivos.prefix(6) {
            guard let doc = PDFDocument(url: arquivo) else { continue }
            for seg in segmenter.segments(of: doc, documentLanguage: "en") {
                guard let page = doc.page(at: seg.pageIndex),
                      let pageText = page.string as NSString? else { continue }

                for pedaco in seg.pageRanges where NSMaxRange(pedaco) <= pageText.length {
                    guard let realcado = PageTextLocator.selection(on: page, matching: pedaco,
                                                                   in: pageText)?.string
                    else { total += 1; continue }

                    total += 1
                    let esperado = limpo(pageText.substring(with: pedaco))
                    let obtido = limpo(realcado)

                    if obtido == esperado { exatos += 1 }
                    if obtido.hasPrefix(String(esperado.prefix(24))) { comecamCerto += 1 }
                    else if desvios.count < 4 {
                        desvios.append("\(arquivo.lastPathComponent) #\(seg.id) esp='\(esperado.prefix(24))' obt='\(obtido.prefix(24))'")
                    }
                }
            }
        }

        #expect(total > 500, "poucas amostras: \(total)")
        let amostra = desvios.joined(separator: " ## ")

        // Onde o realce COMEÇA é o que o uso reclamou: ele abria na equação anterior, que
        // nem é lida. Medido depois da correção de desvio: 97%.
        let taxaComeco = Double(comecamCerto) / Double(max(total, 1))
        #expect(taxaComeco > 0.95,
                "só \(comecamCerto)/\(total) realces começam certo: \(amostra)")

        // Bater por inteiro é mais exigente, e o que sobra é sobra de cauda e texto de
        // figura — outro problema, ainda aberto. Medido: 90%, contra 83% antes.
        let taxaExata = Double(exatos) / Double(max(total, 1))
        #expect(taxaExata > 0.88, "só \(exatos)/\(total) realces exatos")
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
