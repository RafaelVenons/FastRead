import SwiftUI

/// Mostra o que aconteceu no último toque.
///
/// Existe porque os erros de realce e de escolha de trecho dependem do PDF: em documentos
/// gerados para teste tudo passa, e num artigo real não. Este painel expõe cada etapa da
/// cadeia — toque → índice na página → trecho escolhido → texto realçado — para localizar
/// em qual delas a informação se perde.
struct DiagnosticsPanel: View {

    let info: ReaderModel.TapDiagnostics
    let currentWord: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("diag.title", systemImage: "stethoscope")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: String(localized: "diag.location"), info.page + 1, info.characterIndex))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            linha(String(localized: "diag.tapLanded"), info.textAtIndex, mono: true)
            linha(String(localized: "diag.chosenPassage"),
                  info.segmentID.map { "#\($0)  \(info.segmentRange)" } ?? String(localized: "diag.none"))
            linha(String(localized: "diag.passageStarts"), info.segmentHead)

            Divider()

            linha(String(localized: "diag.shouldHighlight"), info.expectedHighlight, mono: true)
            linha(String(localized: "diag.didHighlight"), info.actualHighlight, mono: true,
                  alert: divergem(info.expectedHighlight, info.actualHighlight))

            if let currentWord {
                linha(String(localized: "diag.wordInVoice"), currentWord)
                linha(String(localized: "diag.wordHighlighted"), info.wordActual,
                      alert: divergem(currentWord, info.wordActual))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .textSelection(.enabled)
    }

    private func divergem(_ a: String, _ b: String) -> Bool {
        func limpo(_ s: String) -> String {
            s.replacingOccurrences(of: "⏎", with: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let x = limpo(a), y = limpo(b)
        guard !x.isEmpty, !y.isEmpty, y != "—", y != "(aguardando)" else { return false }
        return x != y
    }

    private func linha(_ rotulo: String, _ valor: String,
                       mono: Bool = false, alert: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(rotulo)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .trailing)
            Text(valor)
                .font(mono ? .caption2.monospaced() : .caption2)
                .foregroundStyle(alert ? Color.red : Color.primary)
                .lineLimit(3)
            if alert {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
    }
}
