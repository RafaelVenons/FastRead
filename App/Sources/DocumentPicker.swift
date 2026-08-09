import SwiftUI
import UniformTypeIdentifiers

/// Seletor de arquivos do sistema, apresentado direto.
///
/// Relatado em uso: com `.fileImporter` o botão de pasta não abria nada no iPad, embora
/// abrisse no simulador em todos os estados testados. O `.fileImporter` é açúcar do
/// SwiftUI sobre este mesmo controlador, e a camada a mais é onde a apresentação se
/// perdia — aqui não há estado de apresentação para o SwiftUI reconciliar.
struct DocumentPicker: UIViewControllerRepresentable {

    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `asCopy: false` mantém o arquivo onde está; quem abre precisa do acesso com
        // escopo de segurança, e é por isso que a URL não pode ser só lida e esquecida.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
