import FastReadCore
import SwiftUI

/// Ferramentas de escrita, visíveis enquanto o modo de desenho está ativo.
///
/// Fica na tela e não no menu: escolher cor e espessura acontece o tempo todo enquanto se
/// anota, e enterrar isso em dois toques de menu inviabiliza o uso.
struct InkToolbar: View {

    @Bindable var model: ReaderModel

    private static let palette: [(name: String, color: InkColor)] = [
        ("black", InkColor(red: 0.1, green: 0.1, blue: 0.12)),
        ("blue", InkColor(red: 0.0, green: 0.35, blue: 0.9)),
        ("red", InkColor(red: 0.85, green: 0.15, blue: 0.15)),
        ("green", InkColor(red: 0.1, green: 0.6, blue: 0.25)),
        ("yellow", InkColor(red: 0.95, green: 0.75, blue: 0.1, alpha: 0.45)),
    ]

    private static let widths: [(name: String, value: Double)] = [
        ("fine", 1.2), ("medium", 2.5), ("bold", 5),
    ]

    var body: some View {
        HStack(spacing: 14) {
            caneta
            Divider().frame(height: 22)
            cores
            Divider().frame(height: 22)
            espessuras
            Divider().frame(height: 22)
            historico
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
    }

    private var caneta: some View {
        HStack(spacing: 8) {
            botao("applepencil.tip", ativo: model.inkTool == .pen, id: "toolPen") {
                model.inkTool = .pen
            }
            botao("eraser", ativo: model.inkTool == .eraser, id: "toolEraser") {
                model.inkTool = .eraser
            }
        }
    }

    private var cores: some View {
        HStack(spacing: 8) {
            ForEach(Self.palette, id: \.name) { item in
                Button {
                    model.inkColor = item.color
                    model.inkTool = .pen
                } label: {
                    Circle()
                        .fill(Color(red: item.color.red, green: item.color.green,
                                    blue: item.color.blue).opacity(item.color.alpha))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(.primary,
                                                  lineWidth: model.inkColor == item.color ? 2 : 0)
                        )
                }
                .accessibilityIdentifier("color-\(item.name)")
            }
        }
    }

    private var espessuras: some View {
        HStack(spacing: 8) {
            ForEach(Self.widths, id: \.name) { item in
                Button {
                    model.inkWidth = item.value
                } label: {
                    // O ponto mostra a espessura que vai sair, em vez de um rótulo.
                    Circle()
                        .fill(.primary)
                        .frame(width: 4 + item.value * 1.6, height: 4 + item.value * 1.6)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle().fill(model.inkWidth == item.value
                                          ? Color.accentColor.opacity(0.2) : .clear)
                        )
                }
                .accessibilityIdentifier("width-\(item.name)")
            }
        }
    }

    private var historico: some View {
        HStack(spacing: 10) {
            botao("arrow.uturn.backward", ativo: false, id: "undo",
                  desabilitado: !model.canUndo) { model.ink.undo() }
            botao("arrow.uturn.forward", ativo: false, id: "redo",
                  desabilitado: !model.canRedo) { model.ink.redo() }
        }
    }

    private func botao(_ symbol: String, ativo: Bool, id: String,
                       desabilitado: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 30, height: 26)
                .background(ativo ? Color.accentColor.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .disabled(desabilitado)
        .accessibilityIdentifier(id)
    }
}
