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
/// `@preconcurrency` nas conformances: PDFKit e PencilKit entregam esses callbacks na
/// main thread, mas os protocolos são anteriores ao isolamento e não declaram isso.
@MainActor
final class AnnotationLayer: NSObject, @preconcurrency PDFPageOverlayViewProvider,
                             @preconcurrency PKCanvasViewDelegate {

    private let store: AnnotationStore
    private var document: DocumentIdentifier?
    private var canvases: [Int: PKCanvasView] = [:]
    private weak var pdfView: PDFView?

    /// Fora do modo de desenho a tela precisa deixar o toque passar para o PDF, senão o
    /// leitor não consegue mais tocar num parágrafo para ouvi-lo.
    var isDrawingEnabled = false {
        didSet { canvases.values.forEach { applyMode(to: $0) } }
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
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let index = page.document?.index(for: page) else { return nil }

        if let existing = canvases[index] { return existing }

        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly   // o dedo continua servindo para ler e rolar
        canvas.delegate = self
        canvas.tag = index
        applyMode(to: canvas)

        if let document, let data = store.load(document: document, page: index),
           let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }

        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        persist(canvas)
    }

    private func applyMode(to canvas: PKCanvasView) {
        canvas.isUserInteractionEnabled = isDrawingEnabled
        // `pencilOnly` já ignora o dedo, mas desligar a interação por completo garante
        // que o toque de leitura chegue ao PDF mesmo com a Pencil por perto.
        canvas.drawingPolicy = isDrawingEnabled ? .pencilOnly : .pencilOnly
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

    // MARK: - Ferramentas

    /// Mostra a paleta do sistema, com as mesmas ferramentas de qualquer app da Apple.
    func showToolPicker(in window: UIWindow?) {
        guard let window, let canvas = visibleCanvas() else { return }
        let picker = PKToolPicker.shared(for: window)
        picker?.setVisible(true, forFirstResponder: canvas)
        picker?.addObserver(canvas)
        canvas.becomeFirstResponder()
    }

    func hideToolPicker(in window: UIWindow?) {
        guard let window else { return }
        let picker = PKToolPicker.shared(for: window)
        canvases.values.forEach {
            picker?.setVisible(false, forFirstResponder: $0)
            $0.resignFirstResponder()
        }
    }

    private func visibleCanvas() -> PKCanvasView? {
        guard let pdfView, let page = pdfView.currentPage,
              let index = page.document?.index(for: page) else { return canvases.values.first }
        return canvases[index] ?? canvases.values.first
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
