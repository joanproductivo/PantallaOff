import Foundation
import IOKit.pwr_mgt

/// Mantener el Mac despierto, como el modo básico de Amphetamine.
///
/// Usa `IOPMAssertionCreateWithName`, la API **pública** de gestión de energía
/// —la misma que hay debajo de `caffeinate`—. Nada de APIs privadas aquí: esta
/// parte del proyecto no necesita ningún truco.
///
/// Deliberadamente sólo hace una cosa: impedir el reposo por inactividad.
/// Sin temporizadores, sin activarse por app, sin disparadores. Un interruptor.
///
/// Qué NO hace, a propósito:
///   - No impide el reposo al cerrar la tapa. macOS lo fuerza al margen de
///     cualquier assertion, y en este proyecto además es deseable: cerrar la
///     tapa es tu vía fiable para recuperar la pantalla interna.
///   - No evita que la pantalla se apague por sí sola, salvo que actives
///     "mantener también la pantalla encendida".
enum KeepAwake {

    /// `PreventUserIdleSystemSleep`: el sistema no se duerme por inactividad,
    /// pero la pantalla sí puede apagarse (equivale a `caffeinate -i`).
    /// Es el modo por defecto y el que menos gasta batería.
    private static let systemAssertion = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString

    /// `PreventUserIdleDisplaySleep`: además mantiene la pantalla encendida
    /// (equivale a `caffeinate -d`). Útil para ver un vídeo o un dashboard.
    private static let displayAssertion = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString

    private static var systemID: IOPMAssertionID = 0
    private static var displayID: IOPMAssertionID = 0

    static var isOn: Bool { systemID != 0 }
    static var keepsDisplayOn: Bool { displayID != 0 }

    /// Activa o desactiva. `includeDisplay` añade la assertion de pantalla.
    /// Devuelve nil si todo fue bien, o un mensaje de error para la UI.
    @discardableResult
    static func set(enabled: Bool, includeDisplay: Bool) -> String? {
        guard enabled else {
            release(&systemID)
            release(&displayID)
            return nil
        }
        if systemID == 0,
           let err = create(systemAssertion, "PantallaOff: mantener el Mac despierto",
                            into: &systemID) {
            return err
        }
        return adjustDisplay(includeDisplay)
    }

    /// Ajusta sólo la assertion de pantalla, sin tocar la del sistema.
    @discardableResult
    static func adjustDisplay(_ includeDisplay: Bool) -> String? {
        if includeDisplay && displayID == 0 && systemID != 0 {
            return create(displayAssertion, "PantallaOff: mantener la pantalla encendida",
                          into: &displayID)
        }
        if !includeDisplay { release(&displayID) }
        return nil
    }

    private static func create(_ type: CFString, _ reason: String,
                               into id: inout IOPMAssertionID) -> String? {
        var newID: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(type,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             reason as CFString,
                                             &newID)
        guard rc == kIOReturnSuccess else {
            return L10n.t.awakeFailed(String(format: "0x%08x", rc))
        }
        id = newID
        return nil
    }

    private static func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}
