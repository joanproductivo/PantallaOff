import Foundation

/// Apagar y encender la luz del teclado. Sólo el interruptor, sin graduación:
/// para eso ya están las teclas de brillo del propio teclado.
///
/// Usa `KeyboardBrightnessClient` de CoreBrightness (privado). La vía pública de
/// Intel (`AppleLMUController`) está muerta en Apple Silicon. Verificado en
/// macOS 26.6 / M3 Max: la clase existe, no pide entitlements, y un getter
/// cuesta 0,096 ms — no hace falta sacarlo del hilo principal.
///
/// La sutileza que hace esto menos trivial de lo que parece: **el auto-brillo**.
/// Con el sensor activo (por defecto lo está), poner el brillo a 0 no apaga
/// nada: el sistema lo vuelve a subir. Hay que desactivar el automático, y por
/// tanto restaurarlo después — lo que obliga a recordar cómo estaba.
@objc private protocol KeyboardBrightnessClientProtocol {
    func copyKeyboardBacklightIDs() -> [NSNumber]
    func brightness(forKeyboard keyboardID: UInt64) -> Float
    func setBrightness(_ brightness: Float, forKeyboard keyboardID: UInt64) -> Bool
    func enableAutoBrightness(_ enable: Bool, forKeyboard keyboardID: UInt64) -> Bool
    func isAutoBrightnessEnabled(forKeyboard keyboardID: UInt64) -> Bool
    // Sólo para diagnóstico; no se exigen para considerar la API disponible.
    @objc optional func backlightLevel(forKeyboard keyboardID: UInt64) -> Float
    @objc optional func isBacklightDimmed(onKeyboard keyboardID: UInt64) -> Bool
}

enum KeyboardLight {

    /// Brillo al que se enciende si no hay nada guardado que restaurar.
    private static let defaultBrightness: Float = 0.35

    private enum Key {
        /// Lo apagamos NOSOTROS. Sin este flag, apagar dos veces con las teclas
        /// F de por medio machacaba el auto-brillo guardado con el valor ya
        /// falseado, y el usuario perdía su ajuste automático para siempre.
        static let offByUs = "kbOffByUs"
        static let brightnessBeforeOff = "kbBrightnessBeforeOff"
        static let autoBeforeOff = "kbAutoBeforeOff"
    }

    // MARK: - Cliente

    private static let client: KeyboardBrightnessClientProtocol? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else { return nil }
        let obj = cls.init()

