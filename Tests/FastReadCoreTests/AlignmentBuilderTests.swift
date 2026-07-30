import Foundation
import Testing
@testable import FastReadCore

// Formato real das vozes compact do sistema, medido: 22050 Hz, mono, float32.
private let formato = AudioFormatInfo(sampleRate: 22050, bytesPerFrame: 4)

private let texto = "O leitor de PDF destaca cada palavra enquanto a voz avança pelo parágrafo."

@Suite("AlignmentBuilder")
struct AlignmentBuilderTests {

    @Test("converte byteSampleOffset de bytes para segundos")
    func converteOffset() throws {
        // 88200 bytes = 22050 frames * 4 bytes = exatamente 1 segundo
        let a = AlignmentBuilder.build(
            text: "um dois",
            markers: [RawMarker(byteSampleOffset: 88_200, range: NSRange(location: 0, length: 2))],
            format: formato,
            totalFrames: 44_100)

        #expect(a.words.count == 1)
        #expect(abs(a.words[0].start - 1.0) < 0.0001)
    }

    /// Regressão do bug que custou a descoberta: tratar `byteSampleOffset` como índice
    /// de sample (em vez de byte) multiplica todos os tempos por `bytesPerFrame`.
    @Test("não interpreta byteSampleOffset como índice de sample")
    func naoConfundeByteComSample() {
        let a = AlignmentBuilder.build(
            text: "um dois",
            markers: [RawMarker(byteSampleOffset: 88_200, range: NSRange(location: 0, length: 2))],
            format: formato,
            totalFrames: 44_100)

        #expect(abs(a.words[0].start - 4.0) > 0.5, "start=4.0s seria o bug de dividir só pelo sample rate")
    }

    @Test("reproduz os tempos medidos na sonda")
    func temposMedidos() throws {
        // offsets reais capturados com a voz compact pt-BR
        let markers = [
            RawMarker(byteSampleOffset: 0,       range: NSRange(location: 0, length: 1)),   // "O"      -> 0.000s
            RawMarker(byteSampleOffset: 13_318,  range: NSRange(location: 2, length: 6)),   // "leitor" -> 0.151s
            RawMarker(byteSampleOffset: 403_449, range: NSRange(location: 64, length: 10)), // "parágrafo." -> 4.574s
        ]
        let a = AlignmentBuilder.build(text: texto, markers: markers, format: formato,
                                       totalFrames: 119_500)

        #expect(a.words.count == 3)
        #expect(abs(a.words[0].start - 0.000) < 0.01)
        #expect(abs(a.words[1].start - 0.151) < 0.01)
        #expect(abs(a.words[2].start - 4.574) < 0.01)
        #expect(a.words[1].word == "leitor")
        #expect(a.words[2].word == "parágrafo.")
    }

    @Test("descarta markers que apontam fora do texto")
    func descartaRangeInvalido() {
        let markers = [
            RawMarker(byteSampleOffset: 0, range: NSRange(location: 0, length: 1)),
            RawMarker(byteSampleOffset: 1000, range: NSRange(location: 900, length: 5)),   // além do fim
            RawMarker(byteSampleOffset: 2000, range: NSRange(location: NSNotFound, length: 2)),
            RawMarker(byteSampleOffset: 3000, range: NSRange(location: 2, length: 900)),   // extrapola
        ]
        let a = AlignmentBuilder.build(text: texto, markers: markers, format: formato, totalFrames: 22_050)
        #expect(a.words.count == 1)
    }

    @Test("ordena por tempo mesmo se os markers chegarem fora de ordem")
    func ordena() {
        let markers = [
            RawMarker(byteSampleOffset: 176_400, range: NSRange(location: 2, length: 6)),
            RawMarker(byteSampleOffset: 0,       range: NSRange(location: 0, length: 1)),
            RawMarker(byteSampleOffset: 88_200,  range: NSRange(location: 9, length: 2)),
        ]
        let a = AlignmentBuilder.build(text: texto, markers: markers, format: formato, totalFrames: 88_200)
        #expect(a.words.map(\.word) == ["O", "de", "leitor"])
        #expect(a.words.map(\.start) == a.words.map(\.start).sorted())
    }

    @Test("duração vem do total de frames escritos")
    func duracao() {
        let a = AlignmentBuilder.build(text: texto, markers: [], format: formato, totalFrames: 110_250)
        #expect(abs(a.duration - 5.0) < 0.0001)   // 110250 / 22050
        #expect(a.words.isEmpty)
    }

    @Test("formato degenerado não gera NaN nem divisão por zero")
    func formatoDegenerado() {
        let ruim = AudioFormatInfo(sampleRate: 0, bytesPerFrame: 0)
        let a = AlignmentBuilder.build(
            text: texto,
            markers: [RawMarker(byteSampleOffset: 1000, range: NSRange(location: 0, length: 1))],
            format: ruim, totalFrames: 1000)

        #expect(a.duration.isFinite)
        #expect(a.words.allSatisfy { $0.start.isFinite })
    }

    @Test("texto vazio não produz palavras")
    func textoVazio() {
        let a = AlignmentBuilder.build(
            text: "",
            markers: [RawMarker(byteSampleOffset: 0, range: NSRange(location: 0, length: 1))],
            format: formato, totalFrames: 0)
        #expect(a.words.isEmpty)
    }

    @Test("preserva acentuação e índices UTF-16")
    func acentuacao() throws {
        let t = "avança pelo parágrafo"
        let a = AlignmentBuilder.build(
            text: t,
            markers: [RawMarker(byteSampleOffset: 0, range: NSRange(location: 12, length: 9))],
            format: formato, totalFrames: 22_050)
        #expect(a.words.first?.word == "parágrafo")
    }
}

@Suite("TerminationGuard")
struct TerminationGuardTests {

    /// Medido: o `bufferCallback` do AVSpeechSynthesizer dispara duas vezes com
    /// `frameLength == 0` no fim da síntese (326 invocações, 2 vazias consecutivas).
    @Test("só deixa passar a primeira finalização")
    func finalizaUmaVez() {
        let guarda = TerminationGuard()
        #expect(guarda.claim() == true)
        #expect(guarda.claim() == false)
        #expect(guarda.claim() == false)
    }

    @Test("é seguro sob concorrência")
    func concorrente() async {
        let guarda = TerminationGuard()
        let vitorias = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 { group.addTask { guarda.claim() } }
            return await group.reduce(into: 0) { if $1 { $0 += 1 } }
        }
        #expect(vitorias == 1)
    }
}
