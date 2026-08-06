import Foundation

/// Localización de PantallaOff: español e inglés.
///
/// Sin ficheros .lproj a propósito. Para dos idiomas y ~37 cadenas, una struct
/// compilada es más simple que un bundle de recursos, y además el compilador
/// obliga a rellenar las dos versiones: no puede haber una cadena traducida a
/// medias. También es greppable, que en este proyecto importa.
///
/// Alcance: TODO lo que ve el usuario en la interfaz. Quedan deliberadamente en
/// español el registro (los README citan líneas literales y conviene que sean
/// monolingües y greppables), las herramientas de línea de comandos y el
/// instalador.
enum Lang: String, CaseIterable {
    case es, en

    var displayName: String {
        switch self {
        case .es: return "Español"
        case .en: return "English"
        }
    }
}

enum L10n {
    private static let key = "language"

    /// Idioma elegido, o el del sistema si el usuario no ha elegido nunca.
    static var current: Lang {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let lang = Lang(rawValue: raw) {
                return lang
            }
            return systemDefault
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Un sistema en catalán, gallego o euskera espera antes el español que el
    /// inglés: la app está escrita en español y el usuario casi seguro lo lee.
    static var systemDefault: Lang {
        guard let first = Locale.preferredLanguages.first?.lowercased() else { return .en }
        for prefix in ["es", "ca", "gl", "eu"] where first.hasPrefix(prefix) {
            return .es
        }
        return .en
    }

    static var t: Strings { current == .es ? .spanish : .english }
}

struct Strings {
    // Menú principal
    let turnOffDisplay: String
    let turnOnDisplay: String
    let cannotTurnOff: (String) -> String
    let breakMirror: String
    let keepAwake: String
    let keepDisplayOn: String
    let openAtLogin: String
    let openAtLoginDisabledInSettings: String
    let openAtLoginUnavailable: (String) -> String
    let quit: String
    let languageMenu: String

    // Diagnóstico (bajo ⌥)
    let diagnostics: String
    let usableExternals: (UInt32) -> String
    let openLog: String
    let verboseLog: String
    let forceReenable: String
    let versionLine: (String) -> String

    // Estado de la pantalla interna
    let stateOn: String
    let stateMirroredSlave: String
    let stateMirrorMaster: String
    let stateOffByUs: String
    let stateMissing: String

    // Tooltip
    let tipAwake: String
    let tipAwakeWithDisplay: String

    // Motivos de la precondición (traducción de pc_deny_reason)
    let denyAlreadyOff: String
    let denyNoBuiltin: String
    let denyMirrorMaster: String
    let denyNoExternal: String
    let denyUnknown: String

    // Errores y alertas
    let errPostcondition: String
    let errStateWrite: String
    let errDeadmanUnavailable: String
    let errCGError: (Int32) -> String
    let errBuiltinNotFound: String
    let errInterference: String

    let alertTurnOffFailedTitle: String
    let alertAttentionTitle: String
    let alertRescueFailed: String
    let alertBreakMirrorFailedTitle: String
    let alertBreakMirrorFailedBody: String
    let alertKeepDisplayTitle: String
    let alertLoginItemTitle: String
    let alertKeyboardTitle: String
    let alertOK: String

    // LoginItem
    let loginNotBundled: String
    let loginUnknownState: String
    let loginRunTheApp: String
    let loginInstallFirst: (String) -> String
    let loginCouldNotChange: (String) -> String

    // KeepAwake
    let awakeFailed: (String) -> String

