import FastReadCore
import PDFKit
import SwiftUI

/// Onde o PDF aparece e onde o destaque acontece.
///
/// O realce usa `highlightedSelections` do próprio PDFView em vez de uma view sobreposta:
/// assim ele acompanha zoom, rotação e rolagem sem nenhum código de coordenadas — e
/// sobreposições foram justamente o ponto onde a integração PencilKit+PDFKit costuma
/// perder resolução ao ampliar.
struct PDFCanvas: UIViewRepresentable {

    struct Highlight: Equatable {
        let pageIndex: Int
        /// Trecho inteiro que está sendo lido, em índices de `page.string`.
        let segmentRange: NSRange
        /// Palavra sendo pronunciada agora.
        let wordRange: NSRange?
    }

    let document: PDFDocument
    let highlight: Highlight?
    let onTap: (_ pageIndex: Int, _ characterIndex: Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .secondarySystemBackground

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        // Não cancela os gestos internos do PDFView: seleção de texto e zoom continuam.
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        context.coordinator.pdfView = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        context.coordinator.onTap = onTap
        context.coordinator.apply(highlight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    /// UIKit entrega esses callbacks na main thread, mas o compilador não sabe disso
    /// através do seletor — a anotação é o que torna as chamadas ao PDFView legais.
    @MainActor
    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var onTap: (_ pageIndex: Int, _ characterIndex: Int) -> Void
        private var applied: Highlight?

        init(onTap: @escaping (_ pageIndex: Int, _ characterIndex: Int) -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView, let document = pdfView.document else { return }
            let point = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: point, nearest: true),
                  let pageText = page.string as NSString?
            else { return }

            let pageIndex = document.index(for: page)
            let inPage = pdfView.convert(point, to: page)

            // Mira em parágrafo, não em letra: quase todo toque cai fora de um glifo, e
            // aí o PDFKit devolve NSNotFound. O locator resolve pelo caractere mais perto.
            guard let index = PageTextLocator.characterIndex(on: page, at: inPage, in: pageText)
            else { return }

            onTap(pageIndex, index)
        }

        func apply(_ highlight: Highlight?) {
            guard applied != highlight else { return }
            applied = highlight

            guard let pdfView, let document = pdfView.document, let highlight,
                  let page = document.page(at: highlight.pageIndex),
                  let pageText = page.string as NSString?
            else {
                pdfView?.highlightedSelections = nil
                return
            }

            var selections: [PDFSelection] = []
            if let segment = PageTextLocator.selection(on: page, matching: highlight.segmentRange, in: pageText) {
                segment.color = UIColor.systemYellow.withAlphaComponent(0.22)
                selections.append(segment)
            }
            if let wordRange = highlight.wordRange,
               let word = PageTextLocator.selection(on: page, matching: wordRange, in: pageText) {
                word.color = UIColor.systemYellow.withAlphaComponent(0.75)
                selections.append(word)
            }
            pdfView.highlightedSelections = selections.isEmpty ? nil : selections
        }
    }
}
