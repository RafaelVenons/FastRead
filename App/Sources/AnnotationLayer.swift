import FastReadCore
import PDFKit
import PencilKit
import UIKit

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

    static var allowsFingerDrawing: Bool {
        ProcessInfo.processInfo.environment["FASTREAD_FINGER_DRAWING"] == "1"
    }

    /// Quantos traços a página visível tem. Existe para o teste de UI poder afirmar que
    /// o desenho chegou à tela, em vez de só verificar que o botão mudou de estado.
    var strokeCountOnVisiblePage: Int {
        visibleCanvas()?.drawing.strokes.count ?? 0
    }

    var canUndo: Bool { (visibleCanvas()?.drawing.strokes.count ?? 0) > 0 }
    var canRedo: Bool { !(redoStack[visibleCanvas()?.tag ?? -1]?.isEmpty ?? true) }

    init(store: AnnotationStore) {
        self.store = store
    }

    func attach(to pdfView: PDFView, document: DocumentIdentifier?) {
        self.pdfView = pdfView
        self.document = document
        canvases.removeAll()

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
            canvas.drawing = drawing
        }

        canvases[index] = canvas
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
        var strokes = canvas.drawing.strokes
        guard let removido = strokes.popLast() else { return }

        redoStack[canvas.tag, default: []].append(removido)
        applyStrokes(strokes, to: canvas)
        feedback(.light)
    }

    @objc func handleRedo() {
        guard isDrawingEnabled, let canvas = visibleCanvas(),
              let restaurado = redoStack[canvas.tag]?.popLast() else { return }

        applyStrokes(canvas.drawing.strokes + [restaurado], to: canvas)
        feedback(.rigid)
    }

    private func applyStrokes(_ strokes: [PKStroke], to canvas: PKCanvasView) {
        // A atribuição dispara o delegate, que persiste e atualiza a contagem.
        canvas.drawing = PKDrawing(strokes: strokes)
    }

    /// Um toque que desfaz sem retorno tátil parece que não funcionou.
    private func feedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        persist(canvasView)
        onChange?()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // Traço novo invalida o histórico de refazer, como em qualquer editor.
        redoStack[canvasView.tag] = nil
    }

    private func persist(_ canvas: PKCanvasView) {
        guard let document else { return }
        let data = canvas.drawing.strokes.isEmpty ? Data() : canvas.drawing.dataRepresentation()
        try? store.save(data, document: document, page: canvas.tag)
    }

    // MARK: - Edição

    func clearCurrentPage() {
        guard let canvas = visibleCanvas() else { return }
        canvas.drawing = PKDrawing()
        persist(canvas)
        onChange?()
    }

    func clearDocument() {
        canvases.values.forEach { $0.drawing = PKDrawing() }
        if let document { try? store.removeAll(document: document) }
        onChange?()
    }

    var annotatedPageCount: Int {
        document.map { store.annotatedPages(document: $0).count } ?? 0
    }
}
