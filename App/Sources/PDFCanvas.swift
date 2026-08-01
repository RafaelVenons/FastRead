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
    /// Identidade estável do arquivo, para as notas reencontrarem o documento.
    var documentID: DocumentIdentifier?
    let highlight: Highlight?
    let onTap: (_ pageIndex: Int, _ characterIndex: Int) -> Void
    /// Reporta o que foi de fato selecionado — o modo de diagnóstico compara com o esperado.
    var onHighlight: ((_ segment: String?, _ word: String?) -> Void)?
    var ink: InkLayerController?
    var isDrawing = false

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        // O provider tem de estar no lugar ANTES do documento: o PDFKit só o consulta ao
        // dispor as páginas, e atribuí-lo depois não cria camada de tinta nenhuma.
        ink?.attach(to: view, document: documentID)
        view.document = document
        view.autoScales = true
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .secondarySystemBackground
        // Sem `isAccessibilityElement`: marcá-lo como folha impede o XCUITest de calcular
        // pontos internos, e gestos de vários dedos deixam de ser testáveis.
        view.accessibilityIdentifier = "pdfCanvas"

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        // Não cancela os gestos internos do PDFView: seleção de texto e zoom continuam.
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        context.coordinator.pdfView = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            ink?.attach(to: view, document: documentID)
            view.document = document
        }
        // `isInMarkupMode` é o que faz o PDFKit ligar a interação nas page views; sem
        // ele, PDFPageView fica com isUserInteractionEnabled = false e nenhum toque
        // chega à camada de tinta.
        view.isInMarkupMode = isDrawing
        ink?.isDrawingEnabled = isDrawing
        context.coordinator.isDrawing = isDrawing
        context.coordinator.onTap = onTap
        context.coordinator.onHighlight = onHighlight
        context.coordinator.apply(highlight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    /// UIKit entrega esses callbacks na main thread, mas o compilador não sabe disso
    /// através do seletor — a anotação é o que torna as chamadas ao PDFView legais.
    @MainActor
    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var onTap: (_ pageIndex: Int, _ characterIndex: Int) -> Void
        var onHighlight: ((_ segment: String?, _ word: String?) -> Void)?
    var ink: InkLayerController?
    var isDrawing = false
        private var applied: Highlight?

        init(onTap: @escaping (_ pageIndex: Int, _ characterIndex: Int) -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard !isDrawing else { return }
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
            let segment = PageTextLocator.selection(on: page, matching: highlight.segmentRange, in: pageText)
            if let segment {
                segment.color = UIColor.systemYellow.withAlphaComponent(0.22)
                selections.append(segment)
            }
            var word: PDFSelection?
            if let wordRange = highlight.wordRange {
                word = PageTextLocator.selection(on: page, matching: wordRange, in: pageText)
                if let word {
                    word.color = UIColor.systemYellow.withAlphaComponent(0.75)
                    selections.append(word)
                }
            }
            pdfView.highlightedSelections = selections.isEmpty ? nil : selections
            onHighlight?(segment?.string, word?.string)
        }
    }
}
