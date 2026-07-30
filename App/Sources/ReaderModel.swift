import FastReadCore
import Foundation
import Observation
import PDFKit

@MainActor
@Observable
final class ReaderModel {

    private(set) var document: PDFDocument?
    private(set) var documentTitle = ""
    private(set) var segments: [DocumentSegment] = []
    private(set) var documentLanguage = "en"
    private(set) var currentIndex: Int?
    private(set) var isPreparing = false
    private(set) var status = ""

    /// Continua para o próximo segmento quando o atual termina.
    var autoAdvance = true
    var rate: Float = 0.5 { didSet { rebuildPipeline() } }

    let player = SegmentPlayer()

    private let segmenter = DocumentSegmenter()
    private let engine = AVSpeechSynthesisEngine()
    private let cache: DiskSegmentCache
    private var pipeline: SegmentPipeline

    init() {
        let directory = URL.cachesDirectory.appendingPathComponent("FastRead/segments")
        cache = DiskSegmentCache(directory: directory)
        pipeline = SegmentPipeline(synthesizer: engine, cache: cache, rate: 0.5)

        player.onFinish = { [weak self] in
            guard let self, self.autoAdvance else { return }
            self.playNext()
        }
    }

    private func rebuildPipeline() {
        pipeline = SegmentPipeline(synthesizer: engine, cache: cache, rate: rate)
    }

    // MARK: - Documento

    func open(url: URL) {
        // O picker devolve uma URL fora do sandbox; sem isto o PDFKit lê vazio.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url) else {
            status = "Não consegui abrir esse PDF."
            return
        }

        self.document = document
        documentTitle = url.deletingPathExtension().lastPathComponent
        documentLanguage = segmenter.documentLanguage(of: document)
        segments = segmenter.segments(of: document, documentLanguage: documentLanguage)
        currentIndex = nil
        player.stop()

        status = segments.isEmpty
            ? "Esse PDF não tem texto selecionável — provavelmente é digitalizado."
            : "\(segments.count) trechos · idioma \(documentLanguage)"
    }

    // MARK: - Leitura

    func handleTap(pageIndex: Int, characterIndex: Int) {
        guard !segments.isEmpty else { return }

        if let hit = segmenter.segment(in: segments,
                                       pageIndex: pageIndex,
                                       characterIndex: characterIndex) {
            play(index: hit.id)
        }
    }

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
        } else if currentIndex != nil {
            player.resume()
        } else {
            play(index: 0)
        }
    }

    func playNext() {
        guard let current = currentIndex, current + 1 < segments.count else {
            player.stop()
            currentIndex = nil
            return
        }
        play(index: current + 1)
    }

    func playPrevious() {
        guard let current = currentIndex, current > 0 else { return }
        play(index: current - 1)
    }

    func play(index: Int) {
        guard segments.indices.contains(index) else { return }
        let segment = segments[index]
        currentIndex = index

        Task { [pipeline] in
            // Já passou do trecho antigo: o que estava sendo pré-gerado não serve mais.
            await pipeline.cancelPrefetch()

            isPreparing = true
            defer { isPreparing = false }

            do {
                let cached = try await pipeline.prepare(
                    ReadingSegment(text: segment.text, language: segment.language))

                guard currentIndex == index else { return }   // o usuário tocou em outro
                player.play(url: cached.audioURL, alignment: snapshot(of: cached.alignment))
                status = ""
            } catch {
                status = "Não consegui sintetizar esse trecho."
                return
            }

            // Gerar o próximo custa ~4% da duração do atual, então cabe folgado.
            let upcoming = ((index + 1)...(index + 2))
                .filter { segments.indices.contains($0) }
                .map { ReadingSegment(text: segments[$0].text, language: segments[$0].language) }
            await pipeline.prefetch(upcoming)
        }
    }

    private func snapshot(of alignment: SegmentAlignment) -> SegmentPlayer.SegmentAlignmentSnapshot {
        .init(words: alignment.words.map { ($0.range, $0.start) }, duration: alignment.duration)
    }

    // MARK: - Destaque

    var highlight: PDFCanvas.Highlight? {
        guard let index = currentIndex, segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        guard let segmentRange = segment.pageRange else { return nil }

        // O alinhamento fala em índices do texto normalizado; a página usa os dela.
        let wordRange = player.currentWordRange.flatMap(segment.segment.sourceRange(for:))

        return PDFCanvas.Highlight(pageIndex: segment.pageIndex,
                                   segmentRange: segmentRange,
                                   wordRange: wordRange)
    }

    var currentPageIndex: Int? {
        currentIndex.flatMap { segments.indices.contains($0) ? segments[$0].pageIndex : nil }
    }

    var cacheSizeDescription: String {
        let mb = Double(cache.totalSize()) / 1_048_576
        return String(format: "%.1f MB em cache", mb)
    }

    func clearCache() {
        try? cache.removeAll()
        status = "Cache limpo."
    }
}
