import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let control = DisplayControl.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        control.startWatchdog { [weak self] in self?.refresh() }

        // Reconciliación al arrancar: si consta algo apagado pero en realidad
        // todo está online y activo (p.ej. hubo un reinicio, que descarta la
        // configuración), el fichero de estado está obsoleto.
        reconcileStaleState()
        refresh()

        let loginState: String
        switch LoginItem.state {
        case .enabled:          loginState = "activado"
        case .disabled:         loginState = "desactivado"
        case .requiresApproval: loginState = "requiere aprobación en Ajustes"
        case .unsupported(let why): loginState = "no disponible (\(why))"
        }
        control.write("PantallaOff arrancada desde \(Bundle.main.bundlePath) "
                      + "| arranque al inicio: \(loginState)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Las assertions de energía mueren con el proceso, pero soltarlas
        // explícitamente evita dejar una entrada fantasma en `pmset -g assertions`.
        KeepAwake.set(enabled: false, includeDisplay: false)

        // Con kCGConfigureForAppOnly el sistema ya revierte al terminar, pero no
        // se depende de eso: encender explícitamente es barato e idempotente.
        if !control.disabledByUs().isEmpty {
            control.write("saliendo: reactivando pantallas")
            control.turnOnAllBlocking()
        }
    }

    private func reconcileStaleState() {
        let disabled = control.disabledByUs()
        guard !disabled.isEmpty else { return }

        var online = [CGDirectDisplayID](repeating: 0, count: Int(PC_MAX_DISPLAYS))
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(PC_MAX_DISPLAYS), &online, &n) == .success else { return }
        let onlineSet = Set(online.prefix(Int(n)))

        for id in disabled where onlineSet.contains(id) {
            control.write("estado obsoleto: \(id) vuelve a estar online, limpiando")
            pc_state_remove(id)
        }
    }

    // MARK: - UI

    private func refresh() {
        guard let button = statusItem.button else { return }
        let state = control.builtInState()
        let symbol: String
        switch state {
        case .offByUs:       symbol = "laptopcomputer.slash"
        case .mirroredSlave: symbol = "rectangle.on.rectangle"
        case .mirrorMaster:  symbol = "rectangle.on.rectangle"
        case .on:            symbol = "laptopcomputer"
        case .missing:       symbol = "exclamationmark.triangle"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PantallaOff") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = state == .offByUs ? "◻︎" : "◼︎"
        }
        var tip = describe(state)
        if KeepAwake.isOn {
            tip += KeepAwake.keepsDisplayOn
                ? "\nDespierto, con la pantalla encendida"
                : "\nManteniendo el Mac despierto"
        }
        button.toolTip = tip
    }

    private func describe(_ state: BuiltInState) -> String {
        switch state {
        case .on:            return "Pantalla del MacBook: encendida"
        case .mirroredSlave: return "Pantalla del MacBook: encendida, mostrando un espejo"
        case .mirrorMaster:  return "Pantalla del MacBook: encendida, y es la fuente del espejo"
        case .offByUs:       return "Pantalla del MacBook: apagada por PantallaOff"
        case .missing:       return "Pantalla del MacBook: no encontrada"
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let state = control.builtInState()

        let header = NSMenuItem(title: describe(state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let externals = control.usableExternalCount
        let sub = NSMenuItem(
            title: "Pantallas externas utilizables: \(externals)",
            action: nil, keyEquivalent: "")
        sub.isEnabled = false
        menu.addItem(sub)
        menu.addItem(.separator())

        if state == .offByUs {
            menu.addItem(item("Encender pantalla del MacBook",
                              #selector(turnOn), enabled: true))
        } else {
            let check = control.canDisableBuiltIn()
            let title = check.allowed
                ? "Apagar pantalla del MacBook"
                : "No se puede apagar — \(check.reason)"
            menu.addItem(item(title, #selector(turnOff), enabled: check.allowed))

            // Camino explícito para el caso "la interna es la fuente del espejo".
            if control.builtInIsMirrorMaster {
                menu.addItem(item("Romper el espejo (la interna es la fuente)",
                                  #selector(breakMirror), enabled: true))
            }
        }

        menu.addItem(.separator())

        // Mantener despierto: un interruptor y su matiz, nada más.
        let awake = item("Mantener el Mac despierto", #selector(toggleKeepAwake), enabled: true)
        awake.state = KeepAwake.isOn ? .on : .off
        menu.addItem(awake)
        if KeepAwake.isOn {
            let disp = item("      …y la pantalla encendida",
                            #selector(toggleKeepDisplay), enabled: true)
            disp.state = KeepAwake.keepsDisplayOn ? .on : .off
            menu.addItem(disp)
        }

        menu.addItem(.separator())

        // Arranque al iniciar sesión. Seguro porque la app nunca apaga nada
        // por su cuenta (P1): arrancar sola sólo pone el icono en la barra.
        let login = LoginItem.state
        switch login {
        case .enabled, .disabled:
            let li = item("Abrir al iniciar sesión", #selector(toggleLoginItem), enabled: true)
            li.state = login.isOn ? .on : .off
            menu.addItem(li)
        case .requiresApproval:
            let li = item("Abrir al iniciar sesión — desactivado en Ajustes",
                          #selector(openLoginItemsSettings), enabled: true)
            li.state = .off
            menu.addItem(li)
        case .unsupported(let why):
            menu.addItem(item("Abrir al iniciar sesión — \(why)", #selector(quit), enabled: false))
        }

        // Diagnóstico: sólo con ⌥ pulsada al abrir el menú.
        //
        // Ninguna de estas dos cosas hace falta en el uso normal. "Forzar
        // reactivación" ejecuta la misma acción que "Encender pantalla del
        // MacBook" —la app sólo apaga una pantalla— y sólo se distingue cuando
        // el estado quedó inconsistente, p. ej. tras un selftest interrumpido.
        // El registro sólo interesa cuando algo va mal.
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(.separator())
            let head = NSMenuItem(title: "Diagnóstico", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            menu.addItem(item("Abrir el registro", #selector(openLog), enabled: true))
            let verbose = item("Registro detallado", #selector(toggleVerboseLog), enabled: true)
            verbose.state = DisplayControl.verboseLogging ? .on : .off
            menu.addItem(verbose)
            menu.addItem(item("Forzar reactivación de todas las pantallas",
                              #selector(turnOn), enabled: true))
        }

        menu.addItem(.separator())
        menu.addItem(item("Salir de PantallaOff", #selector(quit), enabled: true))
        return menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        i.target = self
        i.isEnabled = enabled
        return i
    }

    // MARK: - Acciones

    @objc private func turnOff() {
        control.turnOffBuiltIn { [weak self] result in
            if case .failure(let err) = result {
                self?.alert("No se ha apagado la pantalla", err.localizedDescription)
            }
            self?.refresh()
        }
    }

    @objc private func turnOn() {
        control.turnOnAll { [weak self] ok in
            if !ok {
                self?.alert("Atención",
                    "No se ha podido reactivar ninguna pantalla.\n\n"
                    + "Ejecuta ~/rescue desde una terminal o por SSH. Si eso no "
                    + "basta: ~/rescue --restore")
            }
            self?.refresh()
        }
    }

    @objc private func breakMirror() {
        control.breakMirror { [weak self] ok in
            if !ok {
                self?.alert("No se ha podido romper el espejo",
                    "Desactiva la duplicación desde Ajustes del Sistema → Pantallas.")
            }
            self?.refresh()
        }
    }

    @objc private func toggleKeepAwake() {
        let turningOn = !KeepAwake.isOn
        if let problem = KeepAwake.set(enabled: turningOn,
                                       includeDisplay: KeepAwake.keepsDisplayOn) {
            alert("Mantener despierto", problem)
        } else {
            control.write("mantener despierto: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    @objc private func toggleKeepDisplay() {
        let turningOn = !KeepAwake.keepsDisplayOn
        if let problem = KeepAwake.adjustDisplay(turningOn) {
            alert("Mantener la pantalla encendida", problem)
        } else {
            control.write("mantener pantalla encendida: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    @objc private func toggleLoginItem() {
        let turningOn = !LoginItem.state.isOn
        if let problem = LoginItem.setEnabled(turningOn) {
            alert("Arranque automático", problem)
        } else {
            control.write("arranque al iniciar sesión: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    @objc private func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleVerboseLog() {
        DisplayControl.verboseLogging.toggle()
        control.write("registro detallado: \(DisplayControl.verboseLogging ? "activado" : "desactivado")")
        refresh()
    }

    @objc private func openLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PantallaOff.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    // Se reconstruye en cada apertura: el estado puede haber cambiado por el
    // watchdog, por un hot-plug o por el propio sistema.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
        for item in menu.items { item.target = self }
    }
}
