import CoreGraphics
import Foundation

/// Cor de um traço, independente de UIKit para o modelo continuar testável fora de um app.
public struct InkColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = InkColor(red: 0, green: 0, blue: 0)
}

/// Uma amostra do traço, com tudo o que a Apple Pencil informa naquele instante.
///
/// Guardar os atributos brutos — e não só a posição — é o que permite a espessura variar
/// ponto a ponto e o traço ser regerado depois em qualquer escala.
public struct InkPoint: Codable, Sendable, Equatable {
    public var location: CGPoint
    /// 0…1. Um toque sem força relatada assume pressão neutra: força zero produziria
    /// traço invisível.
    public var force: Double
    /// Radianos. Perto de π/2 a caneta está em pé; perto de 0, deitada.
    public var altitude: Double
    public var azimuth: Double
    /// Rotação em torno do próprio eixo (Apple Pencil Pro).
    public var roll: Double

    public init(location: CGPoint, force: Double,
                altitude: Double = .pi / 2, azimuth: Double = 0, roll: Double = 0) {
        self.location = location
        self.force = force > 0 ? min(force, 1) : Self.neutralForce
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
    }

    /// Usada quando o dispositivo não informa força — o dedo, ou a Pencil antes de a
    /// estimativa chegar por Bluetooth.
    public static let neutralForce: Double = 0.5
}

/// Um traço contínuo, do encostar ao levantar da caneta.
public struct InkStroke: Codable, Sendable, Equatable {
    public var points: [InkPoint]
    public var color: InkColor
    /// Espessura de referência; a pressão modula em torno dela.
    public var baseWidth: Double

    public init(points: [InkPoint], color: InkColor, baseWidth: Double) {
        self.points = points
        self.color = color
        self.baseWidth = baseWidth
    }

    public var isEmpty: Bool { points.isEmpty }

    /// Área ocupada, já contando a espessura — a caixa dos pontos sozinha cortaria as
    /// bordas do traço, porque ela acompanha o centro da linha.
    public var bounds: CGRect {
        guard let first = points.first else { return .null }

        var minX = first.location.x, maxX = first.location.x
        var minY = first.location.y, maxY = first.location.y
        for point in points.dropFirst() {
            minX = min(minX, point.location.x); maxX = max(maxX, point.location.x)
            minY = min(minY, point.location.y); maxY = max(maxY, point.location.y)
        }

        let margin = baseWidth
        return CGRect(x: minX - margin, y: minY - margin,
                      width: (maxX - minX) + margin * 2,
                      height: (maxY - minY) + margin * 2)
    }
}

/// Os traços de uma página, com histórico de desfazer.
public struct InkDrawing: Codable, Sendable, Equatable {
    public private(set) var strokes: [InkStroke] = []

    /// Fora do `Codable`: o histórico é da sessão, o que se guarda são os traços.
    private var undone: [InkStroke] = []
    /// Distingue "desfazer o traço que fiz" de "desfazer o apagamento que fiz".
    private var lastActionWasRemoval = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case strokes }

    public mutating func append(_ stroke: InkStroke) {
        guard !stroke.isEmpty else { return }
        strokes.append(stroke)
        // Traço novo encerra a linha do tempo alternativa, como em qualquer editor.
        undone.removeAll()
        snapshots.removeAll()
        lastActionWasRemoval = false
    }

    /// Também é possível desfazer logo após apagar, mesmo sem traços restantes.
    public var canUndo: Bool { !strokes.isEmpty || !undone.isEmpty || !snapshots.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }

    public mutating func undo() {
        // Um apagamento é desfeito restaurando o estado anterior inteiro: os traços
        // atingidos voltam como eram, não como pedaços.
        if let previous = snapshots.popLast() {
            strokes = previous
            return
        }
        // Depois de remover um traço inteiro, desfazer o traz de volta.
        if lastActionWasRemoval, let restored = undone.popLast() {
            strokes.append(restored)
            lastActionWasRemoval = false
            return
        }
        guard let last = strokes.popLast() else { return }
        undone.append(last)
    }

    public mutating func redo() {
        guard let last = undone.popLast() else { return }
        strokes.append(last)
    }

    /// Apaga um traço, mantendo-o no histórico para poder ser restaurado.
    public mutating func remove(at index: Int) {
        guard strokes.indices.contains(index) else { return }
        let removed = strokes.remove(at: index)
        undone.append(removed)
        lastActionWasRemoval = true
    }

    /// Apaga o que passou sob a borracha, partindo os traços atingidos.
    ///
    /// Guarda o estado anterior inteiro para que desfazer restaure os traços originais,
    /// e não os pedaços.
    public mutating func erase(at location: CGPoint, radius: Double) {
        var changed = false
        var result: [InkStroke] = []

        for stroke in strokes {
            let pieces = InkPath.erase(stroke, at: location, radius: radius)
            if pieces.count != 1 || pieces[0].points.count != stroke.points.count {
                changed = true
            }
            result.append(contentsOf: pieces)
        }

        guard changed else { return }
        snapshots.append(strokes)
        strokes = result
        undone.removeAll()
        lastActionWasRemoval = false
    }

    /// Estados anteriores a apagamentos, para desfazer restaurar o traço original.
    private var snapshots: [[InkStroke]] = []

    public mutating func removeAll() {
        strokes.removeAll()
        undone.removeAll()
        snapshots.removeAll()
        lastActionWasRemoval = false
    }
}
