import AppKit
import CoreGraphics
import Foundation

// FastRead — as linhas de texto se dissolvem em onda sonora: o texto virando fala, que é
// o que o app faz. A linha acesa é a que está sendo lida.

let S = 1024.0
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// fundo azul-noite, diagonal
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.14, green: 0.18, blue: 0.42, alpha: 1),
                                   CGColor(red: 0.04, green: 0.05, blue: 0.15, alpha: 1)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

let ink = CGColor(red: 1.0, green: 0.80, blue: 0.24, alpha: 1)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let left = 172.0
let right = 852.0
let waveStart = left + (right - left) * 0.46
let spacing = 146.0
let lines = 5
let middle = lines / 2

for index in 0..<lines {
    let y = S / 2 + Double(middle - index) * spacing
    let isMiddle = index == middle

    ctx.setStrokeColor(isMiddle ? ink : CGColor(red: 1, green: 1, blue: 1, alpha: 0.26))
    ctx.setLineWidth(isMiddle ? 44 : 32)

    // Um único caminho do começo ao fim: desenhar o trecho reto e o ondulado em dois
    // traços deixava um ponto visível na emenda, por causa da tampa redonda.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left, y: y))
    path.addLine(to: CGPoint(x: waveStart, y: y))

    var x = waveStart
    while x <= right {
        let progress = (x - waveStart) / (right - waveStart)
        // A amplitude cresce ao sair do texto: a linha se solta em som aos poucos.
        let amplitude = (isMiddle ? 78.0 : 40.0) * progress
        path.addLine(to: CGPoint(x: x, y: y + sin(progress * .pi * 2.2) * amplitude))
        x += 3
    }

    ctx.addPath(path)
    ctx.strokePath()
}

let image = ctx.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ícone final gerado")
