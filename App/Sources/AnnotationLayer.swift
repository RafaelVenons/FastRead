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

    var isDrawingEnabled = false {
        didSet {
            guard isDrawingEnabled != oldValue else { return }
            canvases.values.forEach { applyMode(to: $0) }
            // O PDFKit só pede os overlays quando (re)dispõe as páginas. Sem forçar,
            // entrar no modo de desenho não criava tela nenhuma e a Pencil continuava
            // rolando o documento.
            pdfView?.layoutDocumentView()
            updateToolPicker()
        }
    }

    var onChange: (() -> Void)?

    init(store: AnnotationStore) {
        self.store = store
    }

    func attach(to pdfView: PDFView, document: DocumentIdentifier?) {
        self.pdfView = pdfView
        self.document = document
        canvases.removeAll()
        pdfView.pageOverlayViewProvider = self
        pdfView.layoutDocumentView()
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
        // Desenhar é só com a Pencil: o dedo continua rolando, dando zoom e — fora do
        // modo — tocando num parágrafo para ouvi-lo.
        canvas.drawingPolicy = .pencilOnly
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.isScrollEnabled = false
        applyMode(to: canvas)
        installGestures(on: canvas)

        if let document, let data = store.load(document: document, page: index),
           let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }

        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView, isDrawingEnabled else { return }
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        persist(canvas)
    }

    private func applyMode(to canvas: PKCanvasView) {
        canvas.isUserInteractionEnabled = isDrawingEnabled
    }

    // MARK: - Paleta de ferramentas

    private func updateToolPicker() {
        guard let canvas = visibleCanvas() else { return }

        if isDrawingEnabled {
            toolPicker.addObserver(canvas)
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
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

    /// Dois dedos desfaz, três dedos refaz — como no Procreate.
    ///
    /// O iOS traz gestos parecidos, mas exigem três dedos para as duas ações e nem sempre
    /// chegam a uma tela dentro de um PDFView.
    private func installGestures(on canvas: PKCanvasView) {
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
            canvas.addGestureRecognizer($0)
        }
    }

    @objc private func handleUndo() {
        guard isDrawingEnabled, let manager = visibleCanvas()?.undoManager, manager.canUndo else { return }
        manager.undo()
        feedback(.light)
        onChange?()
    }

    @objc private func handleRedo() {
        guard isDrawingEnabled, let manager = visibleCanvas()?.undoManager, manager.canRedo else { return }
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
