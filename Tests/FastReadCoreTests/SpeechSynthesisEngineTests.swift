import AVFoundation
import Foundation
import Testing
@testable import FastReadCore

private let ingles = "The reader highlights every word while the voice moves through the paragraph."

/// Estes testes exercitam o AVSpeechSynthesizer de verdade: são a única forma de
/// pegar regressões nas armadilhas medidas (offset em bytes, callback duplo).
@Suite("AVSpeechSynthesisEngine", .serialized)
struct SpeechSynthesisEngineTests {

    @Test("sintetiza e alinha um segmento")
    func sintetizaEAlinha() async throws {
        let engine = AVSpeechSynthesisEngine()
        let result = try await engine.synthesize(text: ingles, language: "en", rate: 0.5)
        defer { try? FileManager.default.removeItem(at: result.audioURL) }

        #expect(result.alignment.words.count >= 10)
        #expect(result.alignment.duration > 1.0)
        #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    }

    @Test("tempos são crescentes e cabem na duração")
    func temposCoerentes() async throws {
        let engine = AVSpeechSynthesisEngine()
        let result = try await engine.synthesize(text: ingles, language: "en", rate: 0.5)
        defer { try? FileManager.default.removeItem(at: result.audioURL) }

        let starts = result.alignment.words.map(\.start)
        #expect(starts == starts.sorted())
        #expect(starts.allSatisfy { $0 >= 0 })

        // a armadilha do byteSampleOffset se manifesta aqui: os tempos estourariam 4x
        let ultimo = try #require(starts.last)
        #expect(ultimo <= result.alignment.duration)
        #expect(ultimo > result.alignment.duration * 0.4)
    }

    @Test("as palavras alinhadas correspondem ao texto original")
    func palavrasBatemComTexto() async throws {
        let engine = AVSpeechSynthesisEngine()
        let result = try await engine.synthesize(text: ingles, language: "en", rate: 0.5)
        defer { try? FileManager.default.removeItem(at: result.audioURL) }

        let ns = ingles as NSString
        for w in result.alignment.words {
            #expect(ns.substring(with: w.range) == w.word)
        }
        #expect(result.alignment.words.contains { $0.word.contains("reader") })
    }

    @Test("saída é AAC reproduzível e muito menor que o PCM equivalente")
    func saidaComprimida() async throws {
        let engine = AVSpeechSynthesisEngine()
        let result = try await engine.synthesize(text: ingles, language: "en", rate: 0.5)
        defer { try? FileManager.default.removeItem(at: result.audioURL) }

        let file = try AVAudioFile(forReading: result.audioURL)
        #expect(file.length > 0)

        let bytes = try Data(contentsOf: result.audioURL).count
        let pcmEquivalente = result.alignment.duration * 22_050 * 4
        #expect(Double(bytes) < pcmEquivalente * 0.2, "esperado ~15x menor que PCM float32")
    }

    @Test("texto sem conteúdo falável é rejeitado")
    func textoVazio() async throws {
        let engine = AVSpeechSynthesisEngine()
        await #expect(throws: SynthesisError.self) {
            _ = try await engine.synthesize(text: "   \n ", language: "en", rate: 0.5)
        }
    }

    @Test("idioma sem voz instalada falha de forma explícita")
    func idiomaIndisponivel() async throws {
        let engine = AVSpeechSynthesisEngine()
        await #expect(throws: SynthesisError.self) {
            _ = try await engine.synthesize(text: ingles, language: "zz-ZZ", rate: 0.5)
        }
    }

    @Test("sintetiza segmentos em paralelo sem embaralhar resultados")
    func paralelo() async throws {
        let engine = AVSpeechSynthesisEngine()
        let textos = [
            "First segment about alpha.",
            "Second segment about beta and gamma.",
            "Third segment about delta epsilon zeta.",
        ]

        let results = try await withThrowingTaskGroup(of: (Int, SynthesizedSegment).self) { group in
            for (i, t) in textos.enumerated() {
                group.addTask { (i, try await engine.synthesize(text: t, language: "en", rate: 0.5)) }
            }
            var acc: [(Int, SynthesizedSegment)] = []
            for try await r in group { acc.append(r) }
            return acc.sorted { $0.0 < $1.0 }
        }
        defer { results.forEach { try? FileManager.default.removeItem(at: $0.1.audioURL) } }

        #expect(results.count == 3)
        for (i, seg) in results {
            let ns = textos[i] as NSString
            // cada resultado precisa alinhar contra o SEU texto, não o de outro segmento
            for w in seg.alignment.words { #expect(ns.substring(with: w.range) == w.word) }
        }
        #expect(results[2].1.alignment.duration > results[0].1.alignment.duration)
    }

    @Test("velocidade maior encurta o áudio")
    func velocidadeAfetaDuracao() async throws {
        let engine = AVSpeechSynthesisEngine()
        let lento = try await engine.synthesize(text: ingles, language: "en", rate: 0.4)
        let rapido = try await engine.synthesize(text: ingles, language: "en", rate: 0.6)
        defer {
            try? FileManager.default.removeItem(at: lento.audioURL)
            try? FileManager.default.removeItem(at: rapido.audioURL)
        }
        #expect(rapido.alignment.duration < lento.alignment.duration)
    }
}
