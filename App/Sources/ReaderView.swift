import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderView: View {

    @State private var model = ReaderModel()
    @State private var showingImporter = false
    @State private var showingVoices = false

    var body: some View {
        NavigationStack {
            Group {
                if let document = model.document {
                    PDFCanvas(document: document,
                              highlight: model.highlight,
                              onTap: model.handleTap,
                              onHighlight: model.recordHighlight)
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
        .sheet(isPresented: $showingVoices) {
            VoicePickerView(model: model)
        }
        .task {
            // Permite que os testes de UI abram um PDF sem passar pelo seletor de arquivos.
            if let path = ProcessInfo.processInfo.environment["FASTREAD_OPEN_PDF"] {
                model.open(url: URL(fileURLWithPath: path))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("reader.empty.title", systemImage: "doc.text")
        } description: {
            Text("reader.empty.description")
        } actions: {
            Button("reader.open") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingImporter = true } label: { Image(systemName: "folder") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingVoices = true } label: {
                Image(systemName: "waveform.circle")
            }
            .disabled(model.availableVoices.isEmpty)
            .accessibilityIdentifier("voicePicker")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("reader.speed", selection: $model.rate) {
                    Text("reader.speed.slow").tag(Float(0.42))
                    Text("reader.speed.normal").tag(Float(0.5))
                    Text("reader.speed.fast").tag(Float(0.58))
                }
                Toggle("reader.autoAdvance", isOn: $model.autoAdvance)
                Toggle("reader.diagnostics", isOn: $model.diagnosticsEnabled)
                Divider()
                Text(model.cacheSizeDescription)
                Button("reader.clearCache", role: .destructive) { model.clearCache() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("settingsMenu")
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            if model.diagnosticsEnabled, let info = model.diagnostics {
                DiagnosticsPanel(info: info, currentWord: model.currentWordText)
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("status")
            }

            HStack(spacing: 28) {
                Button { model.playPrevious() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(model.currentIndex == nil)
                .accessibilityIdentifier("previous")

                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPreparing
                          ? "waveform"
                          : (model.player.isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                    .font(.system(size: 42))
                    .symbolEffect(.pulse, isActive: model.isPreparing)
                }
                .disabled(model.segments.isEmpty)
                .accessibilityIdentifier("playPause")

                Button { model.playNext() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(model.segments.isEmpty)
                .accessibilityIdentifier("next")
            }
            .font(.title2)

            if let index = model.currentIndex {
                Text(String(format: String(localized: "reader.segmentCounter"), index + 1, model.segments.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("segmentCounter")
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
