import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let control = DisplayControl.shared

    /// Referencias a los elementos del menú vivo, para poder re-sincronizar
    /// títulos, marcas y presencia SIN cerrar el menú: los interruptores usan
    /// StayOpenRow, y tras cada clic hay que actualizar el resto in situ (el
    /// menú ya no se reconstruye entre clic y clic, sólo entre aperturas).
    private struct MenuRefs {
        weak var menu: NSMenu?
        var displayItem: NSMenuItem?
        var breakMirrorItem: NSMenuItem?
        var awakeItem: NSMenuItem?
        var awakeRow: StayOpenRow?
        var keepDisplayItem: NSMenuItem?
        var keepDisplayRow: StayOpenRow?
        var kbRow: StayOpenRow?
        var loginRow: StayOpenRow?
        var verboseRow: StayOpenRow?
        var diagHead: NSMenuItem?
        var diagState: NSMenuItem?
        var diagExternals: NSMenuItem?
        var openLogItem: NSMenuItem?
        var forceItem: NSMenuItem?
        var quitItem: NSMenuItem?
        var langItem: NSMenuItem?
        var langRows: [(Lang, StayOpenRow)] = []
    }
    private var refs = MenuRefs()

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
        syncOpenMenu()

        guard let button = statusItem?.button else { return }
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

    // MARK: - Construcción del menú

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        refs = MenuRefs()
        refs.menu = menu
        let state = control.builtInState()

        // Reconciliar antes de dibujar: si el usuario re-encendió la luz con
        // las teclas F, hay que devolverle el auto-brillo ya, no esperar al
        // próximo arranque de la app.
        KeyboardLight.reconcile()

        // La acción principal es un ítem NORMAL: apagar o encender la pantalla
        // reconfigura los displays, y con eso en marcha lo sano es que el menú
        // se cierre. Los interruptores de abajo sí se quedan abiertos.
        let s = L10n.t
        let displayItem: NSMenuItem
        if state == .offByUs {
            displayItem = item(s.turnOnDisplay, #selector(turnOn), enabled: true)
        } else {
            let check = control.canDisableBuiltIn()
            displayItem = item(check.allowed ? s.turnOffDisplay : s.cannotTurnOff(check.reason),
                               #selector(turnOff), enabled: check.allowed)
        }
        menu.addItem(displayItem)
        refs.displayItem = displayItem

        if state != .offByUs, control.builtInIsMirrorMaster {
            let bm = item(s.breakMirror, #selector(breakMirror), enabled: true)
            menu.addItem(bm)
            refs.breakMirrorItem = bm
        }

        menu.addItem(.separator())

        // Mantener despierto: interruptor, no cierra.
        let (awakeItem, awakeRow) = stayOpenRow(title: s.keepAwake,
                                                checked: KeepAwake.isOn) { [weak self] in
            self?.toggleKeepAwake()
        }
        menu.addItem(awakeItem)
        refs.awakeItem = awakeItem
        refs.awakeRow = awakeRow
        if KeepAwake.isOn { insertKeepDisplayRow(in: menu, after: awakeItem) }

        // Luz del teclado: sólo si este Mac tiene teclado retroiluminado.
        // El título se recalcula tras cada clic con la lectura en vivo.
        if KeyboardLight.available {
            let (kbItem, kbRow) = stayOpenRow(
                title: KeyboardLight.isOn ? s.keyboardLightOff : s.keyboardLightOn,
                checked: false) { [weak self] in self?.toggleKeyboardLight() }
            menu.addItem(kbItem)
            refs.kbRow = kbRow
        }

        menu.addItem(.separator())

        // Arranque al iniciar sesión. Seguro porque la app nunca apaga nada
        // por su cuenta (P1): arrancar sola sólo pone el icono en la barra.
        switch LoginItem.state {
        case .enabled, .disabled:
            let (li, row) = stayOpenRow(title: s.openAtLogin,
                                        checked: LoginItem.state.isOn) { [weak self] in
                self?.toggleLoginItem()
            }
            menu.addItem(li)
            refs.loginRow = row
        case .requiresApproval:
            // Abre Ajustes del Sistema: aquí cerrar el menú es lo correcto.
            menu.addItem(item(s.openAtLoginDisabledInSettings,
                              #selector(openLoginItemsSettings), enabled: true))
        case .unsupported(let why):
            menu.addItem(item(s.openAtLoginUnavailable(why), #selector(quit), enabled: false))
        }

        // Diagnóstico: sólo con ⌥ pulsada al abrir el menú.
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(.separator())
            let head = NSMenuItem(title: s.diagnostics, action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            refs.diagHead = head

            let dState = NSMenuItem(title: "  \(describe(state))", action: nil, keyEquivalent: "")
            dState.isEnabled = false
            menu.addItem(dState)
            refs.diagState = dState

            let dExt = NSMenuItem(title: "  \(s.usableExternals(control.usableExternalCount))",
                                  action: nil, keyEquivalent: "")
            dExt.isEnabled = false
            menu.addItem(dExt)
            refs.diagExternals = dExt

            let ol = item(s.openLog, #selector(openLog), enabled: true)
            menu.addItem(ol)
            refs.openLogItem = ol

            let (vi, vRow) = stayOpenRow(title: s.verboseLog,
                                         checked: DisplayControl.verboseLogging) { [weak self] in
                self?.toggleVerboseLog()
            }
            menu.addItem(vi)
            refs.verboseRow = vRow

            let force = item(s.forceReenable, #selector(turnOn), enabled: true)
            menu.addItem(force)
            refs.forceItem = force
        }

        menu.addItem(.separator())
        let quit = item(s.quit, #selector(quit), enabled: true)
        menu.addItem(quit)
        refs.quitItem = quit

        // Idioma DESPUÉS de Salir, como se pidió. Cambiarlo re-etiqueta todo el
        // menú en vivo, sin cerrarlo: la gracia de las filas StayOpenRow.
        let langItem = NSMenuItem(title: s.languageMenu, action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in Lang.allCases {
            let (li, row) = stayOpenRow(title: lang.displayName,
                                        checked: L10n.current == lang) { [weak self] in
                self?.chooseLanguage(lang)
            }
            langMenu.addItem(li)
            refs.langRows.append((lang, row))
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        refs.langItem = langItem

        return menu
    }

    private func stayOpenRow(title: String, checked: Bool,
                             onClick: @escaping () -> Void) -> (NSMenuItem, StayOpenRow) {
        let row = StayOpenRow(title: title, checked: checked)
        row.onClick = onClick
        let menuItem = NSMenuItem()
        menuItem.view = row
        return (menuItem, row)
    }

    private func insertKeepDisplayRow(in menu: NSMenu, after awakeItem: NSMenuItem) {
        let (di, dRow) = stayOpenRow(title: L10n.t.keepDisplayOn,
                                     checked: KeepAwake.keepsDisplayOn) { [weak self] in
            self?.toggleKeepDisplay()
        }
        menu.insertItem(di, at: menu.index(of: awakeItem) + 1)
        refs.keepDisplayItem = di
        refs.keepDisplayRow = dRow
    }

    /// Re-sincroniza el menú vivo tras un clic en un interruptor: títulos,
    /// marcas ✓ y la fila condicional de "…y la pantalla encendida". Los ítems
    /// se mutan in situ — reconstruir el menú entero con él abierto cancelaría
    /// el tracking.
    private func syncOpenMenu() {
        guard refs.menu != nil else { return }
        let s = L10n.t
        let state = control.builtInState()

        if let di = refs.displayItem {
            if state == .offByUs {
                di.title = s.turnOnDisplay
                di.action = #selector(turnOn)
                di.isEnabled = true
            } else {
                let check = control.canDisableBuiltIn()
                di.title = check.allowed ? s.turnOffDisplay : s.cannotTurnOff(check.reason)
                di.action = check.allowed ? #selector(turnOff) : nil
                di.isEnabled = check.allowed
            }
        }
        refs.breakMirrorItem?.title = s.breakMirror

        refs.awakeRow?.configure(title: s.keepAwake, checked: KeepAwake.isOn)
        if KeepAwake.isOn {
            if refs.keepDisplayItem == nil, let menu = refs.menu, let ai = refs.awakeItem {
                insertKeepDisplayRow(in: menu, after: ai)
            }
            refs.keepDisplayRow?.configure(title: s.keepDisplayOn,
                                           checked: KeepAwake.keepsDisplayOn)
        } else if let di = refs.keepDisplayItem {
            di.menu?.removeItem(di)
            refs.keepDisplayItem = nil
            refs.keepDisplayRow = nil
        }

        refs.kbRow?.configure(title: KeyboardLight.isOn ? s.keyboardLightOff : s.keyboardLightOn,
                              checked: false)
        refs.loginRow?.configure(title: s.openAtLogin, checked: LoginItem.state.isOn)
        refs.verboseRow?.configure(title: s.verboseLog, checked: DisplayControl.verboseLogging)

        refs.diagHead?.title = s.diagnostics
        refs.diagState?.title = "  \(describe(state))"
        refs.diagExternals?.title = "  \(s.usableExternals(control.usableExternalCount))"
        refs.openLogItem?.title = s.openLog
        refs.forceItem?.title = s.forceReenable

        refs.quitItem?.title = s.quit
        refs.langItem?.title = s.languageMenu
        for (lang, row) in refs.langRows {
            row.configure(title: lang.displayName, checked: L10n.current == lang)
        }
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

    private func toggleKeepAwake() {
        let turningOn = !KeepAwake.isOn
        if let problem = KeepAwake.set(enabled: turningOn,
                                       includeDisplay: KeepAwake.keepsDisplayOn) {
            alert(L10n.t.keepAwake, problem)
        } else {
            control.write("mantener despierto: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    private func toggleKeepDisplay() {
        let turningOn = !KeepAwake.keepsDisplayOn
        if let problem = KeepAwake.adjustDisplay(turningOn) {
            alert(L10n.t.alertKeepDisplayTitle, problem)
        } else {
            control.write("mantener pantalla encendida: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    private func toggleLoginItem() {
        let turningOn = !LoginItem.state.isOn
        if let problem = LoginItem.setEnabled(turningOn) {
            alert(L10n.t.alertLoginItemTitle, problem)
        } else {
            control.write("arranque al iniciar sesión: \(turningOn ? "activado" : "desactivado")")
        }
        refresh()
    }

    private func toggleKeyboardLight() {
        let turningOff = KeyboardLight.isOn
        let ok = turningOff ? KeyboardLight.turnOff() : KeyboardLight.turnOn()
        if ok {
            control.write("luz del teclado: \(turningOff ? "apagada" : "encendida")")
        } else {
            alert(L10n.t.alertKeyboardTitle, L10n.t.keyboardLightFailed)
        }
        refresh()
    }

    private func chooseLanguage(_ lang: Lang) {
        L10n.current = lang
        control.write("idioma: \(lang.rawValue)")
        refresh()
    }

    @objc private func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    private func toggleVerboseLog() {
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
    // Se reconstruye en cada APERTURA (no en cada clic: los interruptores
    // actualizan el menú vivo vía syncOpenMenu sin cerrarlo).
    func menuNeedsUpdate(_ menu: NSMenu) {
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
        // Las referencias apuntan al menú vivo, no al temporal ya vaciado.
        refs.menu = menu
    }
}
