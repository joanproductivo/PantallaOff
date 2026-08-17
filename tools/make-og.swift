// Genera las tarjetas Open Graph de la web (docs/assets/og.png y og.es.png).
//
// Se dibujan por código, igual que el icono: así la imagen que se comparte en
// redes se versiona como fuente legible y se puede retocar sin abrir ninguna
// herramienta de diseño.
//
//   swift tools/make-og.swift en docs/assets/og.png
//   swift tools/make-og.swift es docs/assets/og.es.png

import AppKit

let lang = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "en"
let outputPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2] : "docs/assets/og.png"

// Los mismos colores que el icono de la app: la web y el icono son la misma marca.
let ink      = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
let inkUp    = NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.19, alpha: 1)
let light    = NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)
let coral    = NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.38, alpha: 1)

let W: CGFloat = 1200, H: CGFloat = 630

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)

// --- Fondo ------------------------------------------------------------------
let bg = NSRect(x: 0, y: 0, width: W, height: H)
NSGradient(colors: [inkUp, ink])!.draw(in: bg, angle: -70)

// Halo coral en la esquina del portátil, para que la tarjeta no sea un plano liso.
ctx.saveGState()
NSGradient(colors: [coral.withAlphaComponent(0.22), coral.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: W * 0.80, y: H * 0.62), radius: 0,
          toCenter: NSPoint(x: W * 0.80, y: H * 0.62), radius: 420,
          options: [])
ctx.restoreGState()

// --- La marca: portátil con la pantalla apagada y la diagonal ---------------
// Mismo dibujo que tools/make-icon.swift, sobre un lienzo de 1024 escalado.
func drawMark(center: NSPoint, size s: CGFloat) {
    let u = s / 1024.0
    ctx.saveGState()
    ctx.translateBy(x: center.x - s / 2, y: center.y - s / 2)

    let lidW = 560 * u, lidH = 380 * u
    let lid = NSRect(x: (s - lidW) / 2, y: s / 2 - 90 * u, width: lidW, height: lidH)
    let lidPath = NSBezierPath(roundedRect: lid, xRadius: 26 * u, yRadius: 26 * u)
    light.setFill()
    lidPath.fill()

    let screen = lid.insetBy(dx: 30 * u, dy: 30 * u)
    ink.setFill()
    NSBezierPath(roundedRect: screen, xRadius: 10 * u, yRadius: 10 * u).fill()

    let baseY = lid.minY - 46 * u
    let base = NSBezierPath()
    base.move(to: NSPoint(x: lid.minX - 96 * u, y: baseY))
    base.line(to: NSPoint(x: lid.maxX + 96 * u, y: baseY))
    base.line(to: NSPoint(x: lid.maxX - 6 * u, y: lid.minY))
    base.line(to: NSPoint(x: lid.minX + 6 * u, y: lid.minY))
    base.close()
    light.setFill()
    base.fill()

    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: 300 * u, y: 300 * u))
    slash.line(to: NSPoint(x: 724 * u, y: 724 * u))
    slash.lineCapStyle = .round
    ink.setStroke()
    slash.lineWidth = 108 * u
    slash.stroke()
    coral.setStroke()
    slash.lineWidth = 62 * u
    slash.stroke()

    ctx.restoreGState()
}

drawMark(center: NSPoint(x: W - 250, y: H / 2 + 10), size: 380)

// --- Texto ------------------------------------------------------------------
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func draw(_ text: String, at p: NSPoint, font f: NSFont,
          color: NSColor, tracking: CGFloat = 0, width: CGFloat = 660) {
    let para = NSMutableParagraphStyle()
    para.lineHeightMultiple = 1.06
    let attrs: [NSAttributedString.Key: Any] = [
        .font: f, .foregroundColor: color,
        .kern: tracking, .paragraphStyle: para,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let box = NSRect(x: p.x, y: p.y - 400, width: width, height: 400)
    s.draw(with: box, options: [.usesLineFragmentOrigin])
}

let x: CGFloat = 88

// Etiqueta superior.
draw(lang == "es" ? "APP DE BARRA DE MENÚ · macOS" : "MENU BAR APP · macOS",
     at: NSPoint(x: x, y: H - 92), font: font(21, .semibold),
     color: coral, tracking: 2.4)

// Título.
draw("PantallaOff", at: NSPoint(x: x, y: H - 128),
     font: font(78, .bold), color: light, tracking: -1.6)

// Frase.
draw(lang == "es"
     ? "Apaga la pantalla de tu MacBook\nsin cerrar la tapa."
     : "Turn off your MacBook display\nwithout closing the lid.",
     at: NSPoint(x: x, y: H - 244), font: font(40, .medium),
     color: NSColor(calibratedWhite: 1, alpha: 0.86), tracking: -0.6)

// Pie.
draw(lang == "es"
     ? "Gratis y de código abierto · Apple Silicon · macOS 13+ · MIT"
     : "Free and open source · Apple Silicon · macOS 13+ · MIT",
     at: NSPoint(x: x, y: 104), font: font(23, .regular),
     color: NSColor(calibratedWhite: 1, alpha: 0.55), width: 720)

NSGraphicsContext.restoreGraphicsState()

// JPEG a propósito: son 1200×630 de degradado, y en PNG pesaban 750 KB — una
// tarjeta social que tarda en cargar es una tarjeta social que no se ve.
let isJPEG = outputPath.hasSuffix(".jpg") || outputPath.hasSuffix(".jpeg")
let data = isJPEG
    ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    : rep.representation(using: .png, properties: [:])
guard let data else {
    FileHandle.standardError.write("no se pudo codificar la imagen\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outputPath))
print("escrito \(outputPath)")
