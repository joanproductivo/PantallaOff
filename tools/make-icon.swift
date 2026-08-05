// Genera el icono de PantallaOff y lo empaqueta en un .icns.
//
// Se dibuja por código a propósito: así el icono se versiona como fuente
// legible en vez de como un binario opaco, y se puede retocar sin abrir
// ninguna herramienta de diseño.
//
//   swift tools/make-icon.swift resources/AppIcon.icns
//
// Diseño: un MacBook visto de frente con la pantalla apagada, cruzada por una
// barra diagonal. La silueta del portátil aguanta a 16 px, y la diagonal es lo
// que se sigue leyendo cuando el resto ya es una mancha.

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "resources/AppIcon.icns"

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    let u = size / 1024.0   // todo se define sobre un lienzo de 1024

    // A tamaños pequeños el detalle se empasta: se dibuja una variante más
    // rotunda —menos margen, marco más fino, diagonal más gruesa— igual que
    // hace Apple con sus propios iconos. Sin esto, a 32 px sólo se ve una
    // mancha.
    let compact = size <= 64

    // --- Fondo: squircle con el margen que pide macOS -----------------------
    let inset: CGFloat = (compact ? 40 : 100) * u
    let bg = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: 185 * u, yRadius: 185 * u)

    ctx.saveGState()
    bgPath.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)
    ctx.restoreGState()

    // Borde tenue: despega el icono de fondos oscuros.
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    bgPath.lineWidth = 3 * u
    bgPath.stroke()

    // --- Portátil ------------------------------------------------------------
    let light = NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)
    let dark  = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)

    // Carcasa de la pantalla.
    let lidW = (compact ? 680 : 560) * u, lidH = (compact ? 460 : 380) * u
    let lid = NSRect(x: (size - lidW) / 2, y: size / 2 - (compact ? 130 : 90) * u,
                     width: lidW, height: lidH)
    let lidPath = NSBezierPath(roundedRect: lid, xRadius: 26 * u, yRadius: 26 * u)
    light.setFill()
    lidPath.fill()

    // Panel: apagado, que es de lo que va la app.
    let bezel = (compact ? 44 : 30) * u
    let screen = lid.insetBy(dx: bezel, dy: bezel)
    dark.setFill()
    NSBezierPath(roundedRect: screen, xRadius: 10 * u, yRadius: 10 * u).fill()

    // Base: trapecio, para que se lea "portátil" y no "monitor".
    let baseY = lid.minY - (compact ? 60 : 46) * u
    let base = NSBezierPath()
    base.move(to: NSPoint(x: lid.minX - (compact ? 110 : 96) * u, y: baseY))
    base.line(to: NSPoint(x: lid.maxX + (compact ? 110 : 96) * u, y: baseY))
    base.line(to: NSPoint(x: lid.maxX - 6 * u,  y: lid.minY))
    base.line(to: NSPoint(x: lid.minX + 6 * u,  y: lid.minY))
    base.close()
    light.setFill()
    base.fill()

    // --- Barra diagonal ------------------------------------------------------
    // Lo único que sobrevive a 16 px. Se dibuja con un hueco oscuro por debajo
    // para que se separe del portátil sea cual sea el fondo.
    let slash = NSBezierPath()
    let a = (compact ? 250.0 : 300.0) * u, b = (compact ? 774.0 : 724.0) * u
    slash.move(to: NSPoint(x: a, y: a))
    slash.line(to: NSPoint(x: b, y: b))
    slash.lineCapStyle = .round

    dark.setStroke()
    slash.lineWidth = (compact ? 150 : 108) * u
    slash.stroke()

    NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.38, alpha: 1).setStroke()
    slash.lineWidth = (compact ? 96 : 62) * u
    slash.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// --- Construir el .iconset y convertirlo -----------------------------------

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("PantallaOff.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// (tamaño en puntos, escala) -> nombre que espera iconutil
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2),
                              (128, 1), (128, 2), (256, 1), (256, 2),
                              (512, 1), (512, 2)]

for (points, scale) in variants {
    let pixels = points * scale
    let rep = drawIcon(size: CGFloat(pixels))
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! png.write(to: tmp.appendingPathComponent(name))
}

let out = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", out.path]
try! task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("icono generado: \(out.path)")
} else {
    print("iconutil falló con estado \(task.terminationStatus)")
    exit(1)
}
