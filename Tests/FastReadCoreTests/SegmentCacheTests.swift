import Foundation
import Testing
@testable import FastReadCore

/// Cria um diretório temporário isolado por teste.
private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FastReadTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFakeAudio(_ dir: URL, bytes: Int = 1024) throws -> URL {
    let url = dir.appendingPathComponent("src-\(UUID().uuidString).m4a")
    try Data(repeating: 0xAB, count: bytes).write(to: url)
    return url
}

private let alignment = SegmentAlignment(
    words: [WordTiming(word: "Hello", location: 0, length: 5, start: 0)],
    duration: 1.0
)

private func key(_ text: String) -> SegmentKey {
    SegmentKey(text: text, voiceIdentifier: "voz.teste", rate: 0.5)
}

@Suite("DiskSegmentCache")
struct DiskSegmentCacheTests {

    @Test("cache vazio não contém nada")
    func vazio() throws {
        let cache = DiskSegmentCache(directory: try makeTempDir())
        #expect(cache.contains(key("nada")) == false)
        #expect(try cache.load(key("nada")) == nil)
        #expect(cache.totalSize() == 0)
    }

    @Test("guarda e recupera áudio e alinhamento")
    func guardaERecupera() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        let k = key("Hello world")
        let source = try makeFakeAudio(dir, bytes: 2048)

        let stored = try cache.store(k, audio: source, alignment: alignment)
        #expect(FileManager.default.fileExists(atPath: stored.audioURL.path))
        #expect(cache.contains(k))

        let loaded = try #require(try cache.load(k))
        #expect(loaded.alignment == alignment)
        #expect(try Data(contentsOf: loaded.audioURL).count == 2048)
    }

    @Test("guardar consome o arquivo de origem em vez de duplicá-lo")
    func consomeOrigem() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        let source = try makeFakeAudio(dir)

        _ = try cache.store(key("x"), audio: source, alignment: alignment)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }

    @Test("regravar a mesma chave substitui o conteúdo")
    func regravaSobrescreve() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        let k = key("mesmo")

        _ = try cache.store(k, audio: try makeFakeAudio(dir, bytes: 1000), alignment: alignment)
        let novo = SegmentAlignment(
            words: [WordTiming(word: "Novo", location: 0, length: 4, start: 0)], duration: 9.0)
        _ = try cache.store(k, audio: try makeFakeAudio(dir, bytes: 3000), alignment: novo)

        let loaded = try #require(try cache.load(k))
        #expect(loaded.alignment.duration == 9.0)
        #expect(try Data(contentsOf: loaded.audioURL).count == 3000)
    }

    @Test("remove apaga áudio e alinhamento")
    func remove() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        let k = key("apagar")
        _ = try cache.store(k, audio: try makeFakeAudio(dir), alignment: alignment)

        try cache.remove(k)
        #expect(cache.contains(k) == false)
        #expect(try cache.load(k) == nil)
        #expect(cache.totalSize() == 0)
    }

    @Test("entrada meio-gravada é tratada como ausente e limpa")
    func entradaCorrompida() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        let k = key("corrompido")
        let stored = try cache.store(k, audio: try makeFakeAudio(dir), alignment: alignment)

        // simula queda entre gravar o JSON e gravar o áudio
        try FileManager.default.removeItem(at: stored.audioURL)

        #expect(cache.contains(k) == false)
        #expect(try cache.load(k) == nil)
        // e não deve deixar o JSON órfão para trás
        #expect(cache.totalSize() == 0)
    }

    @Test("totalSize soma áudio e alinhamento de todas as entradas")
    func tamanhoTotal() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        _ = try cache.store(key("a"), audio: try makeFakeAudio(dir, bytes: 5000), alignment: alignment)
        _ = try cache.store(key("b"), audio: try makeFakeAudio(dir, bytes: 3000), alignment: alignment)

        #expect(cache.totalSize() > 8000)
        #expect(cache.totalSize() < 12000)   // JSON é pequeno
    }

    @Test("prune remove as entradas menos recentes até caber no limite")
    func pruneRespeitaLimite() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)

        let antiga = key("antiga")
        let media = key("media")
        let recente = key("recente")
        for (k, bytes) in [(antiga, 4000), (media, 4000), (recente, 4000)] {
            _ = try cache.store(k, audio: try makeFakeAudio(dir, bytes: bytes), alignment: alignment)
        }
        // envelhece explicitamente em vez de depender de sleep
        try cache.touch(antiga, date: Date(timeIntervalSince1970: 1_000))
        try cache.touch(media, date: Date(timeIntervalSince1970: 2_000))
        try cache.touch(recente, date: Date(timeIntervalSince1970: 3_000))

        try cache.prune(toMaxBytes: 9_000)

        #expect(cache.contains(antiga) == false)
        #expect(cache.contains(recente))
        #expect(cache.totalSize() <= 9_000)
    }

    @Test("prune não faz nada se já cabe")
    func pruneNoop() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        let k = key("fica")
        _ = try cache.store(k, audio: try makeFakeAudio(dir, bytes: 1000), alignment: alignment)

        try cache.prune(toMaxBytes: 10_000_000)
        #expect(cache.contains(k))
    }

    @Test("carregar renova o carimbo de recência")
    func loadRenovaRecencia() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        let velha = key("v")
        let nova = key("n")
        _ = try cache.store(velha, audio: try makeFakeAudio(dir, bytes: 4000), alignment: alignment)
        _ = try cache.store(nova, audio: try makeFakeAudio(dir, bytes: 4000), alignment: alignment)
        try cache.touch(velha, date: Date(timeIntervalSince1970: 1_000))
        try cache.touch(nova, date: Date(timeIntervalSince1970: 2_000))

        _ = try cache.load(velha)          // agora "velha" é a mais recente
        try cache.prune(toMaxBytes: 5_000)

        #expect(cache.contains(velha))
        #expect(cache.contains(nova) == false)
    }

    @Test("removeAll esvazia o cache")
    func removeAll() throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)
        _ = try cache.store(key("a"), audio: try makeFakeAudio(dir), alignment: alignment)
        _ = try cache.store(key("b"), audio: try makeFakeAudio(dir), alignment: alignment)

        try cache.removeAll()
        #expect(cache.totalSize() == 0)
        #expect(cache.contains(key("a")) == false)
    }

    @Test("cria o diretório se ainda não existir")
    func criaDiretorio() throws {
        let base = try makeTempDir().appendingPathComponent("sub/dir/profundo")
        let cache = DiskSegmentCache(directory: base)
        _ = try cache.store(key("a"), audio: try makeFakeAudio(try makeTempDir()), alignment: alignment)
        #expect(cache.contains(key("a")))
    }

    @Test("escritas concorrentes de chaves distintas não se corrompem")
    func escritasConcorrentes() async throws {
        let dir = try makeTempDir()
        let cache = DiskSegmentCache(directory: dir)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let src = try? makeFakeAudio(dir, bytes: 500)
                    if let src { _ = try? cache.store(key("seg-\(i)"), audio: src, alignment: alignment) }
                }
            }
        }

        for i in 0..<20 { #expect(cache.contains(key("seg-\(i)"))) }
    }
}
