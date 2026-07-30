import Foundation

/// Um segmento já sintetizado: o áudio comprimido e o alinhamento para destacar o texto.
public struct CachedSegment: Sendable, Equatable {
    public let audioURL: URL
    public let alignment: SegmentAlignment

    public init(audioURL: URL, alignment: SegmentAlignment) {
        self.audioURL = audioURL
        self.alignment = alignment
    }
}

public protocol SegmentCaching: Sendable {
    func contains(_ key: SegmentKey) -> Bool
    func load(_ key: SegmentKey) throws -> CachedSegment?
    @discardableResult
    func store(_ key: SegmentKey, audio: URL, alignment: SegmentAlignment) throws -> CachedSegment
    func remove(_ key: SegmentKey) throws
}

/// Cache em disco: um `.m4a` e um `.json` por segmento, nomeados pela `SegmentKey`.
///
/// Guardar AAC em vez do PCM que sai do sintetizador é o que torna o cache viável —
/// medido, PCM float32 custa 311 MB/hora contra 17 MB/hora em AAC 24 kbps, ou seja
/// 2,5 GB contra 136 MB para um livro de ~8 horas de leitura.
public final class DiskSegmentCache: SegmentCaching, @unchecked Sendable {

    private let directory: URL
    private let fileManager = FileManager.default
    /// Serializa as operações: o prefetch escreve segmentos enquanto a UI lê o atual.
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func audioURL(_ key: SegmentKey) -> URL {
        directory.appendingPathComponent("\(key.value).m4a")
    }

    private func alignmentURL(_ key: SegmentKey) -> URL {
        directory.appendingPathComponent("\(key.value).json")
    }

    // MARK: - Leitura

    public func contains(_ key: SegmentKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isComplete(key)
    }

    /// Uma entrada só vale se as duas metades existirem — o app pode ter sido morto
    /// entre gravar o áudio e gravar o alinhamento.
    private func isComplete(_ key: SegmentKey) -> Bool {
        fileManager.fileExists(atPath: audioURL(key).path)
            && fileManager.fileExists(atPath: alignmentURL(key).path)
    }

    public func load(_ key: SegmentKey) throws -> CachedSegment? {
        lock.lock(); defer { lock.unlock() }

        guard isComplete(key) else {
            try? removeFiles(key)   // descarta a metade órfã
            return nil
        }

        let data = try Data(contentsOf: alignmentURL(key))
        guard let alignment = try? JSONDecoder().decode(SegmentAlignment.self, from: data) else {
            try? removeFiles(key)   // JSON ilegível: melhor ressintetizar
            return nil
        }

        try? stamp(key, date: Date())   // recência para o prune
        return CachedSegment(audioURL: audioURL(key), alignment: alignment)
    }

    // MARK: - Escrita

    /// Move `audio` para dentro do cache. O arquivo de origem deixa de existir.
    ///
    /// O áudio entra antes do alinhamento de propósito: se o processo morrer no meio,
    /// sobra um `.m4a` sem `.json`, que `load` trata como ausente e limpa.
    @discardableResult
    public func store(_ key: SegmentKey, audio: URL, alignment: SegmentAlignment) throws -> CachedSegment {
        lock.lock(); defer { lock.unlock() }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = audioURL(key)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: audio, to: destination)
        } catch {
            // volumes diferentes: copiar e apagar a origem preserva o contrato
            try fileManager.copyItem(at: audio, to: destination)
            try? fileManager.removeItem(at: audio)
        }

        let data = try JSONEncoder().encode(alignment)
        try data.write(to: alignmentURL(key), options: .atomic)

        return CachedSegment(audioURL: destination, alignment: alignment)
    }

    public func remove(_ key: SegmentKey) throws {
        lock.lock(); defer { lock.unlock() }
        try removeFiles(key)
    }

    private func removeFiles(_ key: SegmentKey) throws {
        try? fileManager.removeItem(at: audioURL(key))
        try? fileManager.removeItem(at: alignmentURL(key))
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Espaço em disco

    public func totalSize() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return contents().reduce(0) { $0 + size(of: $1) }
    }

    /// Descarta as entradas menos usadas até o cache caber em `maxBytes`.
    public func prune(toMaxBytes maxBytes: Int64) throws {
        lock.lock(); defer { lock.unlock() }

        var total = contents().reduce(0) { $0 + size(of: $1) }
        guard total > maxBytes else { return }

        // agrupa por chave (o par .m4a/.json) e ordena do menos recente ao mais recente
        let entries = Set(contents().map { $0.deletingPathExtension().lastPathComponent })
            .map { name -> (name: String, date: Date, bytes: Int64) in
                let audio = directory.appendingPathComponent("\(name).m4a")
                let json = directory.appendingPathComponent("\(name).json")
                return (name, modificationDate(of: json) ?? .distantPast,
                        size(of: audio) + size(of: json))
            }
            .sorted { $0.date < $1.date }

        for entry in entries where total > maxBytes {
            try? fileManager.removeItem(at: directory.appendingPathComponent("\(entry.name).m4a"))
            try? fileManager.removeItem(at: directory.appendingPathComponent("\(entry.name).json"))
            total -= entry.bytes
        }
    }

    /// Reposiciona uma entrada na ordem de recência. Existe para os testes poderem
    /// envelhecer entradas sem depender de espera real.
    public func touch(_ key: SegmentKey, date: Date) throws {
        lock.lock(); defer { lock.unlock() }
        try stamp(key, date: date)
    }

    private func stamp(_ key: SegmentKey, date: Date) throws {
        for url in [audioURL(key), alignmentURL(key)] where fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    // MARK: - Auxiliares de sistema de arquivos

    private func contents() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
    }

    private func size(of url: URL) -> Int64 {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func modificationDate(of url: URL) -> Date? {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}
