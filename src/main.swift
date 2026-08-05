import AppKit

// Diagnóstico del arranque automático, sin abrir la interfaz. Útil para
// distinguir "la API no está disponible para esta firma" de "el usuario no lo
// ha activado", que desde el menú se ven igual.
if CommandLine.arguments.contains("--login-item-diag") {
    print("bundle:     \(Bundle.main.bundlePath)")
    print("bundle id:  \(Bundle.main.bundleIdentifier ?? "(ninguno)")")
    print("estado:     \(LoginItem.state)")
    if let problem = LoginItem.setEnabled(true) {
        print("register(): FALLA -> \(problem)")
    } else {
        print("register(): OK -> estado ahora \(LoginItem.state)")
        _ = LoginItem.setEnabled(false)
        print("            revertido a \(LoginItem.state)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--kb-diag") {
    print("idioma actual: \(L10n.current.rawValue) (sistema: \(L10n.systemDefault.rawValue))")
    print("teclado disponible: \(KeyboardLight.available)")
    print("encendida: \(KeyboardLight.isOn)")
    print(KeyboardLight.diagnosticReport())
    exit(0)
}

// .accessory = sin icono en el Dock. Se hace en código y no sólo con
// LSUIElement en el Info.plist para que el binario también funcione
// correctamente sin empaquetar (durante el desarrollo).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
