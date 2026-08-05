import AppKit

/// Fila de menú que NO cierra el menú al pulsarla.
///
/// NSMenu no ofrece "mantener abierto" en su API pública. La técnica estándar
/// es un NSMenuItem con vista propia: cuando el clic lo consume la vista,
/// AppKit no dispara el cierre del menú. El precio es dibujar a mano lo que un
/// ítem normal regala — el resaltado al pasar el ratón, la marca ✓, los
/// colores según el tema — y perder la navegación por teclado en esa fila.
///
/// Se usa sólo para los INTERRUPTORES (despierto, luz del teclado, arranque,
/// idioma, registro detallado). Las acciones (apagar pantalla, abrir registro,
/// salir) siguen siendo ítems normales que cierran el menú, como debe ser.
final class StayOpenRow: NSView {

    private let highlight = NSVisualEffectView()
    private let check = NSTextField(labelWithString: "✓")
    private let label = NSTextField(labelWithString: "")

    /// Se ejecuta al hacer clic. El menú permanece abierto; quien la asigna es
    /// responsable de re-sincronizar los textos y las marcas de todo el menú.
    var onClick: (() -> Void)?

    private var hovered = false {
        didSet {
            highlight.isHidden = !hovered
            let color: NSColor = hovered ? .selectedMenuItemTextColor : .labelColor
            label.textColor = color
            check.textColor = color
        }
    }

    // Métricas de los menús modernos de macOS: alto 22, resaltado con inset
    // horizontal de 5 y esquinas de 4, texto alineado con el de los ítems
    // nativos (columna de ✓ incluida).
    private static let rowHeight: CGFloat = 22
    private static let textX: CGFloat = 28
    private static let checkX: CGFloat = 10

    init(title: String, checked: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: Self.rowHeight))
        autoresizingMask = [.width]

        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.blendingMode = .behindWindow
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.isHidden = true
        highlight.frame = bounds.insetBy(dx: 5, dy: 0)
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)

        let font = NSFont.menuFont(ofSize: 0)
        for field in [check, label] {
            field.font = font
            field.textColor = .labelColor
            field.backgroundColor = .clear
            field.isBezeled = false
            field.isEditable = false
            addSubview(field)
        }
        check.frame = NSRect(x: Self.checkX, y: 3, width: 16, height: 16)
        label.frame = NSRect(x: Self.textX, y: 3,
                             width: frame.width - Self.textX - 12, height: 16)
        label.autoresizingMask = [.width]

        configure(title: title, checked: checked)
    }

    required init?(coder: NSCoder) { fatalError("no se usa desde nib") }

    func configure(title: String, checked: Bool) {
        label.stringValue = title
        check.isHidden = !checked

        // Ancho natural, para que el menú se dimensione como con ítems
        // normales; si otro ítem es más ancho, autoresizing estira la fila.
        let needed = Self.textX + label.attributedStringValue.size().width + 16
        if needed > frame.width {
            setFrameSize(NSSize(width: needed, height: Self.rowHeight))
        }
    }

    // MARK: - Ratón

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // Parpadeo breve, como los ítems nativos al seleccionarse.
        hovered = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.hovered = true
        }
        onClick?()
    }
}
