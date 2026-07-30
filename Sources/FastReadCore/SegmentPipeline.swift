import Foundation

/// Um trecho do PDF a ser lido, já com o idioma resolvido.
public struct ReadingSegment: Sendable, Equatable {
    public let text: String
    public let language: String
    /// Voz escolhida pelo usuário; nulo usa a melhor instalada para o idioma.
    public let voiceIdentifier: String?

    public init(text: String, language: String, voiceIdentifier: String? = nil) {
        self.text = text
        self.language = language
        self.voiceIdentifier = voiceIdentifier
    }
}

/// Orquestra cache, síntese e pré-geração.
///
/// A pré-geração compensa muito: medido, a síntese roda a ~39× o tempo real (M2), então
/// preparar o próximo segmento custa ~4% da duração do que está tocando. O trabalho real
/// aqui é garantir que o toque do usuário e o prefetch nunca sintetizem o mesmo texto
/// duas vezes.
public actor SegmentPipeline {

    private let synthesizer: any SegmentSynthesizing
    private let cache: any SegmentCaching
    private let rate: Float

    /// `Task` é struct, então a identidade da geração vai explícita: sem isso, limpar a
    /// chave depois de um `await` poderia derrubar uma síntese nova criada nesse meio-tempo.
    private struct InFlight {
        let id: UUID
        let task: Task<CachedSegment, Error>
    }

    /// Sínteses em andamento, por chave — a base do coalescing.
    private var inFlight: [SegmentKey: InFlight] = [:]
    /// Subconjunto de `inFlight` iniciado por prefetch, portanto descartável.
    private var prefetchKeys: Set<SegmentKey> = []

    public init(synthesizer: any SegmentSynthesizing, cache: any SegmentCaching, rate: Float = 0.5) {
        self.synthesizer = synthesizer
        self.cache = cache
        self.rate = rate
    }

    public nonisolated func key(for segment: ReadingSegment) -> SegmentKey {
        // A voz efetiva entra na chave: trocar de voz tem que invalidar o áudio gerado.
        let voice = segment.voiceIdentifier
            ?? synthesizer.voiceIdentifier(for: segment.language)
            ?? segment.language
        return SegmentKey(text: segment.text, voiceIdentifier: voice, rate: rate)
    }

    /// Entrega o segmento pronto para tocar, sintetizando apenas se necessário.
    public func prepare(_ segment: ReadingSegment) async throws -> CachedSegment {
        let key = key(for: segment)

        if let cached = try? cache.load(key) { return cached }

        if let existing = inFlight[key] {
            // Um prefetch já está cuidando disto; o usuário chegou antes da hora.
            // Deixa de ser descartável, para que cancelPrefetch não o derrube.
            prefetchKeys.remove(key)
            return try await existing.task.value
        }

        let entry = InFlight(id: UUID(), task: makeTask(key: key, segment: segment))
        inFlight[key] = entry
        // Limpa também em erro, senão a chave ficaria presa e impediria nova tentativa.
        defer { if inFlight[key]?.id == entry.id { inFlight[key] = nil } }

        return try await entry.task.value
    }

    /// Dispara a geração dos próximos segmentos sem bloquear quem chamou.
    public func prefetch(_ segments: [ReadingSegment]) {
        for segment in segments {
            let key = key(for: segment)
            guard inFlight[key] == nil, !cache.contains(key) else { continue }

            inFlight[key] = InFlight(id: UUID(), task: makeTask(key: key, segment: segment))
            prefetchKeys.insert(key)
        }
    }

    /// Descarta prefetches ainda em andamento — o usuário pulou para outro ponto.
    public func cancelPrefetch() {
        for key in prefetchKeys {
            inFlight[key]?.task.cancel()
            inFlight[key] = nil
        }
        prefetchKeys.removeAll()
    }

    /// Aguarda o trabalho pendente. Existe para os testes e para o encerramento ordenado.
    public func waitForPendingWork() async {
        while !inFlight.isEmpty {
            let pending = inFlight
            for (key, entry) in pending {
                _ = try? await entry.task.value
                if inFlight[key]?.id == entry.id {
                    inFlight[key] = nil
                    prefetchKeys.remove(key)
                }
            }
        }
    }

    /// `nonisolated` de propósito: um `Task` criado dentro de contexto isolado ao actor
    /// herda esse isolamento e passa a rodar no executor do actor — o que serializaria o
    /// prefetch. Medido: 3 segmentos levavam 0,65 s (soma) em vez de ~0,2 s (paralelo).
    private nonisolated func makeTask(key: SegmentKey, segment: ReadingSegment) -> Task<CachedSegment, Error> {
        Task { [synthesizer, cache, rate] in
            let produced = try await synthesizer.synthesize(text: segment.text,
                                                            language: segment.language,
                                                            rate: rate,
                                                            voiceIdentifier: segment.voiceIdentifier)
            // Se o usuário pulou adiante enquanto isto rodava, não suja o cache.
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: produced.audioURL)
                throw CancellationError()
            }
            return try cache.store(key, audio: produced.audioURL, alignment: produced.alignment)
        }
    }
}
