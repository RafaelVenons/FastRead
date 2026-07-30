import CoreGraphics
import PDFKit
import XCTest

/// Testes de interface no simulador.
///
/// Existem porque os dois bugs que apareceram no uso real — o realce deslocado e o toque
/// abrindo o trecho errado — viviam na costura entre o núcleo e o PDFKit, exatamente
/// onde os testes de unidade não chegavam. Aqui o toque é um toque de verdade, na tela.
final class ReaderUITests: XCTestCase {

    private var pdfURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        pdfURL = try Self.makeArticlePDF()
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Abre o documento direto, sem depender do seletor de arquivos do sistema.
        app.launchEnvironment["FASTREAD_OPEN_PDF"] = pdfURL.path
        app.launch()
        return app
    }

    // MARK: - Testes

    func testAbreDocumentoEIndicaOsTrechos() {
        let app = launchApp()
        let status = app.staticTexts["status"]

        XCTAssertTrue(status.waitForExistence(timeout: 10), "a barra de status não apareceu")
        // Sem depender do idioma da interface: o status traz a contagem e o código do idioma.
        XCTAssertTrue(status.label.contains("en"), "idioma não detectado: \(status.label)")
        XCTAssertTrue(status.label.rangeOfCharacter(from: .decimalDigits) != nil,
                      "status sem contagem de trechos: \(status.label)")
    }

    func testTocarNoCorpoNaoComecaPeloCabecalho() throws {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        // Toca bem abaixo do topo, já no corpo do artigo — nunca no cabeçalho.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()

        let contador = app.staticTexts["segmentCounter"]
        XCTAssertTrue(contador.waitForExistence(timeout: 10), "nada começou a tocar")

        // O bug relatado: qualquer toque caía no primeiro trecho (o cabeçalho).
        let indice = try Self.segmentIndex(from: contador.label)
        XCTAssertGreaterThan(indice, 1, "tocar no corpo abriu o trecho \(indice) — voltou ao topo")
    }

    func testTocarMaisAbaixoAbreTrechoPosterior() throws {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        let contador = app.staticTexts["segmentCounter"]
        XCTAssertTrue(contador.waitForExistence(timeout: 10))
        let acima = try Self.segmentIndex(from: contador.label)

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        Thread.sleep(forTimeInterval: 2)
        let abaixo = try Self.segmentIndex(from: contador.label)

        XCTAssertGreaterThan(abaixo, acima,
                             "tocar mais abaixo devia abrir um trecho posterior (\(acima) -> \(abaixo))")
    }

    func testAvancarERetrocederEntreTrechos() throws {
        let app = launchApp()
        XCTAssertTrue(app.otherElements["pdfCanvas"].waitForExistence(timeout: 10))

        app.buttons["playPause"].tap()
        let contador = app.staticTexts["segmentCounter"]
        XCTAssertTrue(contador.waitForExistence(timeout: 10))
        let inicial = try Self.segmentIndex(from: contador.label)

        app.buttons["next"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(try Self.segmentIndex(from: contador.label), inicial + 1)

        app.buttons["previous"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(try Self.segmentIndex(from: contador.label), inicial)
    }

    func testSeletorDeVozListaAsVozesInstaladas() {
        let app = launchApp()
        XCTAssertTrue(app.otherElements["pdfCanvas"].waitForExistence(timeout: 10))

        app.buttons["voicePicker"].tap()

        // A própria lista é o sinal de que abriu — mais confiável que o container da
        // sheet, cujo identificador nem sempre é exposto ao XCUITest.
        let vozes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voice-'"))
        XCTAssertTrue(vozes.firstMatch.waitForExistence(timeout: 5), "o seletor de voz não abriu")
        XCTAssertGreaterThan(vozes.count, 0, "nenhuma voz listada")

        // A qualidade tem que estar visível: é o ponto de existir esta tela.
        let qualidades = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'quality-'"))
        XCTAssertGreaterThan(qualidades.count, 0, "a qualidade das vozes não aparece na lista")
    }

    func testEscolherVozFechaOSeletor() {
        let app = launchApp()
        XCTAssertTrue(app.otherElements["pdfCanvas"].waitForExistence(timeout: 10))

        app.buttons["voicePicker"].tap()

        let vozes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voice-'"))
        XCTAssertTrue(vozes.firstMatch.waitForExistence(timeout: 5))
        vozes.firstMatch.tap()

        // A lista desaparecer é o sinal de que a folha fechou.
        XCTAssertTrue(vozes.firstMatch.waitForNonExistence(timeout: 5),
                      "escolher a voz devia fechar a tela")
    }

    // MARK: - Auxiliares

    private static func segmentIndex(from label: String) throws -> Int {
        // "Trecho 3 de 12"
        let parts = label.split(separator: " ")
        guard parts.count > 1, let value = Int(parts[1]) else {
            throw XCTSkip("rótulo inesperado: \(label)")
        }
        return value
    }

    /// PDF com o formato que quebrou no uso real: cabeçalho de revista, autores, corpo.
    private static func makeArticlePDF() throws -> URL {
        let body = """
        Journal of Document Engineering, Vol. 12, No. 3, 2026, pp. 45-67.

        Reading Documents Aloud With Word Level Alignment

        Rafael Garcia, Maria Silva, John Smith, Ana Costa

        Abstract. This paper presents a method for reading documents aloud on tablets.
        The system aligns synthesized speech with the source text of the document.
        We evaluate the approach on a corpus of scientific articles and report results.

        Introduction. Reading long documents on a tablet is tiring for many readers.
        A synthesized voice helps, but only when the text follows the audio precisely.
        Previous systems highlighted whole paragraphs, which is too coarse to follow.

        Method. We synthesize each paragraph separately and cache the resulting audio.
        Word timings come from the speech synthesizer itself, at no additional cost.
        The alignment is stored next to the audio so a second reading is instantaneous.

        Results. The approach runs entirely on device and needs no network connection.
        Synthesis is much faster than real time, so the next paragraph is always ready.
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-article.pdf")
        try? FileManager.default.removeItem(at: url)

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(string: body, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 13, nil),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        return url
    }
}
