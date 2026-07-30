import Foundation
import Testing
@testable import FastReadCore

/// Sintetizador falso: conta chamadas e produz um arquivo real, para o cache poder movê-lo.
private final class FakeSynthesizer: SegmentSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var delay: Duration = .zero
    var failOn: Set<String> = []

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    var callCount: Int { calls.count }

    /// Síncrona de propósito: no Swift 6, NSLock não pode ser travado de contexto async.
    private func record(_ text: String) {
        lock.lock(); _calls.append(text); lock.unlock()
    }

    func voiceIdentifier(for language: String) -> String? { "fake.voice.\(language)" }

    func synthesize(text: String, language: String, rate: Float) async throws -> SynthesizedSegment {
        record(text)
        if delay > .zero { try await Task.sleep(for: delay) }
        if failOn.contains(text) { throw SynthesisError.producedNoAudio }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).m4a")
        try Data(repeating: 0x11, count: 256).write(to: url)

        let words = text.split(separator: " ").enumerated().map { i, w in
            WordTiming(word: String(w), location: i, length: w.count, start: Double(i) * 0.3)
        }
        return SynthesizedSegment(audioURL: url,
                                  alignment: SegmentAlignment(words: words,
                                                              duration: Double(words.count) * 0.3))
    }
}

private func makeCache() throws -> DiskSegmentCache {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PipelineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return DiskSegmentCache(directory: dir)
}

private func seg(_ text: String, _ lang: String = "en") -> ReadingSegment {
    ReadingSegment(text: text, language: lang)
}

@Suite("SegmentPipeline")
struct SegmentPipelineTests {

    @Test("cache vazio sintetiza e guarda")
    func missSintetiza() async throws {
        let fake = FakeSynthesizer()
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        let result = try await pipeline.prepare(seg("hello world"))
        #expect(fake.callCount == 1)
        #expect(result.alignment.words.count == 2)
        #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    }

    @Test("segunda leitura vem do cache sem sintetizar de novo")
    func hitNaoSintetiza() async throws {
        let fake = FakeSynthesizer()
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        _ = try await pipeline.prepare(seg("hello world"))
        let again = try await pipeline.prepare(seg("hello world"))

        #expect(fake.callCount == 1)
        #expect(again.alignment.words.count == 2)
    }

    @Test("pedidos concorrentes do mesmo segmento sintetizam uma vez só")
    func coalesceEmVoo() async throws {
        let fake = FakeSynthesizer()
        fake.delay = .milliseconds(120)          // garante sobreposição
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        async let a = pipeline.prepare(seg("same text"))
        async let b = pipeline.prepare(seg("same text"))
        async let c = pipeline.prepare(seg("same text"))
        _ = try await (a, b, c)

        #expect(fake.callCount == 1, "prefetch e toque do usuário não podem sintetizar em dobro")
    }

    @Test("segmentos diferentes sintetizam separadamente")
    func segmentosDistintos() async throws {
        let fake = FakeSynthesizer()
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        _ = try await pipeline.prepare(seg("primeiro"))
        _ = try await pipeline.prepare(seg("segundo"))
        #expect(fake.callCount == 2)
    }

    @Test("idioma diferente gera entrada de cache diferente")
    func idiomaDiscrimina() async throws {
        let fake = FakeSynthesizer()
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        _ = try await pipeline.prepare(seg("ambiguous", "en"))
        _ = try await pipeline.prepare(seg("ambiguous", "pt"))
        #expect(fake.callCount == 2)
    }

    @Test("prefetch deixa o próximo segmento pronto")
    func prefetchPrepara() async throws {
        let fake = FakeSynthesizer()
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        await pipeline.prefetch([seg("proximo trecho")])
        await pipeline.waitForPendingWork()

        #expect(fake.callCount == 1)
        // e agora o toque do usuário não sintetiza nada
        _ = try await pipeline.prepare(seg("proximo trecho"))
        #expect(fake.callCount == 1)
    }

    @Test("prefetch repetido não refaz trabalho")
    func prefetchIdempotente() async throws {
        let fake = FakeSynthesizer()
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        await pipeline.prefetch([seg("a"), seg("b")])
        await pipeline.waitForPendingWork()
        await pipeline.prefetch([seg("a"), seg("b")])
        await pipeline.waitForPendingWork()

        #expect(fake.callCount == 2)
    }

    @Test("cancelar descarta prefetch ainda não concluído")
    func cancelaPrefetch() async throws {
        let fake = FakeSynthesizer()
        fake.delay = .seconds(5)
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        await pipeline.prefetch([seg("longo demais")])
        await pipeline.cancelPrefetch()
        await pipeline.waitForPendingWork()

        #expect(cache.contains(SegmentKey(text: "longo demais",
                                          voiceIdentifier: "fake.voice.en", rate: 0.5)) == false)
    }

    @Test("falha na síntese propaga e não deixa entrada no cache")
    func falhaNaoPoluiCache() async throws {
        let fake = FakeSynthesizer()
        fake.failOn = ["quebrado"]
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        await #expect(throws: SynthesisError.self) {
            _ = try await pipeline.prepare(seg("quebrado"))
        }
        #expect(cache.contains(SegmentKey(text: "quebrado",
                                          voiceIdentifier: "fake.voice.en", rate: 0.5)) == false)
    }

    @Test("depois de falhar, uma nova tentativa é possível")
    func retentativaAposFalha() async throws {
        let fake = FakeSynthesizer()
        fake.failOn = ["instavel"]
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        _ = try? await pipeline.prepare(seg("instavel"))
        fake.failOn = []
        let ok = try await pipeline.prepare(seg("instavel"))

        #expect(ok.alignment.words.isEmpty == false)
        #expect(fake.callCount == 2, "a entrada em voo que falhou não pode ficar presa")
    }

    @Test("prefetch de vários segmentos roda em paralelo")
    func prefetchParalelo() async throws {
        let fake = FakeSynthesizer()
        fake.delay = .milliseconds(200)
        let cache = try makeCache()
        let pipeline = SegmentPipeline(synthesizer: fake, cache: cache, rate: 0.5)

        let inicio = ContinuousClock.now
        await pipeline.prefetch([seg("um"), seg("dois"), seg("tres")])
        await pipeline.waitForPendingWork()
        let decorrido = ContinuousClock.now - inicio

        #expect(fake.callCount == 3)
        #expect(decorrido < .milliseconds(500), "serializado levaria ~600ms")
    }
}
