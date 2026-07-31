import FastReadCore
import PDFKit
import UIKit

/// Coloca uma camada de tinta sobre cada página e guarda o que foi escrito.
///
/// `@preconcurrency`: o PDFKit entrega estes callbacks na main thread, mas o protocolo é
/// anterior ao isolamento e não declara isso.
@MainActor
final class InkLayerController: NSObject, @preconcurrency PDFPageOverlayViewProvider {

    private let store: AnnotationStore
    private var document: DocumentIdentifier?
    private var canvases: [Int: InkCanvasView] = [:]
    private weak var pdfView: PDFView?

    var onChange: (() -> Void)?

    /// Enquanto desenha, o toque não inicia a leitura e a rolagem sai de cena — o pan do
    /// PDFView ficaria com o arrasto antes de a camada vê-lo.
    var isDrawingEnabled = false {
        didSet {
            guard isDrawingEnabled != oldValue else { return }
            canvases.values.forEach { $0.isDrawingEnabled = isDrawingEnabled }
            setScrollEnabled(!isDrawingEnabled)
            onChange?()
        }
    }

    var color: InkColor = .black {
        didSet { canvases.values.forEach { $0.color = color } }
    }

    var baseWidth: Double = 3 {
        didSet { canvases.values.forEach { $0.baseWidth = baseWidth } }
    }

    /// O simulador não tem Pencil; os testes de interface liberam o dedo por variável.
    private let acceptsFinger = ProcessInfo.processInfo.environment["FASTREAD_FINGER_DRAWING"] == "1"

    init(store: AnnotationStore) {
        self.store = store
    }

    /// - Important: chamar **antes** de atribuir o documento. O PDFKit só consulta o
    ///   provider ao dispor as páginas; atribuí-lo depois não cria camada nenhuma.
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

        let canvas = InkCanvasView()
        canvas.color = color
        canvas.baseWidth = baseWidth
        canvas.acceptsFingerInput = acceptsFinger
        canvas.isDrawingEnabled = isDrawingEnabled
        canvas.onStrokeFinished = { [weak self] _ in
            self?.persist(page: index)
            self?.onChange?()
        }

        if let document, let data = store.load(document: document, page: index),
           let saved = try? JSONDecoder().decode(InkDrawing.self, from: data) {
            canvas.drawing = saved
        }

        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        // A page view do PDFKit vem com a interação desligada; sem religá-la, nenhum
        // toque chega à camada por mais correta que ela esteja.
        overlayView.superview?.isUserInteractionEnabled = isDrawingEnabled
    }

    // MARK: - Estado

    private func persist(page index: Int) {
        guard let document, let canvas = canvases[index] else { return }
        let data = canvas.drawing.strokes.isEmpty
            ? Data()
            : ((try? JSONEncoder().encode(canvas.drawing)) ?? Data())
        try? store.save(data, document: document, page: index)
    }

    private func visibleCanvas() -> InkCanvasView? {
        guard let pdfView, let page = pdfView.currentPage,
              let index = page.document?.index(for: page) else { return canvases.values.first }
        return canvases[index] ?? canvases.values.first
    }

    private func setScrollEnabled(_ enabled: Bool) {
        guard let pdfView else { return }
        for case let scroll as UIScrollView in pdfView.subviews {
            scroll.isScrollEnabled = enabled
            scroll.panGestureRecognizer.isEnabled = enabled
        }
    }

    // MARK: - Edição

    var strokeCount: Int { visibleCanvas()?.drawing.strokes.count ?? 0 }
    var canUndo: Bool { visibleCanvas()?.drawing.canUndo ?? false }
    var canRedo: Bool { visibleCanvas()?.drawing.canRedo ?? false }

    func undo() {
        guard let canvas = visibleCanvas(), canvas.drawing.canUndo else { return }
        canvas.drawing.undo()
        finishEdit(canvas)
    }

    func redo() {
        guard let canvas = visibleCanvas(), canvas.drawing.canRedo else { return }
        canvas.drawing.redo()
        finishEdit(canvas)
    }

    func clearCurrentPage() {
        guard let canvas = visibleCanvas() else { return }
        canvas.drawing.removeAll()
        finishEdit(canvas)
    }

    func clearDocument() {
        canvases.values.forEach { $0.drawing.removeAll() }
        if let document { try? store.removeAll(document: document) }
        onChange?()
    }

    private func finishEdit(_ canvas: InkCanvasView) {
        guard let index = canvases.first(where: { $0.value === canvas })?.key else { return }
        persist(page: index)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onChange?()
    }
}
