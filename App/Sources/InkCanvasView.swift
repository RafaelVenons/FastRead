import FastReadCore
import UIKit

/// Onde a tinta é desenhada, sobre uma página do PDF.
///
/// Renderiza com `CAShapeLayer`, que é vetorial e acelerado por hardware: o traço
/// permanece nítido em qualquer zoom porque nunca é rasterizado numa resolução fixa.
/// Foi o motivo de abandonar o `PKCanvasView`, que rasteriza na resolução da página e
/// borra ao ampliar.
final class InkCanvasView: UIView {

    /// Traços já concluídos. Trocar redesenha a camada inteira.
    var drawing = InkDrawing() {
        didSet { rebuildLayers() }
    }

    enum Tool { case pen, eraser }

    var tool: Tool = .pen
    var color: InkColor = .black
    var baseWidth: Double = 3

    /// Chamado quando um traço termina, para o modelo e o disco acompanharem.
    var onStrokeFinished: ((InkStroke) -> Void)?

    /// Fora do modo de desenho a camada precisa deixar o toque passar, senão não dá mais
    /// para tocar num parágrafo e ouvi-lo.
    var isDrawingEnabled = false {
        didSet { isUserInteractionEnabled = isDrawingEnabled }
    }

    /// Só a Pencil desenha; o dedo continua rolando e tocando para ler.
    var acceptsFingerInput = false

    private var finishedLayers: [CAShapeLayer] = []
    /// O traço em andamento vive em dois layers: a parte já consolidada, que não muda
    /// mais, e a cauda, a única recalculada a cada quadro. Sem essa divisão a latência
    /// cresce com o tamanho do traço.
    private let settledLayer = CAShapeLayer()
    private let activeLayer = CAShapeLayer()
    /// Quantos pontos recentes são regerados por quadro.
    private let tailLength = 24
    private var activePoints: [InkPoint] = []
    /// Toques previstos entram e saem a cada frame — ficam fora do traço definitivo.
    private var predictedCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = false
        accessibilityIdentifier = "inkCanvas"

        for shape in [settledLayer, activeLayer] {
            shape.fillColor = UIColor.black.cgColor
            shape.strokeColor = nil
            layer.addSublayer(shape)
        }
    }

    // MARK: - Captura

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = usableTouch(touches) else {
            super.touchesBegan(touches, with: event)
            return
        }
        if tool == .eraser {
            erase(at: touch.location(in: self))
            return
        }
        activePoints = [inkPoint(from: touch)]
        predictedCount = 0
        redrawActive()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = usableTouch(touches) else {
            super.touchesMoved(touches, with: event)
            return
        }
        if tool == .eraser {
            erase(at: touch.location(in: self))
            return
        }
        guard !activePoints.isEmpty else { return }

        // Descarta a previsão do frame anterior antes de acrescentar a nova.
        if predictedCount > 0 {
            activePoints.removeLast(predictedCount)
            predictedCount = 0
        }

        // Todos os pontos entre frames, não só o último: sem isto o traço fica
        // poligonal em movimentos rápidos.
        for coalesced in event?.coalescedTouches(for: touch) ?? [touch] {
            activePoints.append(inkPoint(from: coalesced))
        }

        // Previstos compensam a latência; saem no próximo frame ou ao levantar.
        let predicted = event?.predictedTouches(for: touch) ?? []
        activePoints.append(contentsOf: predicted.map(inkPoint(from:)))
        predictedCount = predicted.count

        redrawActive()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tool == .pen else { return }
        finishStroke()
    }

    /// Apaga o traço sob o ponto — inteiro, não em pedaços: é o que se espera de uma
    /// borracha de anotação, e apagar parcialmente exigiria recortar a geometria.
    private func erase(at location: CGPoint) {
        guard let index = InkPath.strokeIndex(at: location, in: drawing.strokes,
                                              tolerance: eraserTolerance) else { return }
        drawing.remove(at: index)
        onStrokeFinished?(InkStroke(points: [], color: color, baseWidth: baseWidth))
    }

    private let eraserTolerance: Double = 10

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activePoints.removeAll()
        predictedCount = 0
        settledCount = 0
        activeLayer.path = nil
        settledLayer.path = nil
    }

    /// A Pencil envia força e ângulos definitivos depois, por Bluetooth; sem isto o
    /// começo do traço fica com valores estimados.
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        redrawActive()
    }

    private func usableTouch(_ touches: Set<UITouch>) -> UITouch? {
        touches.first { $0.type == .pencil || acceptsFingerInput }
    }

    private func inkPoint(from touch: UITouch) -> InkPoint {
        InkPoint(location: touch.location(in: self),
                 force: touch.type == .pencil ? Double(touch.force / max(touch.maximumPossibleForce, 1))
                                              : InkPoint.neutralForce,
                 altitude: Double(touch.altitudeAngle),
                 azimuth: Double(touch.azimuthAngle(in: self)),
                 // Rotação em torno do eixo só existe na Pencil Pro, a partir do iOS 17.5.
                 roll: rollAngle(of: touch))
    }

    private func rollAngle(of touch: UITouch) -> Double {
        if #available(iOS 17.5, *) { return Double(touch.rollAngle) }
        return 0
    }

    // MARK: - Renderização

    private func redrawActive() {
        guard !activePoints.isEmpty else {
            activeLayer.path = nil
            settledLayer.path = nil
            return
        }

        let split = InkPath.split(activePoints, tailLength: tailLength)
        let fill = cgColor(color)

        // Sem animação implícita: o traço deve acompanhar a caneta, não deslizar até ela.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // A parte consolidada só muda quando a cauda avança — regerá-la a cada quadro é
        // justamente o que fazia a latência crescer com o traço.
        if split.settled.count != settledCount {
            settledCount = split.settled.count
            settledLayer.fillColor = fill
            settledLayer.path = split.settled.isEmpty
                ? nil
                : InkPath.outline(of: InkStroke(points: split.settled, color: color, baseWidth: baseWidth))
        }

        activeLayer.fillColor = fill
        activeLayer.path = InkPath.outline(of: InkStroke(points: split.tail, color: color, baseWidth: baseWidth))

        CATransaction.commit()
    }

    private var settledCount = 0

    private func finishStroke() {
        defer {
            activePoints.removeAll()
            predictedCount = 0
            settledCount = 0
            activeLayer.path = nil
            settledLayer.path = nil
        }
        // A previsão não é traço de verdade; sai antes de gravar.
        if predictedCount > 0, activePoints.count > predictedCount {
            activePoints.removeLast(predictedCount)
        }
        guard activePoints.count > 0 else { return }

        let stroke = InkStroke(points: activePoints, color: color, baseWidth: baseWidth)
        drawing.append(stroke)
        onStrokeFinished?(stroke)
    }

    /// Um layer por traço: acrescentar um não obriga a redesenhar os anteriores.
    private func rebuildLayers() {
        finishedLayers.forEach { $0.removeFromSuperlayer() }
        finishedLayers = drawing.strokes.compactMap { stroke in
            guard let path = InkPath.outline(of: stroke) else { return nil }
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = cgColor(stroke.color)
            shape.strokeColor = nil
            layer.insertSublayer(shape, below: settledLayer)
            return shape
        }
    }

    private func cgColor(_ color: InkColor) -> CGColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha).cgColor
    }
}
