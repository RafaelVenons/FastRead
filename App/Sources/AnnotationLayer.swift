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
                             @preconcurrency PKCanvasViewDelegate {

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

    /// Escala efetiva de rasterização — exibida no modo de diagnóstico para conferir se
    /// a correção de nitidez chegou de fato à tela, em vez de julgar pelo olho.
    var resolutionDescription: String {
        guard let canvas = visibleCanvas() else { return "—" }
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

        // Ampliar muda quanto de tela cada ponto da página ocupa; sem reagir, o traço
        // feito com zoom fica na resolução de antes.
        NotificationCenter.default.removeObserver(self, name: .PDFViewScaleChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged),
                                               name: .PDFViewScaleChanged, object: pdfView)
        pdfView.pageOverlayViewProvider = self
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

    /// Desfazer e refazer vão pelo `undoManager` da tela, o mesmo que os gestos de
    /// três dedos do iOS acionam.
    ///
    /// Uma pilha própria parecia mais simples, mas criava um histórico paralelo: desfazer
    /// pelo gesto e refazer pelo botão não se enxergavam, e vice-versa.
    private var undoManagerForVisibleCanvas: UndoManager? {
        visibleCanvas()?.undoManager
    }

    var canUndo: Bool { undoManagerForVisibleCanvas?.canUndo ?? false }
    var canRedo: Bool { undoManagerForVisibleCanvas?.canRedo ?? false }

    @objc func handleUndo() {
        guard let manager = undoManagerForVisibleCanvas, manager.canUndo else { return }
        manager.undo()
        feedback(.light)
        onChange?()
    }

    @objc func handleRedo() {
        guard let manager = undoManagerForVisibleCanvas, manager.canRedo else { return }
        manager.redo()
        feedback(.rigid)
        onChange?()
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
