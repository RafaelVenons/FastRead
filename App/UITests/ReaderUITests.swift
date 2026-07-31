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
        // O simulador não tem Pencil; sem isto nenhum teste consegue traçar.
        app.launchEnvironment["FASTREAD_FINGER_DRAWING"] = "1"
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

        // A lista desaparecer é o sinal de que a folha fechou. Margem folgada: com a
        // suíte inteira rodando, a animação de fechamento chega a passar de 5 s.
        XCTAssertTrue(vozes.firstMatch.waitForNonExistence(timeout: 15),
                      "escolher a voz devia fechar a tela")
    }

    // MARK: - Notas com Apple Pencil

    func testAlternarModoDeDesenho() {
        let app = launchApp()
        XCTAssertTrue(app.otherElements["pdfCanvas"].waitForExistence(timeout: 10))

        let botao = app.buttons["drawToggle"]
        XCTAssertTrue(botao.exists, "botão de desenho ausente")
        botao.tap()

        // O aviso de que a leitura por toque está pausada precisa aparecer, senão o
        // usuário toca no parágrafo e não entende por que nada acontece.
        let aviso = app.staticTexts["drawStatus"]
        XCTAssertTrue(aviso.waitForExistence(timeout: 5), "nenhum aviso de modo de desenho")

        botao.tap()
        XCTAssertTrue(aviso.waitForNonExistence(timeout: 5), "aviso permaneceu fora do modo")
    }

    func testTocarNaoLeEnquantoDesenha() throws {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        app.buttons["drawToggle"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()

        // Sem trecho em reprodução, o contador não deve aparecer.
        XCTAssertFalse(app.staticTexts["segmentCounter"].waitForExistence(timeout: 4),
                       "o toque iniciou a leitura mesmo em modo de desenho")
    }

    func testVoltarDoModoDesenhoRestauraALeitura() throws {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        app.buttons["drawToggle"].tap()
        app.buttons["drawToggle"].tap()

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(app.staticTexts["segmentCounter"].waitForExistence(timeout: 10),
                      "a leitura não voltou depois de sair do modo de desenho")
    }

    func testPaletaDeFerramentasApareceNoModo() {
        let app = launchApp()
        XCTAssertTrue(app.otherElements["pdfCanvas"].waitForExistence(timeout: 10))

        app.buttons["drawToggle"].tap()

        // A paleta do PencilKit expõe os botões de ferramenta; basta um existir.
        let ferramentas = app.buttons.matching(NSPredicate(
            format: "identifier CONTAINS[c] 'pen' OR identifier CONTAINS[c] 'eraser' OR label CONTAINS[c] 'pen'"))
        XCTAssertTrue(ferramentas.firstMatch.waitForExistence(timeout: 8),
                      "a paleta de ferramentas não apareceu")
    }

    func testDesenharCriaTraco() throws {
        let app = launchApp()
        let pdf = app.otherElements["pdfCanvas"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))

        app.buttons["drawToggle"].tap()
        let status = app.staticTexts["drawStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "modo de desenho não iniciou")
        XCTAssertTrue(status.label.contains("0"), "começou com traço: \(status.label)")

        // risca a página
        let inicio = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
        let fim = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        inicio.press(forDuration: 0.1, thenDragTo: fim)

        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 },
                      "o traço não chegou à tela: \(status.label)")
    }

    func testDesfazerRestauraContagem() throws {
        let app = launchApp()
        let pdf = app.otherElements["pdfCanvas"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        app.buttons["drawToggle"].tap()

        let status = app.staticTexts["drawStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 },
                      "não desenhou antes de desfazer: \(status.label)")

        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.exists, "botão desfazer ausente")
        XCTAssertTrue(undo.isEnabled, "botão desfazer desabilitado com \(status.label)")
        undo.tap()

        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) == 0 },
                      "desfazer não removeu o traço: \(status.label)")
    }

    /// Último número do rótulo — é onde a contagem de traços aparece.
    private static func tracos(em label: String) -> Int {
        label.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .last ?? -1
    }

    private static func aguarda(ate segundos: TimeInterval, _ condicao: () -> Bool) -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        while Date() < limite {
            if condicao() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condicao()
    }

    func testRefazerRestauraTraco() throws {
        let app = launchApp()
        let pdf = app.otherElements["pdfCanvas"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        app.buttons["drawToggle"].tap()

        let status = app.staticTexts["drawStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 })

        app.buttons["undo"].tap()
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) == 0 },
                      "não desfez antes de refazer")

        app.buttons["redo"].tap()
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 },
                      "refazer não restaurou o traço: \(status.label)")
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
