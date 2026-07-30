import FastReadCore
import SwiftUI

/// Lista as vozes instaladas para o idioma do documento.
///
/// Existe porque descobrir isso nos Ajustes é ruim: o painel mudou de nome para
/// "Read & Speak" no iPadOS 26, e de lá não dá para saber qual voz um app vai usar.
/// Aqui a qualidade de cada uma fica visível antes de ouvir.
struct VoicePickerView: View {

    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.shouldSuggestBetterVoice {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Só há vozes padrão instaladas")
                                    .font(.subheadline.weight(.medium))
                                Text("Ajustes → Acessibilidade → Read & Speak → Vozes. "
                                     + "Baixe uma voz Aprimorada ou Premium e ela aparece aqui.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                }

                Section("Vozes para \(model.documentLanguage)") {
                    ForEach(model.availableVoices) { voice in
                        Button {
                            model.selectedVoiceIdentifier = voice.identifier
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name)
                                        .foregroundStyle(.primary)
                                    Text("\(voice.quality.label) · \(voice.language)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
            .navigationTitle("Voz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluir") { dismiss() }
                }
            }
        }
    }
}
