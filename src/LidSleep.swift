import Foundation
import IOKit

/// «Dormir al cerrar la tapa»: con el interruptor activado, si la tapa pasa de
/// abierta a cerrada y el sistema NO va a dormir por sí solo (clamshell:
/// corriente + pantalla externa), se ordena el reposo.
///
/// Todo API pública: `kIOPMMessageClamshellStateChange` (IOPM.h) llega como
/// notificación de interés general de IOPMrootDomain con un bitfield —
/// `kClamshellStateBit` (tapa cerrada) y `kClamshellSleepBit` (el cambio ya
/// provoca reposo) — y `IOPMSleepSystem` exige root o el usuario de CONSOLA
/// (IOPMLib.h), que una app de barra de menú siempre es.
///
/// Sin estado persistente en el sistema: si la app muere no queda nada que
/// restaurar (a diferencia de `pmset disablesleep`, descartado por eso). La
/// única memoria es la preferencia en UserDefaults.
enum LidSleep {
    private static let key = "sleepOnLidClose"

    /// Cola propia, como el vigía IOKit de DisplayControl. TODO el estado del
    /// enum se toca sólo aquí (arranque, parada, semilla, flanco y callback:
    /// IONotificationPortSetDispatchQueue entrega en esta misma cola).
    private static let queue = DispatchQueue(label: "com.joanplanas.pantallaoff.lidsleep",
                                             qos: .userInteractive)

    private static var notifyPort: IONotificationPortRef?
    private static var interestNote: io_object_t = 0
    private static var rootDomain: io_service_t = 0

    /// Último estado conocido de la tapa (true = cerrada). Se SIEMBRA leyendo
    /// AppleClamshellState al arrancar el vigía: sin semilla, el primer
    /// mensaje —que puede llegar por un cambio de CausesSleep con la tapa
    /// quieta, p. ej. enchufar la corriente en clamshell— se confundiría con
    /// un flanco y dormiría el Mac por sorpresa; con la convención contraria,
    /// el primer cierre real no haría nada.
    private static var lastClosed = false

    /// Preferencia del usuario. Cambiarla arranca o para el vigía.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            queue.async { newValue ? start() : stop() }
        }
    }

    /// Llamar al arrancar la app: si la preferencia quedó activada en una
    /// sesión anterior, el vigía debe revivir con ella (el interruptor
    /// marcado con la función muerta sería mentir).
    static func startIfEnabled() {
        queue.async { if UserDefaults.standard.bool(forKey: key) { start() } }
    }

    // MARK: - Vigía (todo en `queue`)

    private static func start() {
        guard notifyPort == nil else { return }

        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            DisplayControl.shared.writeProblem("tapa: no se encuentra IOPMrootDomain")
            return
        }
        lastClosed = readClamshellClosed()

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            DisplayControl.shared.writeProblem("tapa: no se pudo crear el puerto de notificaciones")
            IOObjectRelease(rootDomain)
            rootDomain = 0
            return
        }
        IONotificationPortSetDispatchQueue(port, queue)

        // refcon nil a propósito: el callback usa el estado estático del enum,
        // así que una callback ya encolada tras stop() no puede colgar de
        // memoria liberada.
        let kr = IOServiceAddInterestNotification(
            port, rootDomain, kIOGeneralInterest,
            { _, _, messageType, messageArgument in
                LidSleep.clamshellMessage(type: messageType, argument: messageArgument)
            },
            nil, &interestNote)
        guard kr == KERN_SUCCESS else {
            DisplayControl.shared.writeProblem("tapa: AddInterestNotification falló (\(kr))")
            IONotificationPortDestroy(port)
            IOObjectRelease(rootDomain)
            rootDomain = 0
            return
        }
        notifyPort = port
        DisplayControl.shared.write("dormir al cerrar la tapa: vigía iniciado (tapa cerrada=\(lastClosed))")
    }

    /// Orden de limpieza: notificación → puerto → servicio. Corre en `queue`,
    /// serializado con el callback: no pueden solaparse.
    private static func stop() {
        guard notifyPort != nil else { return }
        if interestNote != 0 { IOObjectRelease(interestNote); interestNote = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        if rootDomain != 0 { IOObjectRelease(rootDomain); rootDomain = 0 }
        DisplayControl.shared.write("dormir al cerrar la tapa: vigía parado")
    }

    private static func clamshellMessage(type: UInt32, argument: UnsafeMutableRawPointer?) {
        guard type == pcMsgClamshellStateChange else { return }
        // El bitfield viaja en el VALOR del puntero; con ambos bits a 0 llega
        // nil — es un valor válido (tapa abierta, sin reposo), no un error.
        let bits = UInt(bitPattern: argument)
        let closed = bits & UInt(kClamshellStateBit) != 0
        let systemWillSleep = bits & UInt(kClamshellSleepBit) != 0
        if DisplayControl.verboseLogging {
            DisplayControl.shared.write("tapa: cerrada=\(closed) dormirá=\(systemWillSleep)")
        }
        defer { lastClosed = closed }

        // Sólo el GESTO de cerrar (flanco abierta→cerrada): los mensajes por
        // cambios de CausesSleep con la tapa quieta no son un gesto. Sin
        // debounce a propósito: cerrar de nuevo nada más despertar ES un
        // gesto y debe dormir; un debounce con reloj pausado en reposo se lo
        // tragaría.
        guard closed && !lastClosed else { return }
        // Si el sistema ya va a dormir solo (batería, sin externo…), no se
        // duplica el disparo.
        guard !systemWillSleep else { return }
        trigger()
    }

    private static func trigger() {
        DisplayControl.shared.write("tapa cerrada con el sistema despierto: durmiendo (opción activada)")
        let fb = IOPMFindPowerManagement(kIOMainPortDefault)
        guard fb != 0 else {
            DisplayControl.shared.writeProblem("tapa: IOPMFindPowerManagement falló; no se puede dormir")
            return
        }
        let err = IOPMSleepSystem(fb)
        IOServiceClose(fb)
        if err != kIOReturnSuccess {
            // Un gesto explícito del usuario sin efecto merece investigación;
            // writeProblem, no write: tiene que llegar al disco siempre.
            DisplayControl.shared.writeProblem("tapa: IOPMSleepSystem falló (IOReturn \(err))")
        }
    }

    private static func readClamshellClosed() -> Bool {
        guard rootDomain != 0,
              let cf = IORegistryEntryCreateCFProperty(rootDomain,
                                                       "AppleClamshellState" as CFString,
                                                       kCFAllocatorDefault, 0)
        else { return false }
        return (cf.takeRetainedValue() as? Bool) ?? false
    }
}