        // `as?` sobre un @objc protocol consulta conformsToProtocol:, y una
        // clase privada de Apple no declara conformidad con un protocolo que
        // acabamos de inventar: siempre devolvería nil. Se comprueba a mano que
        // responde a los selectores que vamos a usar —eso sí es la garantía
        // real— y se hace el bitcast, que para un existencial @objc no es más
        // que reinterpretar el puntero al objeto.
        let required: [Selector] = [
            #selector(KeyboardBrightnessClientProtocol.copyKeyboardBacklightIDs),
            #selector(KeyboardBrightnessClientProtocol.brightness(forKeyboard:)),
            #selector(KeyboardBrightnessClientProtocol.setBrightness(_:forKeyboard:)),
            #selector(KeyboardBrightnessClientProtocol.enableAutoBrightness(_:forKeyboard:)),
            #selector(KeyboardBrightnessClientProtocol.isAutoBrightnessEnabled(forKeyboard:)),
        ]
        guard required.allSatisfy({ obj.responds(to: $0) }) else { return nil }
        return unsafeBitCast(obj, to: KeyboardBrightnessClientProtocol.self)
    }()

    private static var keyboardIDs: [UInt64] {
        (client?.copyKeyboardBacklightIDs() ?? []).map { $0.uint64Value }
    }

    /// false en un Mac sin teclado retroiluminado (sobremesa). El ítem de menú
    /// simplemente no aparece.
    static var available: Bool { client != nil && !keyboardIDs.isEmpty }

    /// Lectura en vivo. `brightnessForKeyboard:` devuelve el AJUSTE, no el nivel
    /// efectivo del hardware (`backlightLevelForKeyboard:` es otro selector), así
    /// que sirve de fuente de verdad para el menú aunque el sistema haya
    /// atenuado la luz por inactividad.
    static var isOn: Bool {
        guard let client, let id = keyboardIDs.first else { return false }
        return client.brightness(forKeyboard: id) > 0
    }

    private static var offByUs: Bool {
        get { UserDefaults.standard.bool(forKey: Key.offByUs) }
        set { UserDefaults.standard.set(newValue, forKey: Key.offByUs) }
    }

    // MARK: - Acciones

    @discardableResult
    static func turnOff() -> Bool {
        guard let client, !keyboardIDs.isEmpty else { return false }
        let ids = keyboardIDs

        // Guardar SÓLO si no lo teníamos ya apagado nosotros. Si el usuario
        // subió la luz con F6 mientras estaba "apagada", el auto sigue
        // desactivado por nosotros: re-guardarlo ahora perdería su valor real.
        if !offByUs, let first = ids.first {
            UserDefaults.standard.set(client.brightness(forKeyboard: first),
                                      forKey: Key.brightnessBeforeOff)
            UserDefaults.standard.set(client.isAutoBrightnessEnabled(forKeyboard: first),
                                      forKey: Key.autoBeforeOff)
        }

        // El flag se marca ANTES de mutar, igual que P5 hace con el estado de
        // las pantallas. Si se marcara sólo "si todo fue bien", un
        // setBrightness fallido dejaría el auto ya desactivado con offByUs en
        // false: ni restoreOnQuit lo revertiría, ni la guarda de arriba
        // impediría que el siguiente turnOff re-guardase el auto ya falseado.
        // Marcado de más es recuperable —reconcile() lo deshace—; marcado de
        // menos, no.
        offByUs = true

        var ok = true
        for id in ids {
            // Primero el automático: si no, el sensor vuelve a subir la luz.
            if !client.enableAutoBrightness(false, forKeyboard: id) { ok = false }
            if !client.setBrightness(0, forKeyboard: id) { ok = false }
        }
        return ok
    }

    @discardableResult
    static func turnOn() -> Bool {
        guard let client, !keyboardIDs.isEmpty else { return false }

        let saved = UserDefaults.standard.object(forKey: Key.brightnessBeforeOff) as? Float
        let brightness = (saved.map { $0 > 0 ? $0 : defaultBrightness }) ?? defaultBrightness
        let autoWasOn = UserDefaults.standard.object(forKey: Key.autoBeforeOff) as? Bool ?? true

        // El auto-brillo sólo se toca si fuimos NOSOTROS quienes lo apagamos.
        // Si el usuario bajó la luz a 0 con las teclas F, "Encender" no debe
        // activarle un automático que quizá tenía desactivado a propósito.
        let restoreAuto = offByUs

        var ok = true
        for id in keyboardIDs {
            // Brillo primero y automático después: si el orden fuera el
            // inverso, el sensor podría recalcular antes de que pongamos el
            // valor y dejar un resultado distinto al que había.
            if !client.setBrightness(brightness, forKeyboard: id) { ok = false }
            if restoreAuto, !client.enableAutoBrightness(autoWasOn, forKeyboard: id) {
                ok = false
            }
        }
        offByUs = false
        return ok
    }

    /// Si consta apagada por nosotros pero está encendida, alguien la subió por
    /// fuera (teclas F). Devolvemos el automático a como estaba y soltamos el
    /// flag: el mismo patrón de reconciliación que usa el estado de pantallas.
    @discardableResult
    static func reconcile() -> Bool {
        guard offByUs, isOn, let client else { return false }
        let autoWasOn = UserDefaults.standard.object(forKey: Key.autoBeforeOff) as? Bool ?? true
        var ok = true
        for id in keyboardIDs {
            if !client.enableAutoBrightness(autoWasOn, forKeyboard: id) { ok = false }
        }
        // Se suelta el flag aunque falle: si no, quedaríamos en un bucle de
        // reconciliación que nunca converge. El estado real ya es "encendida".
        offByUs = false
        return ok
    }

    /// Al salir de la app: no dejar el auto-brillo del sistema desactivado a
    /// espaldas del usuario. Simétrico con KeepAwake y con las pantallas.
    static func restoreOnQuit() {
        guard offByUs else { return }
        turnOn()
    }

    // MARK: - Diagnóstico

    static func diagnosticReport() -> String {
        guard let client else {
            return "CoreBrightness / KeyboardBrightnessClient no disponible"
        }
        let ids = keyboardIDs
        guard !ids.isEmpty else { return "sin teclados retroiluminados" }

        // El dominio de UserDefaults depende del bundle id: un binario suelto
        // NO ve las preferencias de la app. Se imprime para no confundir un
        // diagnóstico del binario de ./build con el estado real de la app.
        var out = "dominio=\(Bundle.main.bundleIdentifier ?? "(sin bundle: preferencias aparte)")\n"
        out += "offByUs=\(offByUs) "
        out += "guardado: brillo=\(UserDefaults.standard.object(forKey: Key.brightnessBeforeOff) ?? "—") "
        out += "auto=\(UserDefaults.standard.object(forKey: Key.autoBeforeOff) ?? "—")\n"
        for id in ids {
            out += "teclado \(id): ajuste=\(client.brightness(forKeyboard: id)) "
            out += "nivel_efectivo=\(client.backlightLevel?(forKeyboard: id) ?? -1) "
            out += "atenuado=\(client.isBacklightDimmed?(onKeyboard: id) ?? false) "
            out += "auto=\(client.isAutoBrightnessEnabled(forKeyboard: id))\n"
        }
        return out
    }
}
