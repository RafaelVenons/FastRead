import FastReadCore
import OSLog
import PDFKit
import PencilKit
import UIKit

private let log = Logger(subsystem: "com.rafaelg.FastRead", category: "ink")

/// Coloca uma tela de desenho sobre cada página do PDF.
///
/// Usa `PDFPageOverlayViewProvider` em vez de uma view sobreposta ao `PDFView`: assim o
/// PDFKit posiciona e escala a tela junto com a página, e o traço acompanha zoom e
/// rolagem sem nenhum cálculo de coordenadas — que é onde a integração PencilKit+PDFKit
/// costuma perder resolução ao ampliar.
///
/// `@preconcurrency` nas conformances: PDFKit e PencilKit entregam esses callbacks na
/// main thread, mas os protocolos são anteriores ao isolamento e não declaram isso.
@MainActor
final class AnnotationLayer: NSObject, @preconcurrency PDFPageOverlayViewProvider,
                             @preconcurrency PKCanvasViewDelegate,
                             @preconcurrency UIGestureRecognizerDelegate {

    private let store: AnnotationStore
    private var document: DocumentIdentifier?
    private var canvases: [Int: PKCanvasView] = [:]
    private var pages: [Int: PDFPage] = [:]
    private weak var pdfView: PDFView?

    /// Instância própria e retida. `PKToolPicker.shared(for:)` está obsoleto desde o
    /// iOS 14, e uma paleta não retida some assim que o escopo termina — era por isso
    /// que ela não aparecia.
    private let toolPicker = PKToolPicker()

    /// A tela existe desde que a página é exibida; só a interação alterna.
    ///
    /// Criá-la sob demanda não funciona: o PDFKit consulta o provider ao dispor as
    /// páginas e não volta a consultá-lo depois, então entrar no modo de desenho não
    /// produzia tela alguma e a Pencil caía no PDFView, que a tratava como rolagem.
    var isDrawingEnabled = false {
        didSet {
            guard isDrawingEnabled != oldValue else { return }
            canvases.values.forEach { applyMode(to: $0) }
            setScrollEnabled(!isDrawingEnabled)
            updateToolPicker()
        }
    }

    /// O `PDFView` é um scroll view, e o pan dele fica com o arrasto antes de a tela de
    /// desenho vê-lo — era por isso que a Pencil rolava a página em vez de traçar.
    /// Durante o desenho a rolagem sai de cena; para navegar, basta sair do modo.
    private func setScrollEnabled(_ enabled: Bool) {
        guard let pdfView else { return }
        for case let scroll as UIScrollView in pdfView.subviews {
            scroll.isScrollEnabled = enabled
            scroll.panGestureRecognizer.isEnabled = enabled
        }
    }

    var onChange: (() -> Void)?

    /// Espessura do traço convertido. Trocar reescreve as anotações já existentes, para
    /// o documento inteiro ficar consistente em vez de misturar calibrações.
    var calibration: InkGeometry.Calibration = .medium {
        didSet {
            guard calibration != oldValue else { return }
            for (index, page) in pages {
                InkAnnotator.replaceAnnotations(on: page,
                                                with: storedDrawings[index] ?? PKDrawing(),
                                                calibration: calibration)
            }
            onChange?()
        }
    }

    /// O traço original de cada página. Guardado porque a anotação do PDF é só a
    /// representação exibida — reconvertê-la de volta perderia pressão e tipo de caneta.
    private var storedDrawings: [Int: PKDrawing] = [:]
    private var pendingCommits: [Int: DispatchWorkItem] = [:]

    static var allowsFingerDrawing: Bool {
        ProcessInfo.processInfo.environment["FASTREAD_FINGER_DRAWING"] == "1"
    }

    /// Quantos traços a página visível tem. Existe para o teste de UI poder afirmar que
    /// o desenho chegou à tela, em vez de só verificar que o botão mudou de estado.
    var strokeCountOnVisiblePage: Int {
        guard let tag = visibleCanvas()?.tag else { return 0 }
        return (storedDrawings[tag]?.strokes.count ?? 0) + (canvases[tag]?.drawing.strokes.count ?? 0)
    }

    /// Escala efetiva de rasterização, para o modo de diagnóstico.
    var resolutionDescription: String {
        guard let canvas = visibleCanvas() else { return "sem canvas" }
        let vetorizadas = pages[canvas.tag]?.annotations.filter { $0.userName == InkAnnotator.marker }.count ?? 0
        return "vetor \(vetorizadas) · bitmap \(canvas.drawing.strokes.count) · " + geometryDescription(canvas)
    }

    private func geometryDescription(_ canvas: PKCanvasView) -> String {
        let pdfScale = pdfView?.scaleFactor ?? 0
        let screen = canvas.window?.screen.scale ?? 0
        return String(format: "pdf %.2f · tela %.0f · canvas %.1f · bounds %.0f",
                      pdfScale, screen, canvas.contentScaleFactor, canvas.bounds.width)
    }


    init(store: AnnotationStore) {
        self.store = store
    }

    func attach(to pdfView: PDFView, document: DocumentIdentifier?) {
        self.pdfView = pdfView
        self.document = document
        canvases.removeAll()
        pages.removeAll()

        // Ampliar muda quanto de tela cada ponto da página ocupa; sem reagir, o traço
        // feito com zoom fica na resolução de antes.
        NotificationCenter.default.removeObserver(self, name: .PDFViewScaleChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged),
                                               name: .PDFViewScaleChanged, object: pdfView)
        pdfView.pageOverlayViewProvider = self
        installGestures(on: pdfView)
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let index = page.document?.index(for: page) else { return nil }
        if let existing = canvases[index] { return existing }

        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.tag = index
        canvas.accessibilityIdentifier = "annotationCanvas"
        canvas.isAccessibilityElement = true
        // Desenhar é só com a Pencil: o dedo continua rolando, dando zoom e — fora do
        // modo — tocando num parágrafo para ouvi-lo. O simulador não tem Pencil, então os
        // testes de UI liberam o dedo por variável de ambiente.
        canvas.drawingPolicy = Self.allowsFingerDrawing ? .anyInput : .pencilOnly
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.isScrollEnabled = false
        applyResolution(to: canvas)
        applyMode(to: canvas)

        if let document, let data = store.load(document: document, page: index),
           let drawing = try? PKDrawing(data: data) {
            // O traço salvo vira anotação do PDF, que é vetorial e não borra ao ampliar.
            // A tela fica vazia: ela serve para desenhar, não para exibir o que já existe.
            InkAnnotator.replaceAnnotations(on: page, with: drawing, calibration: calibration)
            storedDrawings[index] = drawing
        }

        canvases[index] = canvas
        pages[index] = page
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        applyResolution(to: canvas)
        guard isDrawingEnabled else { return }
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        persist(canvas)
    }

    @objc private func scaleChanged() {
        canvases.values.forEach { applyResolution(to: $0) }
    }

    /// Densidade de rasterização da tela, acompanhando o zoom do PDF.
    private func applyResolution(to canvas: PKCanvasView) {
        let pdfScale = pdfView?.scaleFactor ?? 1
        let screen = canvas.window?.screen.scale ?? UIScreen.main.scale
        let scale = DrawingResolution.contentScale(pdfScale: pdfScale, screenScale: screen)

        guard abs(canvas.contentScaleFactor - scale) > 0.01 else { return }
        canvas.contentScaleFactor = scale
        canvas.layer.contentsScale = scale
        canvas.drawingGestureRecognizer.isEnabled = true
        canvas.setNeedsDisplay()
    }

    private func applyMode(to canvas: PKCanvasView) {
        canvas.isUserInteractionEnabled = isDrawingEnabled
        // A page view do PDFKit vem com interação desligada; sem religá-la o toque nem
        // chega ao canvas.
        canvas.superview?.isUserInteractionEnabled = isDrawingEnabled
    }

    // MARK: - Paleta de ferramentas

    private func updateToolPicker() {
        guard let canvas = visibleCanvas() else { return }

        if isDrawingEnabled {
            toolPicker.addObserver(canvas)
            toolPicker.setVisible(true, forFirstResponder: canvas)
            let became = canvas.becomeFirstResponder()
        } else {
            canvases.values.forEach {
                toolPicker.setVisible(false, forFirstResponder: $0)
                $0.resignFirstResponder()
            }
        }
    }

    private func visibleCanvas() -> PKCanvasView? {
        guard let pdfView, let page = pdfView.currentPage,
              let index = page.document?.index(for: page) else { return canvases.values.first }
        return canvases[index] ?? canvases.values.first
    }

    // MARK: - Gestos de desfazer e refazer

    private var gesturesInstalled = false

    /// Dois dedos desfaz, três dedos refaz — como no Procreate.
    ///
    /// Ficam no `PDFView`, não na tela de desenho: o PencilKit consome os toques antes e
    /// o gesto nunca era reconhecido — verificado, o handler não rodava uma vez sequer.
    private func installGestures(on view: UIView) {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        let undo = UITapGestureRecognizer(target: self, action: #selector(handleUndo))
        undo.numberOfTouchesRequired = 2
        undo.numberOfTapsRequired = 1

        let redo = UITapGestureRecognizer(target: self, action: #selector(handleRedo))
        redo.numberOfTouchesRequired = 3
        redo.numberOfTapsRequired = 1

        // Sem isto, o toque de dois dedos viraria desfazer E o de três também, porque o
        // de dois reconhece antes.
        undo.require(toFail: redo)

        [undo, redo].forEach {
            $0.cancelsTouchesInView = false
            $0.delegate = self
            view.addGestureRecognizer($0)
        }
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Desfazer e refazer são de dois e três dedos; um dedo (ou a Pencil) é traço e não
    /// deve ser interceptado.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldReceive touch: UITouch) -> Bool {
        return touch.type != .pencil
    }

    /// Pilha própria em vez do `undoManager` da view: dentro do PDFView o gerenciador que
    /// chega pela cadeia de responders não recebe os traços do PencilKit, e desfazer não
    /// fazia nada.
    private var redoStack: [Int: [PKStroke]] = [:]

    @objc func handleUndo() {
        guard isDrawingEnabled, let canvas = visibleCanvas() else { return }
        var strokes = storedDrawings[canvas.tag]?.strokes ?? []
        guard let removido = strokes.popLast() else { return }

        redoStack[canvas.tag, default: []].append(removido)
        applyStored(strokes, page: canvas.tag)
        feedback(.light)
    }

    @objc func handleRedo() {
        guard isDrawingEnabled, let canvas = visibleCanvas(),
              let restaurado = redoStack[canvas.tag]?.popLast() else { return }

        applyStored((storedDrawings[canvas.tag]?.strokes ?? []) + [restaurado], page: canvas.tag)
        feedback(.rigid)
    }

    /// Reescreve o traço guardado e as anotações da página a partir dele.
    private func applyStored(_ strokes: [PKStroke], page index: Int) {
        let drawing = PKDrawing(strokes: strokes)
        storedDrawings[index] = drawing
        if let page = pages[index] {
            InkAnnotator.replaceAnnotations(on: page, with: drawing, calibration: calibration)
        }
        persistStored(page: index)
        onChange?()
    }

    var canUndo: Bool { !(storedDrawings[visibleCanvas()?.tag ?? -1]?.strokes.isEmpty ?? true) }
    var canRedo: Bool { !(redoStack[visibleCanvas()?.tag ?? -1]?.isEmpty ?? true) }

    /// Um toque que desfaz sem retorno tátil parece que não funcionou.
    private func feedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onChange?()
        scheduleCommit(for: canvasView)
    }

    /// `canvasViewDidEndUsingTool` não dispara nesta montagem — verificado por log, nem
    /// uma vez. Sem gatilho de fim de traço, a conversão para anotação nunca acontecia e
    /// o desenho ficava só no bitmap da tela, que é o que borra ao ampliar.
    ///
    /// O adiamento espera a caneta parar: converter a cada ponto faria o traço piscar
    /// entre a tela e a anotação enquanto está sendo desenhado.
    private func scheduleCommit(for canvas: PKCanvasView) {
        pendingCommits[canvas.tag]?.cancel()

        let work = DispatchWorkItem { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.commit(canvas)
        }
        pendingCommits[canvas.tag] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// A transferência acontece ao levantar a caneta, não a cada ponto: converter durante
    /// o traço faria o desenho piscar entre a tela e a anotação.
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        commit(canvasView)
    }

    private func commit(_ canvas: PKCanvasView) {
        pendingCommits[canvas.tag] = nil
        guard let page = pages[canvas.tag], !canvas.drawing.strokes.isEmpty else { return }

        let combined = PKDrawing(strokes: (storedDrawings[canvas.tag]?.strokes ?? []) + canvas.drawing.strokes)
        storedDrawings[canvas.tag] = combined
        InkAnnotator.replaceAnnotations(on: page, with: combined, calibration: calibration)

        canvas.drawing = PKDrawing()   // o traço agora vive no PDF
        persistStored(page: canvas.tag)
        onChange?()
    }

    private func persistStored(page index: Int) {
        guard let document else { return }
        let drawing = storedDrawings[index]
        let data = (drawing?.strokes.isEmpty ?? true) ? Data() : drawing!.dataRepresentation()
        try? store.save(data, document: document, page: index)
    }


    private func persist(_ canvas: PKCanvasView) {
        persistStored(page: canvas.tag)
    }

    // MARK: - Edição

    func clearCurrentPage() {
        guard let canvas = visibleCanvas() else { return }
        canvas.drawing = PKDrawing()
        storedDrawings[canvas.tag] = nil
        redoStack[canvas.tag] = nil
        if let page = pages[canvas.tag] {
            InkAnnotator.replaceAnnotations(on: page, with: PKDrawing(), calibration: calibration)
        }
        persistStored(page: canvas.tag)
        onChange?()
    }

    func clearDocument() {
        canvases.values.forEach { $0.drawing = PKDrawing() }
        storedDrawings.removeAll()
        redoStack.removeAll()
        pages.forEach { InkAnnotator.replaceAnnotations(on: $0.value, with: PKDrawing(), calibration: calibration) }
        if let document { try? store.removeAll(document: document) }
        onChange?()
    }

    var annotatedPageCount: Int {
        document.map { store.annotatedPages(document: $0).count } ?? 0
    }
}
