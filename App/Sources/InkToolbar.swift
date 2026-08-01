import FastReadCore
import SwiftUI

/// Ferramentas de escrita, visíveis enquanto o modo de desenho está ativo.
///
/// Fica na tela e não no menu: escolher cor e espessura acontece o tempo todo enquanto se
/// anota, e enterrar isso em dois toques de menu inviabiliza o uso.
struct InkToolbar: View {

    @Bindable var model: ReaderModel

    /// Atalhos para as cores mais usadas. O ciclo cromático completo fica ao lado, para
    /// qualquer outra — a paleta fixa é conveniência, não limite.
    private static let shortcuts: [(name: String, color: InkColor)] = [
        ("black", InkColor(red: 0.1, green: 0.1, blue: 0.12)),
        ("blue", InkColor(red: 0.0, green: 0.35, blue: 0.9)),
        ("red", InkColor(red: 0.85, green: 0.15, blue: 0.15)),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ferramenta
            Divider().frame(height: 24)
            cores
            Divider().frame(height: 24)
            espessura
            Divider().frame(height: 24)
            historico
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
    }

    // MARK: - Ferramenta

    private var ferramenta: some View {
        HStack(spacing: 6) {
            botao("applepencil.tip", ativo: model.inkTool == .pen, id: "toolPen") {
                model.inkTool = .pen
            }
            botao("eraser", ativo: model.inkTool == .eraser, id: "toolEraser") {
                model.inkTool = .eraser
            }
        }
    }

    // MARK: - Cor

    private var cores: some View {
        HStack(spacing: 8) {
            ForEach(Self.shortcuts, id: \.name) { item in
                Button {
                    model.inkColor = item.color
                    model.inkTool = .pen
                } label: {
                    Circle()
                        .fill(swiftUIColor(item.color))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.primary,
                                                       lineWidth: model.inkColor == item.color ? 2 : 0))
                }
                .accessibilityIdentifier("color-\(item.name)")
            }

            // Ciclo cromático do sistema: qualquer cor, com opacidade.
            ColorPicker("notes.color", selection: colorBinding, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 26, height: 26)
                .accessibilityIdentifier("colorWheel")
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { swiftUIColor(model.inkColor) },
            set: { novo in
                model.inkColor = inkColor(from: novo)
                model.inkTool = .pen
            }
        )
    }

    // MARK: - Espessura

    private var espessura: some View {
        HStack(spacing: 8) {
            // A amostra mostra a espessura real que vai sair, em vez de um número.
            Circle()
                .fill(swiftUIColor(model.inkColor))
                .frame(width: amostra, height: amostra)
                .frame(width: 22, height: 22)
                .accessibilityIdentifier("widthPreview")

            Slider(value: $model.inkWidth, in: 0.5...12)
                .frame(width: 110)
                .accessibilityIdentifier("widthSlider")
        }
    }

    /// Limitada para o ponto de amostra não estourar a barra em espessuras grandes.
    private var amostra: Double { min(4 + model.inkWidth * 1.4, 22) }

    // MARK: - Histórico

    private var historico: some View {
        HStack(spacing: 8) {
            botao("arrow.uturn.backward", ativo: false, id: "undo",
                  desabilitado: !model.canUndo) { model.ink.undo() }
            botao("arrow.uturn.forward", ativo: false, id: "redo",
                  desabilitado: !model.canRedo) { model.ink.redo() }
        }
    }

    // MARK: - Auxiliares

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

    private func swiftUIColor(_ color: InkColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue).opacity(color.alpha)
    }

    private func inkColor(from color: Color) -> InkColor {
        let components = UIColor(color).cgColor.components ?? [0, 0, 0, 1]
        // Cinzas vêm com dois componentes (branco e alfa) em vez de quatro.
        if components.count < 4 {
            let white = Double(components.first ?? 0)
            return InkColor(red: white, green: white, blue: white,
                            alpha: Double(components.last ?? 1))
        }
        return InkColor(red: Double(components[0]), green: Double(components[1]),
                        blue: Double(components[2]), alpha: Double(components[3]))
    }
}
