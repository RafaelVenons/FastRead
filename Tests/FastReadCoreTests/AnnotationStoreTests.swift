import Foundation
import Testing
@testable import FastReadCore

private func makeStore() throws -> AnnotationStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("Annotations-\(UUID().uuidString)")
    return AnnotationStore(directory: dir)
}

private let docA = DocumentIdentifier(value: "doc-a")
private let docB = DocumentIdentifier(value: "doc-b")

@Suite("AnnotationStore")
struct AnnotationStoreTests {

    @Test("página sem anotação não devolve nada")
    func vazio() throws {
        let store = try makeStore()
        #expect(store.load(document: docA, page: 0) == nil)
        #expect(store.hasAnnotations(document: docA) == false)
    }

    @Test("guarda e recupera o traço de uma página")
    func guardaERecupera() throws {
        let store = try makeStore()
        let traço = Data(repeating: 0x7A, count: 512)

        try store.save(traço, document: docA, page: 3)
        #expect(store.load(document: docA, page: 3) == traço)
        #expect(store.hasAnnotations(document: docA))
    }

    @Test("páginas são independentes")
    func paginasIndependentes() throws {
        let store = try makeStore()
        try store.save(Data([1, 2, 3]), document: docA, page: 0)
        try store.save(Data([4, 5, 6]), document: docA, page: 1)

        #expect(store.load(document: docA, page: 0) == Data([1, 2, 3]))
        #expect(store.load(document: docA, page: 1) == Data([4, 5, 6]))
        #expect(store.load(document: docA, page: 2) == nil)
    }

    @Test("documentos são independentes")
    func documentosIndependentes() throws {
        let store = try makeStore()
        try store.save(Data([1]), document: docA, page: 0)

        #expect(store.load(document: docB, page: 0) == nil)
        #expect(store.hasAnnotations(document: docB) == false)
    }

    @Test("regravar substitui o traço anterior")
    func regravaSubstitui() throws {
        let store = try makeStore()
        try store.save(Data(repeating: 0x01, count: 100), document: docA, page: 0)
        try store.save(Data(repeating: 0x02, count: 40), document: docA, page: 0)

        let carregado = try #require(store.load(document: docA, page: 0))
        #expect(carregado.count == 40)
        #expect(carregado.allSatisfy { $0 == 0x02 })
    }

    @Test("traço vazio apaga a anotação da página")
    func vazioApaga() throws {
        let store = try makeStore()
        try store.save(Data([9, 9]), document: docA, page: 2)
        try store.save(Data(), document: docA, page: 2)

        #expect(store.load(document: docA, page: 2) == nil)
        #expect(store.hasAnnotations(document: docA) == false)
    }

    @Test("apaga tudo de um documento sem tocar no outro")
    func apagaDocumento() throws {
        let store = try makeStore()
        try store.save(Data([1]), document: docA, page: 0)
        try store.save(Data([2]), document: docB, page: 0)

        try store.removeAll(document: docA)
        #expect(store.hasAnnotations(document: docA) == false)
        #expect(store.load(document: docB, page: 0) == Data([2]))
    }

    @Test("lista as páginas anotadas em ordem")
    func listaPaginas() throws {
        let store = try makeStore()
        for page in [5, 1, 3] { try store.save(Data([UInt8(page)]), document: docA, page: page) }
        #expect(store.annotatedPages(document: docA) == [1, 3, 5])
    }

    @Test("sobrevive a uma nova instância apontando para o mesmo lugar")
    func persisteEntreInstancias() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Annotations-\(UUID().uuidString)")
        try AnnotationStore(directory: dir).save(Data([7, 7, 7]), document: docA, page: 4)

        #expect(AnnotationStore(directory: dir).load(document: docA, page: 4) == Data([7, 7, 7]))
    }

    @Test("escritas concorrentes em páginas distintas não se perdem")
    func escritasConcorrentes() async throws {
        let store = try makeStore()
        await withTaskGroup(of: Void.self) { group in
            for page in 0..<20 {
                group.addTask { try? store.save(Data([UInt8(page)]), document: docA, page: page) }
            }
        }
        #expect(store.annotatedPages(document: docA).count == 20)
    }
}

@Suite("DocumentIdentifier")
struct DocumentIdentifierTests {

    @Test("o mesmo arquivo gera a mesma identidade")
    func identidadeEstavel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-\(UUID().uuidString).pdf")
        try Data(repeating: 0x2A, count: 4096).write(to: url)

        let a = try #require(DocumentIdentifier(fileAt: url))
        let b = try #require(DocumentIdentifier(fileAt: url))
        #expect(a == b)
    }

    @Test("arquivos diferentes geram identidades diferentes")
    func identidadeDiscrimina() throws {
        let base = FileManager.default.temporaryDirectory
        let um = base.appendingPathComponent("id1-\(UUID().uuidString).pdf")
        let outro = base.appendingPathComponent("id2-\(UUID().uuidString).pdf")
        try Data(repeating: 0x01, count: 4096).write(to: um)
        try Data(repeating: 0x02, count: 4096).write(to: outro)

        #expect(DocumentIdentifier(fileAt: um) != DocumentIdentifier(fileAt: outro))
    }

    /// A URL muda a cada importação; a identidade tem de vir do conteúdo, senão as
    /// anotações somem quando o mesmo PDF é aberto de novo.
    @Test("mover ou renomear o arquivo preserva a identidade")
    func identidadeIndependeDoCaminho() throws {
        let base = FileManager.default.temporaryDirectory
        let original = base.appendingPathComponent("antes-\(UUID().uuidString).pdf")
        let movido = base.appendingPathComponent("depois-\(UUID().uuidString).pdf")
        try Data(repeating: 0x33, count: 8192).write(to: original)

        let antes = try #require(DocumentIdentifier(fileAt: original))
        try FileManager.default.moveItem(at: original, to: movido)
        #expect(DocumentIdentifier(fileAt: movido) == antes)
    }

    @Test("arquivo inexistente não gera identidade")
    func arquivoInexistente() {
        #expect(DocumentIdentifier(fileAt: URL(fileURLWithPath: "/nao/existe.pdf")) == nil)
    }

    @Test("identidade serve como nome de arquivo")
    func usavelComoNomeDeArquivo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fn-\(UUID().uuidString).pdf")
        try Data(repeating: 0x5, count: 1024).write(to: url)

        let id = try #require(DocumentIdentifier(fileAt: url))
        let permitido = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(id.value.unicodeScalars.allSatisfy(permitido.contains))
    }
}
