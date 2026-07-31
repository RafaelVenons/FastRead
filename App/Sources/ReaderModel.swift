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

    // MARK: - Diagnóstico

    /// Registro do último toque, para investigar realce e escolha de trecho.
    struct TapDiagnostics: Equatable {
        var page: Int
        var characterIndex: Int
        /// Texto da página em volta do índice resolvido — mostra onde o toque "caiu".
        var textAtIndex: String
        var segmentID: Int?
        var segmentRange: String
        /// Primeiras palavras do trecho escolhido.
        var segmentHead: String
        /// O que a página tem no intervalo do trecho (o que deveria acender).
        var expectedHighlight: String
        /// O que o PDFKit de fato selecionou.
        var actualHighlight: String
        var wordExpected: String
        var wordActual: String
    }

    var diagnosticsEnabled = false
    private(set) var diagnostics: TapDiagnostics?

    /// Preenchido pelo PDFCanvas com o que realmente foi realçado.
    func recordHighlight(segment: String?, word: String?) {
        guard diagnosticsEnabled, var current = diagnostics else { return }
        current.actualHighlight = String((segment ?? "—").prefix(90))
        current.wordActual = word ?? "—"
        diagnostics = current
    }

    private func captureDiagnostics(pageIndex: Int, characterIndex: Int, segment: DocumentSegment?) {
        guard diagnosticsEnabled,
              let pageText = document?.page(at: pageIndex)?.string as NSString?
        else { return }

        let around = NSRange(location: max(0, characterIndex - 15),
                             length: min(40, max(0, pageText.length - max(0, characterIndex - 15))))
        let contexto = around.length > 0 ? pageText.substring(with: around) : "—"

        var esperado = "—"
        if let range = segment?.pageRange, NSMaxRange(range) <= pageText.length {
            esperado = String(pageText.substring(with: range).prefix(90))
        }

        diagnostics = TapDiagnostics(
            page: pageIndex,
            characterIndex: characterIndex,
            textAtIndex: contexto.replacingOccurrences(of: "\n", with: "⏎"),
            segmentID: segment?.id,
            segmentRange: segment?.pageRange.map { "\($0.location)..<\(NSMaxRange($0))" } ?? "—",
            segmentHead: String((segment?.text ?? "—").prefix(60)),
            expectedHighlight: esperado.replacingOccurrences(of: "\n", with: "⏎"),
            actualHighlight: "(aguardando)",
            wordExpected: "—",
            wordActual: "—")
    }
    var rate: Float = 0.5 { didSet { rebuildPipeline() } }

    /// Vozes instaladas para o idioma do documento.
    private(set) var availableVoices: [VoiceOption] = []
    /// Nulo = a melhor voz disponível para o idioma.
    var selectedVoiceIdentifier: String? {
        didSet {
            guard selectedVoiceIdentifier != oldValue else { return }
            // O áudio em cache é de outra voz; recomeça o trecho atual com a nova.
            player.stop()
            if let index = currentIndex { play(index: index) }
        }
    }

    var selectedVoice: VoiceOption? {
        selectedVoiceIdentifier.flatMap(VoiceCatalog.voice(withIdentifier:))
            ?? availableVoices.first
    }

    /// Todas as vozes do idioma são `compact`? Então vale sugerir o download.
    var shouldSuggestBetterVoice: Bool {
        !availableVoices.isEmpty && !VoiceCatalog.hasHighQualityVoice(for: documentLanguage)
    }

    let player = SegmentPlayer()

    /// Anotações com a Apple Pencil.
    private(set) var documentID: DocumentIdentifier?
    let annotations: AnnotationLayer
    /// Enquanto desenha, o toque não inicia a leitura.
    var isDrawing = false {
        didSet {
            strokeCount = annotations.strokeCountOnVisiblePage
            canUndo = annotations.canUndo
            canRedo = annotations.canRedo
            resolutionInfo = annotations.resolutionDescription
        }
    }
    /// Traços na página visível — exposto para a interface e para os testes.
    private(set) var strokeCount = 0
    /// Espelhados do `AnnotationLayer`, que não é observável: sem isto os botões de
    /// desfazer e refazer nunca saem de desabilitados.
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Só aparece no modo de diagnóstico.
    private(set) var resolutionInfo = ""

    private let segmenter = DocumentSegmenter()
    private let engine = AVSpeechSynthesisEngine()
    private let cache: DiskSegmentCache
    private var pipeline: SegmentPipeline

    init() {
        let directory = URL.cachesDirectory.appendingPathComponent("FastRead/segments")
        cache = DiskSegmentCache(directory: directory)
        // Anotações vão em Application Support, não em Caches: o sistema pode limpar
        // Caches sob pressão de disco, e o áudio se regenera — o traço do usuário não.
        annotations = AnnotationLayer(store: AnnotationStore(
            directory: URL.applicationSupportDirectory.appendingPathComponent("FastRead/annotations")))
        pipeline = SegmentPipeline(synthesizer: engine, cache: cache, rate: 0.5)

        player.onFinish = { [weak self] in
            guard let self, self.autoAdvance else { return }
            self.playNext()
        }
        annotations.onChange = { [weak self] in
            guard let self else { return }
            self.strokeCount = self.annotations.strokeCountOnVisiblePage
            self.canUndo = self.annotations.canUndo
            self.canRedo = self.annotations.canRedo
            self.resolutionInfo = self.annotations.resolutionDescription
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
            status = String(localized: "reader.status.openFailed")
            return
        }

        self.document = document
        documentID = DocumentIdentifier(fileAt: url)
        documentTitle = url.deletingPathExtension().lastPathComponent
        documentLanguage = segmenter.documentLanguage(of: document)
        segments = segmenter.segments(of: document, documentLanguage: documentLanguage)
        availableVoices = VoiceCatalog.voices(for: documentLanguage)
        selectedVoiceIdentifier = availableVoices.first?.identifier
        currentIndex = nil
        player.stop()

        status = segments.isEmpty
            ? String(localized: "reader.status.noText")
            : String(format: String(localized: "reader.status.ready"), segments.count, documentLanguage)
    }

    // MARK: - Leitura

    func handleTap(pageIndex: Int, characterIndex: Int) {
        guard !segments.isEmpty else { return }

        let hit = segmenter.segment(in: segments,
                                    pageIndex: pageIndex,
                                    characterIndex: characterIndex)
        captureDiagnostics(pageIndex: pageIndex, characterIndex: characterIndex, segment: hit)

        // Toca a partir de onde o dedo caiu, não do início do trecho: num parágrafo longo
        // recomeçar do topo a cada toque impede voltar a um ponto específico.
        if let hit {
            play(index: hit.id, fromPageIndex: characterIndex)
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

    func play(index: Int, fromPageIndex pageCharacterIndex: Int? = nil) {
        guard segments.indices.contains(index) else { return }
        let segment = segments[index]
        currentIndex = index

        // Posição dentro do trecho onde a leitura deve começar.
        let startAt = pageCharacterIndex.flatMap { segment.segment.normalizedIndex(forSource: $0) }

        Task { [pipeline] in
            // Já passou do trecho antigo: o que estava sendo pré-gerado não serve mais.
            await pipeline.cancelPrefetch()

            isPreparing = true
            defer { isPreparing = false }

            do {
                let cached = try await pipeline.prepare(
                    ReadingSegment(text: segment.text,
                                   language: segment.language,
                                   voiceIdentifier: selectedVoiceIdentifier))

                guard currentIndex == index else { return }   // o usuário tocou em outro
                let startTime = startAt.flatMap { cached.alignment.time(atTextIndex: $0) } ?? 0
                player.play(url: cached.audioURL,
                            alignment: snapshot(of: cached.alignment),
                            from: startTime)
                status = ""
            } catch {
                status = String(localized: "reader.status.synthesisFailed")
                return
            }

            // Gerar o próximo custa ~4% da duração do atual, então cabe folgado.
            let upcoming = ((index + 1)...(index + 2))
                .filter { segments.indices.contains($0) }
                .map { ReadingSegment(text: segments[$0].text,
                                      language: segments[$0].language,
                                      voiceIdentifier: selectedVoiceIdentifier) }
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

    /// Palavra que o alinhamento diz estar tocando agora, no texto do trecho.
    var currentWordText: String? {
        guard let index = currentIndex, segments.indices.contains(index),
              let range = player.currentWordRange else { return nil }
        let texto = segments[index].text as NSString
        guard NSMaxRange(range) <= texto.length else { return nil }
        return texto.substring(with: range)
    }

    var currentPageIndex: Int? {
        currentIndex.flatMap { segments.indices.contains($0) ? segments[$0].pageIndex : nil }
    }

    var cacheSizeDescription: String {
        let mb = Double(cache.totalSize()) / 1_048_576
        return String(format: String(localized: "reader.cacheSize"), String(format: "%.1f MB", mb))
    }

    func clearCache() {
        try? cache.removeAll()
        status = String(localized: "reader.status.cacheCleared")
    }
}
