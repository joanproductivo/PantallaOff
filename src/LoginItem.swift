import Foundation
import ServiceManagement

/// Arranque al iniciar sesión, vía `SMAppService` (macOS 13+).
///
/// Por qué esto es seguro pese a que el plan lo había pospuesto: el riesgo que
/// se temía era un bucle de arranque en negro, y sólo existiría si la app
/// re-aplicase el apagado al arrancar. No lo hace — P1 dice que ninguna ruta
/// automática puede desactivar un display. Arrancar al inicio sólo coloca el
/// icono en la barra de menú; apagar sigue exigiendo un clic.
///
/// Peor caso si la app fallase al arrancar: no aparece el icono. Nada más.
enum LoginItem {

    enum State {
        case enabled
        case disabled
        case requiresApproval   // el usuario lo desactivó en Ajustes del Sistema
        case unsupported(String)

        var isOn: Bool { if case .enabled = self { return true }; return false }
    }

    /// `SMAppService.mainApp` registra la RUTA del bundle actual. Registrar
    /// desde ./build dejaría un elemento de inicio apuntando a un directorio de
    /// compilación que puede desaparecer con `make clean`.
    static var isInStableLocation: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static var state: State {
        guard Bundle.main.bundleIdentifier != nil else {
            return .unsupported(L10n.t.loginNotBundled)
        }
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .disabled
        case .requiresApproval: return .requiresApproval
        // .notFound NO significa "no soportado": con firma ad-hoc es lo que
        // devuelve el sistema mientras la app nunca se ha registrado. Medido:
        // register() funciona igualmente y el estado pasa a .enabled. Tratarlo
        // como "no disponible" deshabilitaba el menú sin motivo.
        case .notFound:         return .disabled
        @unknown default:       return .unsupported(L10n.t.loginUnknownState)
        }
    }

    /// Devuelve nil si todo fue bien, o un mensaje para mostrar al usuario.
    static func setEnabled(_ enabled: Bool) -> String? {
        guard Bundle.main.bundleIdentifier != nil else {
            return L10n.t.loginRunTheApp
        }
        if enabled && !isInStableLocation {
            return L10n.t.loginInstallFirst(Bundle.main.bundlePath)
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return L10n.t.loginCouldNotChange(error.localizedDescription)
        }
    }
}