    // Luz del teclado
    let keyboardLightOff: String
    let keyboardLightOn: String
    let keyboardLightFailed: String
}

extension Strings {
    static let spanish = Strings(
        turnOffDisplay: "Apagar pantalla del MacBook",
        turnOnDisplay: "Encender pantalla del MacBook",
        cannotTurnOff: { "No se puede apagar — \($0)" },
        breakMirror: "Romper el espejo (la interna es la fuente)",
        keepAwake: "Mantener el Mac despierto",
        keepDisplayOn: "      …y la pantalla encendida",
        openAtLogin: "Abrir al iniciar sesión",
        openAtLoginDisabledInSettings: "Abrir al iniciar sesión — desactivado en Ajustes",
        openAtLoginUnavailable: { "Abrir al iniciar sesión — \($0)" },
        quit: "Salir de PantallaOff",
        languageMenu: "Idioma / Language",

        diagnostics: "Diagnóstico",
        usableExternals: { "Pantallas externas utilizables: \($0)" },
        openLog: "Abrir el registro",
        verboseLog: "Registro detallado",
        forceReenable: "Forzar reactivación de todas las pantallas",
        versionLine: { "  Versión: \($0)" },

        stateOn: "Pantalla del MacBook: encendida",
        stateMirroredSlave: "Pantalla del MacBook: encendida, mostrando un espejo",
        stateMirrorMaster: "Pantalla del MacBook: encendida, y es la fuente del espejo",
        stateOffByUs: "Pantalla del MacBook: apagada por PantallaOff",
        stateMissing: "Pantalla del MacBook: no encontrada",

        tipAwake: "Manteniendo el Mac despierto",
        tipAwakeWithDisplay: "Despierto, con la pantalla encendida",

        denyAlreadyOff: "La pantalla interna ya está apagada",
        denyNoBuiltin: "No se encuentra la pantalla interna",
        denyMirrorMaster: "La interna es la fuente del espejo: rómpelo primero",
        denyNoExternal: "Sin pantalla externa utilizable (desconectada, dormida o virtual)",
        denyUnknown: "No se puede apagar ahora mismo",

        errPostcondition: "La operación dejaba el equipo sin pantalla utilizable; se ha revertido",
        errStateWrite: "No se pudo guardar el estado en disco",
        errDeadmanUnavailable: "No se pudo armar la red de seguridad (falta el binario 'rescue'). "
                             + "No se ha tocado ninguna pantalla.",
        errCGError: { "Error de CoreGraphics \($0)" },
        errBuiltinNotFound: "No se encuentra la pantalla interna",
        errInterference: "Otra herramienta reactivó la pantalla; vuelve a intentarlo",

        alertTurnOffFailedTitle: "No se ha apagado la pantalla",
        alertAttentionTitle: "Atención",
        alertRescueFailed: "No se ha podido reactivar ninguna pantalla.\n\n"
                         + "Ejecuta ~/rescue desde una terminal o por SSH. Si eso no basta: "
                         + "~/rescue --restore",
        alertBreakMirrorFailedTitle: "No se ha podido romper el espejo",
        alertBreakMirrorFailedBody: "Desactiva la duplicación desde Ajustes del Sistema → Pantallas.",
        alertKeepDisplayTitle: "Mantener la pantalla encendida",
        alertLoginItemTitle: "Arranque automático",
        alertKeyboardTitle: "Luz del teclado",
        alertOK: "Aceptar",

        loginNotBundled: "La app no está empaquetada (ejecútala desde el .app)",
        loginUnknownState: "Estado desconocido",
        loginRunTheApp: "Esta copia no está empaquetada. Ejecuta PantallaOff.app, no el binario suelto.",
        loginInstallFirst: { path in
            "Instala primero la app en /Applications (make install).\n\n"
            + "El elemento de inicio guarda la ruta del bundle, y apuntar a \(path) "
            + "dejaría un arranque roto en cuanto muevas o borres esa carpeta."
        },
        loginCouldNotChange: { reason in
            "No se pudo cambiar el arranque automático: \(reason)\n\n"
            + "Puedes hacerlo a mano en Ajustes del Sistema → General → Ítems de inicio y extensiones."
        },

        awakeFailed: { code in "No se pudo activar (IOReturn \(code))" },

        keyboardLightOff: "Apagar luz del teclado",
        keyboardLightOn: "Encender luz del teclado",
        keyboardLightFailed: "No se pudo cambiar la luz del teclado. "
                           + "Puedes usar las teclas de brillo del teclado."
    )

