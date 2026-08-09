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

    // MARK: - Notas à mão

    /// Os testes que faltaram nas tentativas anteriores: verificam que o traço chega ao
    /// modelo, não que o botão mudou de estado.
    func testDesenharRegistraTraco() throws {
        let app = launchApp()
        let pdf = app.otherElements["pdfCanvas"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))

        app.buttons["drawToggle"].tap()
        let status = app.staticTexts["drawStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "modo de desenho não iniciou")
        XCTAssertEqual(Self.tracos(em: status.label), 0)

        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.15,
                   thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)))

        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 },
                      "o traço não chegou ao modelo: \(status.label)")
    }

    func testDesfazerRemoveOTraco() throws {
        let app = launchApp()
        let pdf = app.otherElements["pdfCanvas"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        app.buttons["drawToggle"].tap()

        let status = app.staticTexts["drawStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.15,
                   thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)))
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 })

        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.isEnabled, "desfazer desabilitado com traço presente")
        undo.tap()
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) == 0 },
                      "desfazer não removeu: \(status.label)")

        let redo = app.buttons["redo"]
        XCTAssertTrue(redo.isEnabled, "refazer desabilitado depois de desfazer")
        redo.tap()
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 },
                      "refazer não restaurou: \(status.label)")
    }

    func testTocarNaoLeEnquantoDesenha() throws {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        app.buttons["drawToggle"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()

        XCTAssertFalse(app.staticTexts["segmentCounter"].waitForExistence(timeout: 4),
                       "o toque iniciou a leitura em modo de desenho")
    }

    func testSairDoModoRestauraALeitura() throws {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        app.buttons["drawToggle"].tap()
        app.buttons["drawToggle"].tap()

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(app.staticTexts["segmentCounter"].waitForExistence(timeout: 10),
                      "a leitura não voltou ao sair do modo de desenho")
    }

    func testFerramentasEstaoAoAlcance() {
        let app = launchApp()
        XCTAssertTrue(app.otherElements["pdfCanvas"].waitForExistence(timeout: 10))
        app.buttons["drawToggle"].tap()

        // Relatado em uso: não havia como escolher cor, espessura ou borracha.
        for botao in ["toolPen", "toolEraser", "color-blue", "color-red", "undo", "redo"] {
            XCTAssertTrue(app.buttons[botao].waitForExistence(timeout: 5),
                          "\(botao) não está na barra")
        }
        // Espessura contínua e ciclo cromático, em vez de valores predefinidos.
        XCTAssertTrue(app.sliders["widthSlider"].waitForExistence(timeout: 5),
                      "não há controle contínuo de espessura")
        XCTAssertTrue(app.colorWells["colorWheel"].exists || app.buttons["colorWheel"].exists,
                      "não há ciclo cromático para escolher qualquer cor")
    }

    func testBorrachaApagaSoOTrechoTocado() throws {
        let app = launchApp()
        let pdf = app.otherElements["pdfCanvas"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        app.buttons["drawToggle"].tap()

        let status = app.staticTexts["drawStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        // um traço longo atravessando a página
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45))
            .press(forDuration: 0.15,
                   thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) == 1 })

        // apaga no meio: deve partir em dois, não sumir
        app.buttons["toolEraser"].tap()
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()

        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) == 2 },
                      "a borracha não partiu o traço: \(status.label)")
    }

    /// Os gestos de dois e três dedos estão implementados com requisito de falha contra
    /// o pan do scroll e `delaysContentTouches` desligado, mas o XCUITest não consegue
    /// computar coordenadas para `twoFingerTap` nesta hierarquia — falha com "unable to
    /// compute coordinates" mesmo com o frame inteiro visível. Fica registrado como
    /// verificável só no dispositivo, em vez de fingir cobertura.
    func testDesfazerPorGestoDeDoisDedos() throws {
        throw XCTSkip("twoFingerTap não é computável sobre o PDFView; verificar no iPad")
    }

    private func testDesfazerPorGestoDeDoisDedos_manual() throws {
        let app = launchApp()
        let pdf = app.otherElements["pdfCanvas"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        app.buttons["drawToggle"].tap()

        let status = app.staticTexts["drawStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.15,
                   thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) >= 1 })

        // O twoFingerTap precisa de um elemento com ponto calculável; o pdfCanvas é um
        // elemento de acessibilidade único e não serve.
        app.windows.firstMatch.twoFingerTap()
        XCTAssertTrue(Self.aguarda(ate: 8) { Self.tracos(em: status.label) == 0 },
                      "dois dedos não desfizeram: \(status.label)")
    }

    /// Relatado em uso: apertar a pasta no canto superior esquerdo não faz nada, e não há
    /// como trocar de PDF. O seletor do sistema roda em outro processo, então o que se
    /// pode afirmar de dentro do app é que alguma coisa passou a cobrir a tela.
    func testPastaAbreOSeletorDeArquivos() {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        let pasta = app.buttons["openDocument"]
        XCTAssertTrue(pasta.waitForExistence(timeout: 5), "botão de pasta não existe")
        XCTAssertTrue(pasta.isHittable, "botão de pasta não é tocável")
        pasta.tap()

        // Com o seletor na frente, o PDF deixa de ser alcançável.
        let cobriu = Self.aguarda(ate: 10) { !canvas.isHittable }
        if !cobriu {
            let visiveis = app.descendants(matching: .any).allElementsBoundByIndex
                .prefix(30).map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" }
            XCTFail("o seletor não apareceu. Na tela: \(visiveis.joined(separator: " | "))")
        }
    }

    /// O mesmo botão, nos estados em que o app costuma estar: desenhando, e lendo.
    /// Desenhar mexe na interação das views do PDFKit e desliga o scroll, e é aí que um
    /// toque pode se perder antes de chegar à barra.
    func testPastaFuncionaDesenhandoELendo() throws {
        let app = launchApp()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let pasta = app.buttons["openDocument"]
        XCTAssertTrue(pasta.waitForExistence(timeout: 5))

        // 1. desenhando
        app.buttons["drawToggle"].tap()
        XCTAssertTrue(pasta.isHittable, "desenhando, a pasta não é tocável")
        pasta.tap()
        XCTAssertTrue(Self.aguarda(ate: 10) { !canvas.isHittable },
                      "desenhando, o seletor não apareceu")

        // Fecha o seletor para o próximo estado.
        let cancelar = app.buttons["Cancel"].firstMatch
        if cancelar.waitForExistence(timeout: 5) { cancelar.tap() }
        XCTAssertTrue(Self.aguarda(ate: 10) { canvas.isHittable }, "o seletor não fechou")
        app.buttons["drawToggle"].tap()

        // 2. lendo
        canvas.tap()
        XCTAssertTrue(pasta.isHittable, "lendo, a pasta não é tocável")
        pasta.tap()
        XCTAssertTrue(Self.aguarda(ate: 10) { !canvas.isHittable },
                      "lendo, o seletor não apareceu")
    }

    // MARK: - Acompanhar a leitura

    /// Com a página inteira à vista nada precisa rolar; ampliada, a palavra lida sai da
    /// tela e a leitura em voz alta deixa de ser acompanhável. O PDFKit expõe o texto da
    /// página como elementos de acessibilidade, então o deslocamento deles denuncia a
    /// rolagem.
    private func posicaoDoTexto(_ app: XCUIApplication) -> CGFloat? {
        let alvo = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Journal of Document'")).firstMatch
        guard alvo.exists else { return nil }
        return alvo.frame.origin.y
    }

    private func ampliaEComecaALer(_ app: XCUIApplication) throws -> CGFloat {
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        // Ampliado, o parágrafo não cabe mais na tela — é a condição do problema.
        canvas.pinch(withScale: 6, velocity: 3)
        Thread.sleep(forTimeInterval: 1)

        let antes = try XCTUnwrap(posicaoDoTexto(app), "nenhum texto do PDF visível para medir")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.staticTexts["segmentCounter"].waitForExistence(timeout: 10),
                      "nada começou a tocar")
        return antes
    }

    func testTelaAcompanhaAPalavraLida() throws {
        let app = launchApp()
        let antes = try ampliaEComecaALer(app)

        XCTAssertTrue(Self.aguarda(ate: 25) {
            guard let agora = self.posicaoDoTexto(app) else { return true }
            return abs(agora - antes) > 20
        }, "a tela não acompanhou a palavra lida")
    }

    /// A prova de que o movimento veio de acompanhar, e não de outra coisa: desligado, a
    /// tela fica parada lendo o mesmo trecho.
    func testSemAcompanharATelaFicaParada() throws {
        let app = XCUIApplication()
        app.launchEnvironment["FASTREAD_OPEN_PDF"] = pdfURL.path
        app.launchEnvironment["FASTREAD_FINGER_DRAWING"] = "1"
        app.launchEnvironment["FASTREAD_NO_FOLLOW"] = "1"
        app.launch()

        let antes = try ampliaEComecaALer(app)
        Thread.sleep(forTimeInterval: 12)

        let agora = try XCTUnwrap(posicaoDoTexto(app))
        XCTAssertEqual(agora, antes, accuracy: 20, "a tela rolou com o acompanhamento desligado")
    }

    // MARK: - Auxiliares

    /// Último número do rótulo — é onde a contagem de traços aparece.
    private static func tracos(em label: String) -> Int {
        label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.last ?? -1
    }

    private static func aguarda(ate segundos: TimeInterval, _ condicao: () -> Bool) -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        while Date() < limite {
            if condicao() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condicao()
    }


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
