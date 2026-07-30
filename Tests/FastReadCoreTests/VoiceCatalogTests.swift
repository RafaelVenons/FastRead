import AVFoundation
import Foundation
import Testing
@testable import FastReadCore

@Suite("VoiceCatalog")
struct VoiceCatalogTests {

    @Test("lista as vozes instaladas para um idioma")
    func listaVozes() {
        let vozes = VoiceCatalog.voices(for: "en")
        #expect(!vozes.isEmpty)
        #expect(vozes.allSatisfy { $0.language.lowercased().hasPrefix("en") })
        #expect(vozes.allSatisfy { !$0.identifier.isEmpty })
        #expect(vozes.allSatisfy { !$0.name.isEmpty })
    }

    @Test("aceita idioma com região")
    func idiomaComRegiao() {
        let so = VoiceCatalog.voices(for: "pt-BR")
        #expect(!so.isEmpty)
        #expect(so.allSatisfy { $0.language.lowercased().hasPrefix("pt") })
    }

    @Test("ordena da melhor qualidade para a pior")
    func ordenaPorQualidade() {
        let vozes = VoiceCatalog.voices(for: "en")
        let qualidades = vozes.map(\.quality)
        #expect(qualidades == qualidades.sorted(by: >))
    }

    @Test("desempata por nome para uma listagem estável")
    func ordemEstavel() {
        let a = VoiceCatalog.voices(for: "en")
        let b = VoiceCatalog.voices(for: "en")
        #expect(a == b)

        let mesmaQualidade = Dictionary(grouping: a, by: \.quality)
        for (_, grupo) in mesmaQualidade where grupo.count > 1 {
            #expect(grupo.map(\.name) == grupo.map(\.name).sorted())
        }
    }

    @Test("best devolve a de maior qualidade")
    func melhorVoz() throws {
        let melhor = try #require(VoiceCatalog.best(for: "en"))
        let todas = VoiceCatalog.voices(for: "en")
        #expect(todas.allSatisfy { $0.quality <= melhor.quality })
        #expect(melhor.identifier == todas.first?.identifier)
    }

    @Test("idioma sem vozes devolve lista vazia")
    func idiomaInexistente() {
        #expect(VoiceCatalog.voices(for: "zz").isEmpty)
        #expect(VoiceCatalog.best(for: "zz") == nil)
        #expect(VoiceCatalog.voices(for: "").isEmpty)
    }

    @Test("classifica a qualidade a partir do sistema")
    func classificaQualidade() {
        let vozes = VoiceCatalog.voices(for: "en")
        // O sistema traz ao menos as compact; enhanced/premium dependem de download.
        #expect(vozes.contains { $0.quality == .standard })
        #expect(vozes.allSatisfy { VoiceQuality.allCases.contains($0.quality) })
    }

    @Test("descreve a qualidade para exibição")
    func descricaoDeQualidade() {
        #expect(VoiceQuality.standard.label == "Padrão")
        #expect(VoiceQuality.enhanced.label == "Aprimorada")
        #expect(VoiceQuality.premium.label == "Premium")
    }

    @Test("informa se há voz melhor para baixar")
    func sugereDownload() {
        // Sem enhanced/premium instalada, o app deve poder avisar o usuário.
        let temMelhor = VoiceCatalog.hasHighQualityVoice(for: "en")
        let melhor = VoiceCatalog.best(for: "en")
        #expect(temMelhor == (melhor.map { $0.quality > .standard } ?? false))
    }

    @Test("resolve uma voz por identificador")
    func resolvePorIdentificador() throws {
        let alguma = try #require(VoiceCatalog.voices(for: "en").first)
        let resolvida = VoiceCatalog.voice(withIdentifier: alguma.identifier)
        #expect(resolvida?.identifier == alguma.identifier)
        #expect(VoiceCatalog.voice(withIdentifier: "nao.existe.voz") == nil)
    }
}
