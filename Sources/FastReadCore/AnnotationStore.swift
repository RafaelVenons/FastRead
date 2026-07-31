import CryptoKit
import Foundation

/// Identidade de um documento, derivada do conteúdo.
///
/// Não pode vir da URL: o seletor de arquivos entrega um caminho diferente a cada
/// importação, e as anotações sumiriam ao reabrir o mesmo PDF.
public struct DocumentIdentifier: Hashable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// Lê o começo do arquivo em vez do todo: um artigo de 13 páginas tem alguns MB, e
    /// abrir o documento já é lento o bastante sem somar a leitura completa a cada vez.
    public init?(fileAt url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 64 * 1024), !head.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: Data(String(size).utf8))
        self.value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Guarda as anotações feitas com a Apple Pencil, uma por página.
///
/// O conteúdo é opaco de propósito — quem grava é o `PKDrawing` do PencilKit, e o núcleo
/// não depende dele para continuar testável fora de um app.
public final class AnnotationStore: @unchecked Sendable {

    private let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func folder(_ document: DocumentIdentifier) -> URL {
        directory.appendingPathComponent(document.value)
    }

    private func file(_ document: DocumentIdentifier, _ page: Int) -> URL {
        folder(document).appendingPathComponent("page-\(page).drawing")
    }

    /// Grava o traço da página. Um traço vazio apaga a anotação — é o que sobra quando o
    /// usuário desfaz tudo, e guardar um arquivo vazio faria a página parecer anotada.
    public func save(_ drawing: Data, document: DocumentIdentifier, page: Int) throws {
        lock.lock(); defer { lock.unlock() }

        guard !drawing.isEmpty else {
            try? fileManager.removeItem(at: file(document, page))
            return
        }
        try fileManager.createDirectory(at: folder(document), withIntermediateDirectories: true)
        try drawing.write(to: file(document, page), options: .atomic)
    }

    public func load(document: DocumentIdentifier, page: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: file(document, page))
    }

    public func hasAnnotations(document: DocumentIdentifier) -> Bool {
        !annotatedPages(document: document).isEmpty
    }

    public func annotatedPages(document: DocumentIdentifier) -> [Int] {
        lock.lock(); defer { lock.unlock() }

        let contents = (try? fileManager.contentsOfDirectory(at: folder(document),
                                                             includingPropertiesForKeys: nil,
                                                             options: .skipsHiddenFiles)) ?? []
        return contents
            .compactMap { url -> Int? in
                let name = url.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("page-") else { return nil }
                return Int(name.dropFirst("page-".count))
            }
            .sorted()
    }

    public func removeAll(document: DocumentIdentifier) throws {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: folder(document))
    }
}
