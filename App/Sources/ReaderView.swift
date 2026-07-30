import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderView: View {

    @State private var model = ReaderModel()
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if let document = model.document {
                    PDFCanvas(document: document,
                              highlight: model.highlight,
                              onTap: model.handleTap)
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    emptyState
                }
            }
            .navigationTitle(model.documentTitle.isEmpty ? "FastRead" : model.documentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if model.document != nil { controls }
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { model.open(url: url) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nenhum PDF aberto", systemImage: "doc.text")
        } description: {
            Text("Abra um PDF e toque em um parágrafo para ouvi-lo com o texto destacado palavra a palavra.")
        } actions: {
            Button("Abrir PDF") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingImporter = true } label: { Image(systemName: "folder") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Velocidade", selection: $model.rate) {
                    Text("Lenta").tag(Float(0.42))
                    Text("Normal").tag(Float(0.5))
                    Text("Rápida").tag(Float(0.58))
                }
                Toggle("Continuar automaticamente", isOn: $model.autoAdvance)
                Divider()
                Text(model.cacheSizeDescription)
                Button("Limpar cache", role: .destructive) { model.clearCache() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                Button { model.playPrevious() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(model.currentIndex == nil)

                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPreparing
                          ? "waveform"
                          : (model.player.isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                    .font(.system(size: 42))
                    .symbolEffect(.pulse, isActive: model.isPreparing)
                }
                .disabled(model.segments.isEmpty)

                Button { model.playNext() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(model.segments.isEmpty)
            }
            .font(.title2)

            if let index = model.currentIndex {
                Text("Trecho \(index + 1) de \(model.segments.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
