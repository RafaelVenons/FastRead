import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FastReadCore

private func makePDF(_ body: String) throws -> PDFDocument {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("e2e-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)
    let attributed = NSAttributedString(string: body, attributes: [
        .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
    context.endPDFPage()
    context.closePDF()

    guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadUnknown) }
    return document
}

/// Percorre a cadeia inteira como o app percorre: PDF → segmentos → síntese → cache →
/// destaque. É o teste que pegaria uma quebra na costura entre os componentes.
@Suite("Fluxo completo", .serialized)
struct EndToEndTests {

    @Test("do PDF ao destaque, com cache reaproveitado na segunda leitura")
    func fluxoCompleto() async throws {
        let doc = try makePDF(
            "The reader highlights every word while the voice moves through the paragraph.\n"
            + "A second paragraph follows with more content to be read aloud by the app.")

        let segmenter = DocumentSegmenter()
        let language = segmenter.documentLanguage(of: doc)
        #expect(language == "en")

        let segments = segmenter.segments(of: doc, documentLanguage: language)
        #expect(segments.count == 2)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-cache-\(UUID().uuidString)")
        let cache = DiskSegmentCache(directory: dir)
        let engine = AVSpeechSynthesisEngine()
        let pipeline = SegmentPipeline(synthesizer: engine, cache: cache, rate: 0.5)

        let first = try #require(segments.first)

        // 1ª leitura: sintetiza
        let produced = try await pipeline.prepare(
            ReadingSegment(text: first.text, language: first.language))
        #expect(produced.alignment.words.count >= 8)
        #expect(cache.totalSize() > 0)

        // 2ª leitura: vem do cache, mesmo alinhamento
        let reused = try await pipeline.prepare(
            ReadingSegment(text: first.text, language: first.language))
        #expect(reused.alignment == produced.alignment)
        #expect(reused.audioURL == produced.audioURL)

        // O destaque no meio do áudio tem que cair sobre uma palavra real da página.
        let meio = produced.alignment.duration / 2
        let wordRange = try #require(produced.alignment.range(at: meio))
        let naPagina = try #require(first.segment.sourceRange(for: wordRange))
        let pageText = try #require(doc.page(at: first.pageIndex)?.string) as NSString

        #expect(NSMaxRange(naPagina) <= pageText.length)
        let palavraNaPagina = pageText.substring(with: naPagina)
        let palavraNoAudio = (first.text as NSString).substring(with: wordRange)
        #expect(palavraNaPagina == palavraNoAudio)
        let temLetra = palavraNaPagina.contains(where: \.isLetter)
        #expect(temLetra)

        try? FileManager.default.removeItem(at: dir)
    }

    @Test("prefetch deixa o segmento seguinte pronto antes do toque")
    func prefetchAntecipaProximo() async throws {
        let doc = try makePDF(
            "First paragraph that the reader will listen to right now.\n"
            + "Second paragraph that should already be waiting in the cache.")

        let segmenter = DocumentSegmenter()
        let segments = segmenter.segments(of: doc, documentLanguage: "en")
        #expect(segments.count == 2)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-prefetch-\(UUID().uuidString)")
        let cache = DiskSegmentCache(directory: dir)
        let pipeline = SegmentPipeline(synthesizer: AVSpeechSynthesisEngine(),
                                       cache: cache, rate: 0.5)

        let proximo = ReadingSegment(text: segments[1].text, language: segments[1].language)
        await pipeline.prefetch([proximo])
        await pipeline.waitForPendingWork()

        // quando o usuário chegar nele, já está em disco
        let chave = pipeline.key(for: proximo)
        #expect(cache.contains(chave))

        try? FileManager.default.removeItem(at: dir)
    }
}
