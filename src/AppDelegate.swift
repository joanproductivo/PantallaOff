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
        KeyboardLight.reconcile()
        refresh()

        let loginState: String
        switch LoginItem.state {
        case .enabled:          loginState = "activado"
        case .disabled:         loginState = "desactivado"
        case .requiresApproval: loginState = "requiere aprobación en Ajustes"
        case .unsupported: loginState = "no disponible"   // el motivo va traducido: fuera del log
        }
        control.write("PantallaOff arrancada desde \(Bundle.main.bundlePath) "
                      + "| arranque al inicio: \(loginState)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Las assertions de energía mueren con el proceso, pero soltarlas
        // explícitamente evita dejar una entrada fantasma en `pmset -g assertions`.
        KeepAwake.set(enabled: false, includeDisplay: false)

        // La luz del teclado NO muere con el proceso: si la dejáramos apagada,
        // el auto-brillo del sistema quedaría desactivado a espaldas del usuario
        // de forma indefinida. Se restaura, igual que las pantallas.
        KeyboardLight.restoreOnQuit()

        // MEDIDO: kCGConfigureForAppOnly NO revierte el bit 'enabled' ni
        // siquiera en una salida limpia. Este encendido explícito es la única
        // reversión real al salir.
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
            tip += "\n" + (KeepAwake.keepsDisplayOn
                ? L10n.t.tipAwakeWithDisplay
                : L10n.t.tipAwake)
        }
        button.toolTip = tip
    }

    private func describe(_ state: BuiltInState) -> String {
        switch state {
        case .on:            return L10n.t.stateOn
        case .mirroredSlave: return L10n.t.stateMirroredSlave
        case .mirrorMaster:  return L10n.t.stateMirrorMaster
        case .offByUs:       return L10n.t.stateOffByUs
        case .missing:       return L10n.t.stateMissing
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let state = control.builtInState()

        // Reconciliar antes de dibujar: si el usuario re-encendió la luz con
        // las teclas F, hay que devolverle el auto-brillo ya, no esperar al
        // próximo arranque de la app.
        KeyboardLight.reconcile()

        // El menú empieza directamente por la acción. El estado no hace falta
        // escribirlo: el propio interruptor ya dice si toca apagar o encender,
        // y cuando no se puede, lo dice con el motivo. Lo demás va a
        // Diagnóstico, bajo ⌥.
        let s = L10n.t
        if state == .offByUs {
            menu.addItem(item(s.turnOnDisplay, #selector(turnOn), enabled: true))
        } else {
            let check = control.canDisableBuiltIn()
            let title = check.allowed ? s.turnOffDisplay : s.cannotTurnOff(check.reason)
            menu.addItem(item(title, #selector(turnOff), enabled: check.allowed))

            // Camino explícito para el caso "la interna es la fuente del espejo".
            if control.builtInIsMirrorMaster {
                menu.addItem(item(s.breakMirror, #selector(breakMirror), enabled: true))
            }
        }

        menu.addItem(.separator())

        // Mantener despierto: un interruptor y su matiz, nada más.
        let awake = item(s.keepAwake, #selector(toggleKeepAwake), enabled: true)
        awake.state = KeepAwake.isOn ? .on : .off
        menu.addItem(awake)
        if KeepAwake.isOn {
            let disp = item(s.keepDisplayOn, #selector(toggleKeepDisplay), enabled: true)
            disp.state = KeepAwake.keepsDisplayOn ? .on : .off
            menu.addItem(disp)
        }

        // Luz del teclado: sólo si este Mac tiene teclado retroiluminado.
        // Título por lectura en vivo, para que refleje la realidad aunque el
        // usuario la haya cambiado con las teclas de brillo.
        if KeyboardLight.available {
            let lightOn = KeyboardLight.isOn
            menu.addItem(item(lightOn ? s.keyboardLightOff : s.keyboardLightOn,
                              #selector(toggleKeyboardLight), enabled: true))
        }

        menu.addItem(.separator())

        // Arranque al iniciar sesión. Seguro porque la app nunca apaga nada
        // por su cuenta (P1): arrancar sola sólo pone el icono en la barra.
        let login = LoginItem.state
        switch login {
        case .enabled, .disabled:
            let li = item(s.openAtLogin, #selector(toggleLoginItem), enabled: true)
            li.state = login.isOn ? .on : .off
            menu.addItem(li)
        case .requiresApproval:
            let li = item(s.openAtLoginDisabledInSettings,
                          #selector(openLoginItemsSettings), enabled: true)
            li.state = .off
            menu.addItem(li)
        case .unsupported(let why):
            menu.addItem(item(s.openAtLoginUnavailable(why), #selector(quit), enabled: false))
        }

        // Diagnóstico: sólo con ⌥ pulsada al abrir el menú.
        //
        // Nada de esto hace falta en el uso normal: el estado ya lo cuenta el
        // propio interruptor, "Forzar reactivación" ejecuta la misma acción que
        // "Encender pantalla del MacBook" (sólo se distingue con el estado
        // inconsistente, p. ej. tras un selftest interrumpido), y el registro
        // sólo interesa cuando algo va mal.
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(.separator())
            let head = NSMenuItem(title: s.diagnostics, action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)

            for line in [describe(state),
                         s.usableExternals(control.usableExternalCount)] {
                let info = NSMenuItem(title: "  \(line)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }

            menu.addItem(item(s.openLog, #selector(openLog), enabled: true))
            let verbose = item(s.verboseLog, #selector(toggleVerboseLog), enabled: true)
            verbose.state = DisplayControl.verboseLogging ? .on : .off
            menu.addItem(verbose)
            menu.addItem(item(s.forceReenable, #selector(turnOn), enabled: true))
        }

        menu.addItem(.separator())
        menu.addItem(item(s.quit, #selector(quit), enabled: true))

        // Idioma DESPUÉS de Salir, como se pidió. (La convención de macOS pone
        // Salir al final; aquí manda la petición.)
        let langItem = NSMenuItem(title: s.languageMenu, action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in Lang.allCases {
            let li = item(lang.displayName, #selector(chooseLanguage(_:)), enabled: true)
            li.state = (L10n.current == lang) ? .on : .off
            li.representedObject = lang.rawValue
            langMenu.addItem(li)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
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
                self?.alert(L10n.t.alertTurnOffFailedTitle, err.localizedDescription)
            }
            self?.refresh()
        }
    }

    @objc private func turnOn() {
        control.turnOnAll { [weak self] ok in
            if !ok {
                self?.alert(L10n.t.alertAttentionTitle, L10n.t.alertRescueFailed)
            }
            self?.refresh()
        }
    }

    @objc private func breakMirror() {
        control.breakMirror { [weak self] ok in
            if !ok {
                self?.alert(L10n.t.alertBreakMirrorFailedTitle,
                            L10n.t.alertBreakMirrorFailedBody)
            }
            self?.refresh()
        }
    }

    @objc private func toggleKeepAwake() {
        let turningOn = !KeepAwake.isOn
        if let problem = KeepAwake.set(enabled: turningOn,
                                       includeDisplay: KeepAwake.keepsDisplayOn) {
            alert(L10n.t.keepAwake, problem)
        } else {
            control.write("mantener despierto: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    @objc private func toggleKeepDisplay() {
        let turningOn = !KeepAwake.keepsDisplayOn
        if let problem = KeepAwake.adjustDisplay(turningOn) {
            alert(L10n.t.alertKeepDisplayTitle, problem)
        } else {
            control.write("mantener pantalla encendida: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    @objc private func toggleLoginItem() {
        let turningOn = !LoginItem.state.isOn
        if let problem = LoginItem.setEnabled(turningOn) {
            alert(L10n.t.alertLoginItemTitle, problem)
        } else {
            control.write("arranque al iniciar sesión: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    @objc private func toggleKeyboardLight() {
        let turningOff = KeyboardLight.isOn
        let ok = turningOff ? KeyboardLight.turnOff() : KeyboardLight.turnOn()
        if ok {
            control.write("luz del teclado: \(turningOff ? "apagada" : "encendida")")
        } else {
            alert(L10n.t.alertKeyboardTitle, L10n.t.keyboardLightFailed)
        }
        refresh()
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = Lang(rawValue: raw) else { return }
        L10n.current = lang
        control.write("idioma: \(raw)")
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
        // Se puebla el menú vivo con los ítems frescos, SIN copiarlos.
        // La versión anterior hacía item.copy() y re-asignaba el target sólo en
        // el nivel superior: con el submenú de idioma, sus ítems se habrían
        // quedado sin target. Como buildMenu() ya crea ítems nuevos en cada
        // llamada, la copia no aportaba nada.
        menu.removeAllItems()
        for item in buildMenu().items {
            // item.menu, no item.parent: `parent` es el ítem que contiene un
            // submenú y vale nil en el nivel superior, así que no protegía de
            // nada. Hoy funciona porque el menú temporal ya está liberado
            // cuando llegamos aquí, pero eso es un detalle de ARC, no una
            // garantía. Con esto sí lo es.
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}