    static let english = Strings(
        turnOffDisplay: "Turn off MacBook display",
        turnOnDisplay: "Turn on MacBook display",
        cannotTurnOff: { "Can't turn off — \($0)" },
        breakMirror: "Break the mirror (built-in is the source)",
        keepAwake: "Keep the Mac awake",
        keepDisplayOn: "      …and the display on",
        openAtLogin: "Open at login",
        openAtLoginDisabledInSettings: "Open at login — disabled in Settings",
        openAtLoginUnavailable: { "Open at login — \($0)" },
        quit: "Quit PantallaOff",
        languageMenu: "Idioma / Language",

        diagnostics: "Diagnostics",
        usableExternals: { "Usable external displays: \($0)" },
        openLog: "Open the log",
        verboseLog: "Verbose logging",
        forceReenable: "Force re-enable all displays",
        versionLine: { "  Version: \($0)" },

        stateOn: "MacBook display: on",
        stateMirroredSlave: "MacBook display: on, showing a mirror",
        stateMirrorMaster: "MacBook display: on, and it's the mirror source",
        stateOffByUs: "MacBook display: turned off by PantallaOff",
        stateMissing: "MacBook display: not found",

        tipAwake: "Keeping the Mac awake",
        tipAwakeWithDisplay: "Awake, with the display on",

        denyAlreadyOff: "The built-in display is already off",
        denyNoBuiltin: "Built-in display not found",
        denyMirrorMaster: "The built-in is the mirror source: break it first",
        denyNoExternal: "No usable external display (disconnected, asleep or virtual)",
        denyUnknown: "Can't turn it off right now",

        errPostcondition: "That would have left the Mac with no usable display; it was reverted",
        errStateWrite: "Couldn't save the state to disk",
        errDeadmanUnavailable: "Couldn't arm the safety net (the 'rescue' binary is missing). "
                             + "No display was touched.",
        errCGError: { "CoreGraphics error \($0)" },
        errBuiltinNotFound: "Built-in display not found",
        errInterference: "Another tool turned the display back on; try again",

        alertTurnOffFailedTitle: "The display wasn't turned off",
        alertAttentionTitle: "Heads up",
        alertRescueFailed: "No display could be re-enabled.\n\n"
                         + "Run ~/rescue from a terminal or over SSH. If that isn't enough: "
                         + "~/rescue --restore",
        alertBreakMirrorFailedTitle: "Couldn't break the mirror",
        alertBreakMirrorFailedBody: "Turn mirroring off in System Settings → Displays.",
        alertKeepDisplayTitle: "Keep the display on",
        alertLoginItemTitle: "Open at login",
        alertKeyboardTitle: "Keyboard backlight",
        alertOK: "OK",

        loginNotBundled: "The app isn't bundled (run it from the .app)",
        loginUnknownState: "Unknown state",
        loginRunTheApp: "This copy isn't bundled. Run PantallaOff.app, not the bare binary.",
        loginInstallFirst: { path in
            "Install the app in /Applications first (make install).\n\n"
            + "The login item stores the bundle path, and pointing it at \(path) "
            + "would leave a broken startup as soon as you move or delete that folder."
        },
        loginCouldNotChange: { reason in
            "Couldn't change the login item: \(reason)\n\n"
            + "You can do it by hand in System Settings → General → Login Items & Extensions."
        },

        awakeFailed: { code in "Couldn't enable it (IOReturn \(code))" },

        keyboardLightOff: "Turn off keyboard backlight",
        keyboardLightOn: "Turn on keyboard backlight",
        keyboardLightFailed: "Couldn't change the keyboard backlight. "
                           + "You can use the keyboard's brightness keys."
    )
}
