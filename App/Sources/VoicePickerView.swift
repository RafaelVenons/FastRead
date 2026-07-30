import FastReadCore
import SwiftUI

/// Lista as vozes instaladas para o idioma do documento.
///
/// Existe porque descobrir isso nos Ajustes é ruim: o painel mudou de nome para
/// "Read & Speak" no iPadOS 26, e de lá não dá para saber qual voz um app vai usar.
/// Aqui a qualidade de cada uma fica visível antes de ouvir.
struct VoicePickerView: View {

    /// A qualidade vem do núcleo como valor; o texto exibido é do app, que é quem tem
    /// as traduções.
    static func label(for quality: VoiceQuality) -> String {
        switch quality {
        case .standard: String(localized: "voice.quality.standard")
        case .enhanced: String(localized: "voice.quality.enhanced")
        case .premium: String(localized: "voice.quality.premium")
        }
    }

    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.shouldSuggestBetterVoice {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("voice.onlyDefault.title")
                                    .font(.subheadline.weight(.medium))
                                Text("voice.onlyDefault.description")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                }

                Section(String(format: String(localized: "voice.section"), model.documentLanguage)) {
                    ForEach(model.availableVoices) { voice in
                        Button {
                            model.selectedVoiceIdentifier = voice.identifier
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name)
                                        .foregroundStyle(.primary)
                                    Text("\(Self.label(for: voice.quality)) · \(voice.language)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("quality-\(voice.quality.rawValue)")
                                }
                                Spacer()
                                if voice.quality > .standard {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.tint)
                                }
                                if voice.identifier == model.selectedVoiceIdentifier {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("voice-\(voice.name)")
                    }
                }
            }
            .accessibilityIdentifier("voiceSheet")
            .navigationTitle("voice.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("voice.done") { dismiss() }
                }
            }
        }
    }
}
