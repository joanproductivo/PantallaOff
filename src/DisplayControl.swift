import AppKit
import CoreGraphics
import Foundation
import IOKit
import os

/// Estado observable de la pantalla interna.
///
/// Hay más de dos estados, y ese fue el error de la v1: asumir que
/// `CGDisplayIsActive == false` significa "apagada". Bajo espejo hardware el
/// esclavo también da `false` con el panel perfectamente encendido.
enum BuiltInState: Equatable {
    case on                 // encendida, con su propio escritorio
    case mirroredSlave      // encendida, mostrando el espejo de otra pantalla
    case mirrorMaster       // encendida, y es la FUENTE del espejo
    case offByUs            // desactivada por nosotros
    case missing            // no se encuentra y no consta apagada por nosotros
}

struct DisableCheck {
    let allowed: Bool
    let reason: String        // ya localizado, listo para la UI
    let code: pc_deny_reason  // para el log: monolingüe y greppable
}

final class DisplayControl {
    static let shared = DisplayControl()

    private let log = Logger(subsystem: "com.joanplanas.pantallaoff", category: "display")

    /// Cuánto tiempo tiene el dead-man antes de disparar si no lo desarmamos.
    /// 30 s y no 15: se midieron transacciones CG bloqueadas ~21 s con
    /// WindowServer en estados raros, y un dead-man que dispara DURANTE un
    /// apagado legítimo lento limpia el estado en el peor momento. Sigue siendo
    /// corto frente a un cuelgue real de la app.
    private let deadmanSeconds = 30

    /// Cada cuánto reevalúa el watchdog aunque no haya callback.
    /// El caso peligroso (externo dormido, KVM conmutado, entrada del monitor
    /// cambiada) NO genera callback de reconfiguración: sólo lo pilla el timer.
    private let watchdogInterval: TimeInterval = 3.0

    /// Toda mutación ocurre aquí, nunca en el hilo principal: bloquear main
    /// durante y después de la mutación impediría que el timer del watchdog se
    /// dispare justo en la ventana más peligrosa.
    private let workQueue = DispatchQueue(label: "com.joanplanas.pantallaoff.work")

    private var watchdogTimer: Timer?
    private var onChange: (() -> Void)?

    private init() {}

    // MARK: - Lectura de estado

    var builtInID: CGDirectDisplayID { pc_builtin_id() }

    /// IDs que constan como desactivados por nosotros (fichero de estado).
    /// Única fuente de verdad: no existe getter del bit `enabled`.
    func disabledByUs() -> [CGDirectDisplayID] {
        var buf = [CGDirectDisplayID](repeating: 0, count: Int(PC_MAX_DISPLAYS))
        let n = pc_state_read(&buf, UInt32(PC_MAX_DISPLAYS))
        return Array(buf.prefix(Int(n)))
    }

    func builtInState() -> BuiltInState {
        // Pregunta específica "¿consta apagada la INTERNA?", no "¿hay algo en
        // el fichero?": selftest puede haber dejado ahí el ID de un externo, y
        // confundir ambas cosas hacía que la barra de menú mintiera.
        if pc_state_builtin_disabled() { return .offByUs }

        let id = builtInID
        if id == 0 { return .missing }

        if CGDisplayMirrorsDisplay(id) != 0 { return .mirroredSlave }
        if pc_builtin_is_mirror_master(id)  { return .mirrorMaster }
        return .on
    }

    var usableExternalCount: UInt32 { pc_usable_external_count() }

    var builtInIsMirrorMaster: Bool { pc_builtin_is_mirror_master(builtInID) }

    /// Delega en el mismo predicado C que usan las herramientas, pero pide el
    /// CÓDIGO en vez del texto: así la app traduce sin duplicar el predicado ni
    /// parsear cadenas. La versión con texto sigue existiendo para probe.
    func canDisableBuiltIn() -> DisableCheck {
        let why = pc_can_disable_builtin_why()
        let s = L10n.t
        let reason: String
        switch why {
        case PC_DENY_OK:            reason = "OK"
        case PC_DENY_ALREADY_OFF:   reason = s.denyAlreadyOff
        case PC_DENY_NO_BUILTIN:    reason = s.denyNoBuiltin
        case PC_DENY_MIRROR_MASTER: reason = s.denyMirrorMaster
        case PC_DENY_NO_EXTERNAL:   reason = s.denyNoExternal
        default:                    reason = s.denyUnknown
        }
        return DisableCheck(allowed: why == PC_DENY_OK, reason: reason, code: why)
    }

    /// Nombre del motivo para el registro: el log se queda monolingüe aunque la
    /// interfaz cambie de idioma.
    private func denyName(_ code: pc_deny_reason) -> String {
        switch code {
        case PC_DENY_OK:            return "OK"
        case PC_DENY_ALREADY_OFF:   return "ALREADY_OFF"
        case PC_DENY_NO_BUILTIN:    return "NO_BUILTIN"
        case PC_DENY_MIRROR_MASTER: return "MIRROR_MASTER"
        case PC_DENY_NO_EXTERNAL:   return "NO_EXTERNAL"
        default:                    return "UNKNOWN"
        }
    }

    // MARK: - Acciones del usuario (las ÚNICAS que pueden apagar — P1)

    func turnOffBuiltIn(completion: @escaping (Result<Void, PantallaError>) -> Void) {
        workQueue.async {
            let result = self.turnOffBuiltInSync()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func turnOffBuiltInSync() -> Result<Void, PantallaError> {
        let check = canDisableBuiltIn()
        guard check.allowed else {
            write("apagado rechazado por la precondición: \(denyName(check.code))")
            return .failure(.preconditionFailed(check.reason))
        }
        let id = builtInID
        guard id != 0 else { return .failure(.preconditionFailed(L10n.t.errBuiltinNotFound)) }

        // P3 — dead-man FUERA de proceso, ANTES de mutar. Si no se puede armar,
        // no se muta: es la única capa que sobrevive a un SIGKILL mientras el
        // experimento de kCGConfigureForAppOnly siga sin confirmar.
        guard armDeadman() else {
            writeProblem("no se pudo armar el dead-man; no se apaga nada")
            return .failure(.deadmanUnavailable)
        }

        // P5 — el ID en disco ANTES de mutar, marcado como interna.
        guard pc_state_add(id, true) else {
            _ = disarmDeadman()
            return .failure(.stateWriteFailed)
        }

        // kCGConfigureForAppOnly. MEDIDO (kill -9): NO revierte el bit privado
        // 'enabled' al morir el proceso — la red real contra SIGKILL es el
        // dead-man. Se mantiene ForAppOnly porque es gratis y no estorba.
        let err = pc_set_display_enabled(id, false, .forAppOnly)
        guard err == .success else {
            pc_state_remove(id)
            _ = disarmDeadman()
            writeProblem("fallo al desactivar \(id): CGError \(err.rawValue)")
            return .failure(.cgError(err))
        }

        // Post-condición con el MISMO predicado que la precondición. Contar
        // displays "activos" no vale: uno dormido sigue en la lista Active, así
        // que desarmaríamos la red con el usuario ya a ciegas.
        //
        // Se sondea hasta 2 s en vez de una única muestra: con un dock, el
        // externo puede tardar en re-asentarse en la lista Active tras la
        // reconfiguración, y una muestra única convertía apagados válidos en
        // reversiones espurias.
        var externalBack = false
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.2)
            if usableExternalCount > 0 { externalBack = true; break }
        }
        if !externalBack {
            writeProblem("post-condición fallida: sin externo utilizable tras 2 s, revirtiendo")
            let reverted = turnOnAllSync()
            // El dead-man sólo se desarma si la reversión funcionó; si falló,
            // que dispare: es la última red que queda.
            if reverted { _ = disarmDeadman() }
            return .failure(.postconditionFailed)
        }

        // Integridad antes de desarmar: si la transacción fue lenta, el
        // dead-man pudo disparar en medio, ver la interna aún online y limpiar
        // el estado — dejando el panel apagado sin su llave en disco.
        if pc_builtin_id() != 0 && CGDisplayIsActive(pc_builtin_id()) != 0 {
            // Alguien (dead-man, rescue manual) re-encendió la interna mientras
            // terminábamos: aceptar la interferencia, no pelear contra ella.
            pc_state_remove(id)
            _ = disarmDeadman()
            writeProblem("interferencia durante el apagado: la interna volvió; se acepta")
            notifyChange()
            return .failure(.preconditionFailed(L10n.t.errInterference))
        }
        if !pc_state_contains(id) {
            write("estado limpiado por un tercero durante el apagado; re-escribiendo la llave")
            _ = pc_state_add(id, true)
        }

        if !disarmDeadman() {
            writeProblem("no se pudo desarmar el dead-man tras un apagado correcto; "
                         + "disparará en ~\(deadmanSeconds) s y re-encenderá la pantalla")
        }
        write("interna \(id) desactivada; externos utilizables: \(usableExternalCount)")
        notifyChange()
        return .success(())
    }

    func turnOnAll(completion: ((Bool) -> Void)? = nil) {
        workQueue.async {
            let ok = self.turnOnAllSync()
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// Variante bloqueante, para `applicationWillTerminate`: allí no hay
    /// ocasión de esperar a una cola de fondo, el proceso se va a morir.
    @discardableResult
    func turnOnAllBlocking() -> Bool {
        return workQueue.sync { self.turnOnAllSync() }
    }

    /// Cuando el rescate resulta imposible (cero pantallas), se deja de
    /// reintentar hasta que vuelva a haber alguna. Reintentar cada 3 s no
    /// arregla nada y llena el log de ruido: medido, ~50 intentos inútiles en
    /// 18 minutos, cada uno bloqueando ~21 s.
    private var isStranded = false

    @discardableResult
    private func turnOnAllSync() -> Bool {
        let r = pc_rescue()
        write("rescate: indicios=\(r.had_evidence) activos \(r.active_before) -> \(r.active_after), "
              + "IDs \(r.targeted_ok)/\(r.targeted_attempts), "
              + "restauración permanente: \(r.used_permanent_restore)")
        if r.stranded {
            if !isStranded {
                isStranded = true
                writeProblem("*** SIN SALIDA POR SOFTWARE *** No queda ninguna pantalla activa y "
                      + "CGSConfigureDisplayEnabled no puede completarse en ese estado. "
                      + "Reconecta el monitor externo (la interna volverá sola) o reinicia. "
                      + "Se dejan de hacer reintentos hasta que haya alguna pantalla.")
            }
        } else {
            isStranded = false
        }
        notifyChange()
        return r.ok
    }

    /// Rompe el espejo cuando la interna es la fuente, para poder apagarla.
    /// Actúa sobre los ESCLAVOS: `CGConfigureDisplayMirrorOfDisplay` aplicada
    /// al master es un no-op silencioso.
    func breakMirror(completion: ((Bool) -> Void)? = nil) {
        workQueue.async {
            let id = self.builtInID
            guard id != 0 else { DispatchQueue.main.async { completion?(false) }; return }
            // ForSession: deshacer el espejo dura hasta cerrar sesión, no se
            // reescribe la configuración permanente del usuario.
            let err = pc_unmirror_slaves_of(id, .forSession)
            let ok = (err == .success) && !pc_builtin_is_mirror_master(id)
            self.write("romper espejo de \(id): CGError \(err.rawValue), resultado \(ok)")
            self.notifyChange()
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    // MARK: - Watchdog (capa 5) — SÓLO ENCIENDE (P1)

    func startWatchdog(onChange: @escaping () -> Void) {
        self.onChange = onChange

        CGDisplayRegisterReconfigurationCallback(pantallaReconfigCallback, nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.evaluateSafety(trigger: "screenParameters")
        }

        // Despertar: comprobar y, si hace falta, ENCENDER. Nunca re-apagar.
        // Un re-aplicador tras el wake sería una carrera contra la
        // re-enumeración del externo (que tarda segundos, más con un dock) y
        // podría dejar cero pantallas justo al abrir la tapa.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.write("wake: comprobando seguridad (nunca se apaga nada automáticamente)")
                self?.evaluateSafety(trigger: "wake")
        }

        // Antes de dormir o apagar: ENCENDER la interna si estaba apagada.
        // Motivo medido: si desconectas el externo con la interna apagada, el
        // hotplug del panel falla y no hay vuelta por software. La mayoría de
        // desconexiones ocurren tras dormir el Mac o cerrar la tapa, así que
        // encender aquí elimina el grueso del riesgo. Coste: al despertar con
        // el monitor puesto, la interna está encendida y re-apagarla es un
        // clic. Es un encendido: P1 lo permite.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.disabledByUs().isEmpty else { return }
                self.write("willSleep: encendiendo la interna por precaución")
                self.turnOnAllBlocking()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.disabledByUs().isEmpty else { return }
                self.write("willPowerOff: encendiendo la interna")
                self.turnOnAllBlocking()
        }

        // Reposo de pantallas del SISTEMA (temporizador de Ajustes): mientras
        // macOS tenga todas las pantallas dormidas a propósito, el watchdog no
        // rescata — el externo aparece dormido, pero no es una emergencia, es
        // la noche. Sin esto, cada periodo de inactividad re-encendía la
        // interna y deshacía el apagado del usuario. El caso "monitor apagado
        // por su botón" NO emite esta notificación, así que sigue cubierto.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.workQueue.async { self?.systemScreensAsleep = true }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.workQueue.async { self?.systemScreensAsleep = false }
                self?.evaluateSafety(trigger: "screensWake")
        }

        // Timer: imprescindible. Un externo que se duerme (DPMS), un KVM
        // conmutado o una entrada de monitor cambiada NO generan callback.
        let t = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.evaluateSafety(trigger: "timer")
        }
        // 10 % de tolerancia (la recomendación de Apple) para que el sistema
        // coalezca despertares y ahorre energía. 3±0,3 s no compromete nada:
        // el watchdog es una red que SOLO enciende (P1), no un plazo — las
        // emergencias de verdad las ven el fast-path del callback CG y el
        // vigía IOKit, no este timer.
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        watchdogTimer = t

        startIOKitWatcher()

        write("watchdog iniciado (callback + screenParameters + wake + timer \(watchdogInterval)s + IOKit)")
    }

    // MARK: - Vigía IOKit (capa 5d)
    //
    // Por qué existe (medido, 2026-08-05): con la interna desactivada, quitar
    // el cable del externo NO llega nunca a CoreGraphics — WindowServer no
    // procesa la desconexión y CG sigue listando el externo como online y
    // activo (zombi). Sin removeFlag y con usables=1, watchdog y fast-path son
    // estructuralmente ciegos. IOKit sí ve el hardware: el DCPAVServiceProxy
    // del externo TERMINA al desenchufar. Y la ventana zombi es la oportunidad:
    // mientras WindowServer aún crea que tiene una pantalla viva, el enable de
    // la interna puede completarse (con 0 pantallas "reales" ya no — el
    // hotplug falla, también medido).

    private var ioNotifyPort: IONotificationPortRef?
    private var ioTerminatedIter: io_iterator_t = 0
    private let ioQueue = DispatchQueue(label: "com.joanplanas.pantallaoff.iokit",
                                        qos: .userInteractive)

    private func startIOKitWatcher() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            writeProblem("vigía IOKit: no se pudo crear el puerto de notificaciones")
            return
        }
        ioNotifyPort = port
        IONotificationPortSetDispatchQueue(port, ioQueue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            IOServiceMatching("DCPAVServiceProxy"),
            { refcon, iterator in
                guard let refcon else { return }
                Unmanaged<DisplayControl>.fromOpaque(refcon).takeUnretainedValue()
                    .ioProxyTerminated(iterator: iterator)
            },
            refcon, &ioTerminatedIter)
        guard kr == KERN_SUCCESS else {
            writeProblem("vigía IOKit: AddMatchingNotification falló (\(kr))")
            IONotificationPortDestroy(port)
            ioNotifyPort = nil
            return
        }
        // Armar la notificación: hay que drenar el iterador inicial.
        var svc = IOIteratorNext(ioTerminatedIter)
        while svc != 0 { IOObjectRelease(svc); svc = IOIteratorNext(ioTerminatedIter) }
        write("vigía IOKit iniciado (terminación de DCPAVServiceProxy)")
    }

    private func ioProxyTerminated(iterator: io_iterator_t) {
        var saw = false
        var svc = IOIteratorNext(iterator)
        while svc != 0 { saw = true; IOObjectRelease(svc); svc = IOIteratorNext(iterator) }
        guard saw else { return }

        guard pc_state_builtin_disabled() else { return }
        pc_log_str("iokit: conexión de vídeo terminada con la interna apagada")

        if externalProxyCount() > 0 {
            pc_log_str("iokit: queda otra conexión externa viva; no se actúa")
            return
        }
        // Ventana zombi: actuar YA, en este mismo hilo.
        emergencyEnableBuiltin(reason: "iokit: desenchufe físico, enable en ventana zombi",
                               alreadyLocked: false)
    }

    private func externalProxyCount() -> Int {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }
        var count = 0
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            if let cf = IORegistryEntryCreateCFProperty(svc, "Location" as CFString,
                                                        kCFAllocatorDefault, 0),
               let loc = cf.takeRetainedValue() as? String, loc == "External" {
                count += 1
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return count
    }

    /// Fast-path de emergencia: se llama SÍNCRONO desde el callback de
    /// reconfiguración cuando un display que no es la interna se está yendo y
    /// nosotros tenemos la interna apagada. Intenta el enable inmediatamente,
    /// dentro de la ventana de la transición, antes de que el sistema quede
    /// sin pantallas (estado del que no hay salida por software — medido).
    private let fastPathLock = NSLock()
    private var fastPathLastAttempt = Date.distantPast

    func fastPathReenable(departing display: CGDirectDisplayID,
                          flags: CGDisplayChangeSummaryFlags) {
        // SÓLO removeFlag. beginConfigurationFlag no dice qué va a cambiar y
        // también se dispara para el externo durante NUESTRO PROPIO apagado de
        // la interna — con P5 (estado escrito antes de mutar), eso hacía que el
        // fast-path deshiciera el apagado a los pocos ms (bug medido en vivo:
        // "flags 1 ... enable(1) -> CGError 0" justo tras cada apagado).
        guard flags.contains(.removeFlag) else { return }
        // Sólo si lo que se va NO es la interna y la interna consta apagada.
        guard CGDisplayIsBuiltin(display) == 0 else { return }
        guard pc_state_builtin_disabled() else { return }

        // Si queda OTRO externo utilizable, no hay emergencia: el usuario
        // sigue viendo algo y encender la interna aquí sería un capricho.
        var online = [CGDirectDisplayID](repeating: 0, count: Int(PC_MAX_DISPLAYS))
        var no: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(PC_MAX_DISPLAYS), &online, &no) == .success {
            for id in online.prefix(Int(no)) where id != display {
                if pc_is_usable_external(id, pc_builtin_id()) { return }
            }
        }

        // Anti-tormenta: el propio enable dispara más callbacks.
        fastPathLock.lock()
        defer { fastPathLock.unlock() }
        guard Date().timeIntervalSince(fastPathLastAttempt) > 1.0 else { return }
        fastPathLastAttempt = Date()

        // alreadyLocked: el candado y el debounce ya se tomaron arriba en esta
        // misma función; NSLock no es reentrante.
        emergencyEnableBuiltin(reason: "fast-path: display \(display) se va (flags \(flags.rawValue))",
                               alreadyLocked: true)
    }

    /// Enciende la interna que consta apagada, YA, en el hilo que sea. Común al
    /// fast-path de CG y al vigía IOKit. ForSession: rápido y suficiente; no
    /// reescribe la configuración permanente del usuario.
    func emergencyEnableBuiltin(reason: String, alreadyLocked: Bool) {
        // OJO con el ámbito del defer: una versión anterior lo tenía DENTRO del
        // `if`, con lo que el candado se soltaba antes de mutar y dos hilos
        // (ioQueue y workQueue) podían entrar a la vez en la transacción CG.
        if alreadyLocked {
            emergencyEnableLocked(reason: reason)
            return
        }
        fastPathLock.lock()
        defer { fastPathLock.unlock() }
        guard Date().timeIntervalSince(fastPathLastAttempt) > 1.0 else { return }
        fastPathLastAttempt = Date()
        emergencyEnableLocked(reason: reason)
    }

    /// Requiere fastPathLock tomado. Reintenta: la notificación IOKit llega UNA
    /// vez, y si el enable falla dentro de la ventana zombi (WindowServer en
    /// plena transición) no habría segunda oportunidad — el watchdog no ayuda
    /// en zombi puro porque sigue viendo el externo como utilizable.
    private func emergencyEnableLocked(reason: String) {
        var entries = [pc_state_entry](repeating: pc_state_entry(), count: Int(PC_MAX_DISPLAYS))
        let n = pc_state_read_entries(&entries, UInt32(PC_MAX_DISPLAYS))
        for e in entries.prefix(Int(n)) where e.was_builtin {
            var err = CGError.failure
            for attempt in 1...3 {
                err = pc_set_display_enabled(e.id, true, .forSession)
                pc_log_str("\(reason); enable(\(e.id)) intento \(attempt) -> CGError \(err.rawValue)")
                if err == .success { break }
                usleep(300_000)
            }
            if err == .success {
                pc_state_remove(e.id)
                notifyChange()
            }
        }
    }

    /// Regla única del watchdog: si tenemos algo apagado y ya no queda ninguna
    /// salida utilizable, encender. Nunca lo contrario (P1).
    ///
    /// TODO se evalúa en workQueue: ninguna llamada a CoreGraphics en el hilo
    /// principal. Si una llamada CG se bloquea (pasa, con WindowServer en
    /// estados raros), que se congele la cola de trabajo — no el timer, ni la
    /// entrega de callbacks, ni la UI.
    func evaluateSafety(trigger: String) {
        workQueue.async { self.evaluateSafetySync(trigger: trigger) }
    }

    /// true mientras macOS tiene las pantallas dormidas por inactividad.
    /// Sólo se toca en workQueue.
    private var systemScreensAsleep = false

    private var heartbeatLast = Date.distantPast
    private var heartbeatSnapshot = ""

    /// IDs de externos online la última vez que miramos (sólo se mantiene
    /// mientras haya algo apagado). Si un ID desaparece del conjunto, el
    /// externo se ha ido O se ha re-registrado con otro ID — ambas cosas se
    /// observaron en los desenchufes reales (2→23 al tirar del cable). Es el
    /// acelerador del caso cable: CG a veces emite este evento al instante,
    /// mientras que la terminación IOKit tarda ~10 s.
    private var knownExternalIDs: Set<CGDirectDisplayID>?

    private func evaluateSafetySync(trigger: String) {
        // Reconciliación continua (antes sólo al arrancar): una entrada cuyo
        // display está online Y activo describe algo que ya no está apagado —
        // p. ej. el enable de willSleep aterrizó pero su remove se perdió en
        // una carrera. Sin esto, la UI mentía hasta relanzar la app. Corre en
        // workQueue, serializada con turnOffBuiltInSync, así que no puede
        // pisar un apagado en vuelo.
        var entries = [pc_state_entry](repeating: pc_state_entry(), count: Int(PC_MAX_DISPLAYS))
        let entryCount = pc_state_read_entries(&entries, UInt32(PC_MAX_DISPLAYS))
        for e in entries.prefix(Int(entryCount)) {
            if CGDisplayIsActive(e.id) != 0 {
                write("reconciliación: \(e.id) está online y activo; su entrada era rancia")
                pc_state_remove(e.id)
                notifyChange()
            }
        }

        guard !disabledByUs().isEmpty else {
            knownExternalIDs = nil
            return
        }

        // Instantánea de lo que ve CoreGraphics. Regla tras el incidente del
        // cable (silencio total en el log durante toda la prueba): mientras
        // haya algo apagado, el log deja constancia SIEMPRE — cada cambio al
        // momento, y un latido cada 30 s aunque no cambie nada. El silencio
        // deja de ser un resultado posible.
        var snap = "cg-ve:"
        var online = [CGDirectDisplayID](repeating: 0, count: Int(PC_MAX_DISPLAYS))
        var no: UInt32 = 0
        let listOK = CGGetOnlineDisplayList(UInt32(PC_MAX_DISPLAYS), &online, &no) == .success
        if listOK {
            for id in online.prefix(Int(no)) {
                snap += " \(id)["
                snap += CGDisplayIsBuiltin(id) != 0 ? "int" : "ext"
                snap += CGDisplayIsActive(id) != 0 ? ",act" : ""
                snap += CGDisplayIsAsleep(id) != 0 ? ",zzz" : ""
                snap += CGDisplayIsInMirrorSet(id) != 0 ? ",mir" : ""
                snap += "]"
            }
        } else {
            snap += " (CGGetOnlineDisplayList FALLÓ)"
        }
        let usable = usableExternalCount
        snap += " usables=\(usable)"

        // Un cambio real se registra siempre: son escasos y valen su línea.
        // El latido periódico —que existía para demostrar que la app no estaba
        // muda durante la caza del zombi— sólo en modo detallado: con una
        // pantalla apagada todo el día generaba ~1.000 líneas diarias.
        if snap != heartbeatSnapshot {
            write("estado (\(trigger)): \(snap)")
            heartbeatSnapshot = snap
            heartbeatLast = Date()
        } else if Self.verboseLogging, Date().timeIntervalSince(heartbeatLast) > 30 {
            write("latido (\(trigger)): \(snap)")
            heartbeatLast = Date()
        }

        // Acelerador: ¿ha desaparecido (o se ha re-registrado) algún externo?
        // Acción = encender: fail-open, un falso positivo cuesta un clic.
        //
        // Guardas: (a) si la enumeración falló, no se evalúa nada — un fallo
        // transitorio de la lista vaciaba el conjunto y disparaba en falso;
        // (b) si sobrevive un externo utilizable cuyo ID ya conocíamos, no hay
        // emergencia — con dos monitores, quitar uno no debe encender la
        // interna. En el re-registro zombi (2→23) el superviviente tiene ID
        // NUEVO, así que ese caso sigue disparando.
        if listOK {
            let currentExternals = Set(online.prefix(Int(no)).filter { CGDisplayIsBuiltin($0) == 0 })
            if let known = knownExternalIDs {
                let vanished = known.subtracting(currentExternals)
                let stableSurvivorUsable = currentExternals.intersection(known)
                    .contains { pc_is_usable_external($0, pc_builtin_id()) }
                if !vanished.isEmpty && !stableSurvivorUsable && pc_state_builtin_disabled() {
                    write("acelerador (\(trigger)): externo(s) \(vanished.sorted()) desaparecido(s) o re-registrado(s)")
                    emergencyEnableBuiltin(reason: "cg-reenum", alreadyLocked: false)
                }
            }
            knownExternalIDs = currentExternals
        }

        guard usable == 0 else { return }

        // Con las pantallas dormidas por el sistema no hay emergencia que
        // rescatar: nadie está mirando. Se re-evalúa en screensWake.
        guard !systemScreensAsleep else { return }

        // Si ya sabemos que estamos sin salida, no reintentar hasta que
        // reaparezca alguna pantalla activa.
        if isStranded && Int(pc_active_display_count()) == 0 { return }

        writeProblem("watchdog (\(trigger)): sin externo utilizable con algo apagado -> reactivando")
        _ = turnOnAllSync()
    }

    private func notifyChange() { DispatchQueue.main.async { self.onChange?() } }

    // MARK: - Dead-man fuera de proceso (capa 3 / P3)

    /// Ruta al binario `rescue`: dentro del bundle o junto al ejecutable.
    var rescueURL: URL? {
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidate = exeDir.appendingPathComponent("rescue")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }

        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("rescue")
        if FileManager.default.isExecutableFile(atPath: home.path) { return home }
        return nil
    }

    /// Devuelve true SÓLO si el proceso salió con código 0. Un fallo aquí
    /// aborta el apagado: no se muta sin red.
    @discardableResult
    private func runRescue(_ args: [String]) -> Bool {
        guard let url = rescueURL else {
            writeProblem("AVISO: no encuentro el binario 'rescue' (dead-man no disponible)")
            return false
        }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            write("AVISO: no se pudo ejecutar rescue \(args): \(error)")
            return false
        }
    }

    private func armDeadman() -> Bool {
        guard runRescue(["--arm", String(deadmanSeconds)]) else { return false }
        // Confirmar que el dead-man existe de verdad y sigue vivo, no fiarse
        // sólo del código de salida del padre.
        let pidFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PC_ARMED_FILE)
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else {
            writeProblem("AVISO: el dead-man no quedó vivo tras armarlo")
            return false
        }
        return true
    }

    private func disarmDeadman() -> Bool { runRescue(["--disarm"]) }

    // MARK: - Log

    /// Registro detallado: añade un latido cada 30 s mientras haya una pantalla
    /// apagada, para poder distinguir "no pasó nada" de "la app estaba muerta".
    /// Desactivado por defecto; se enciende desde ⌥ → Diagnóstico cuando hay
    /// algo que investigar. El fichero rota solo a los 128 KB en cualquier caso.
    static var verboseLogging: Bool {
        get { UserDefaults.standard.bool(forKey: "verboseLogging") }
        set { UserDefaults.standard.set(newValue, forKey: "verboseLogging") }
    }

    /// Últimos eventos, sólo en memoria. En marcha normal no se escribe nada en
    /// disco: si nunca pasa nada raro, el fichero de registro ni se crea.
    ///
    /// Pero cuando algo va mal, lo que hace falta no es el error suelto sino
    /// los minutos anteriores — así fue como se resolvió lo del cable. Por eso
    /// el búfer se vuelca junto con la anomalía en el momento en que ocurre.
    private var ring: [String] = []
    private let ringCapacity = 200
    private let ringLock = NSLock()

    /// Evento normal: a memoria. Sólo llega a disco si luego pasa algo, o si el
    /// registro detallado está activado.
    func write(_ message: String) {
        log.info("\(message, privacy: .public)")

        ringLock.lock()
        ring.append("\(Self.stamp()) \(message)")
        if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
        ringLock.unlock()

        if Self.verboseLogging { pc_log_str(message) }
    }

    /// Anomalía: esto sí va a disco siempre, precedido del contexto reciente.
    /// Reservado para lo que de verdad merece una investigación — rescates que
    /// fallan, quedarse sin salida, errores de CoreGraphics, el dead-man.
    func writeProblem(_ message: String) {
        log.error("\(message, privacy: .public)")

        ringLock.lock()
        let context = ring
        ring.removeAll()
        ringLock.unlock()

        if !Self.verboseLogging && !context.isEmpty {
            pc_log_str("--- contexto previo (\(context.count) eventos en memoria) ---")
            for line in context { pc_log_str("  \(line)") }
            pc_log_str("--- fin del contexto ---")
        }
        pc_log_str("PROBLEMA: \(message)")
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func stamp() -> String { stampFormatter.string(from: Date()) }

}

enum PantallaError: Error {
    case preconditionFailed(String)
    case postconditionFailed
    case stateWriteFailed
    case deadmanUnavailable
    case cgError(CGError)

    var localizedDescription: String {
        switch self {
        case .preconditionFailed(let r): return r
        case .postconditionFailed:       return L10n.t.errPostcondition
        case .stateWriteFailed:          return L10n.t.errStateWrite
        case .deadmanUnavailable:        return L10n.t.errDeadmanUnavailable
        case .cgError(let e):            return L10n.t.errCGError(e.rawValue)
        }
    }
}

/// Callback C de reconfiguración. Debe ser una función global sin capturas.
///
/// El fast-path se ejecuta AQUÍ, en síncrono, no en un dispatch: cuando el
/// externo se está desconectando hay una ventana de milisegundos en la que el
/// panel interno probablemente aún se puede re-enchufar. Una vez el sistema
/// queda sin pantallas, el hotplug del panel falla (medido) y ya no hay vuelta
/// por software. El header dice que los callbacks deberían "evitar" cambiar la
/// configuración — es la emergencia exacta que justifica saltárselo; si la
/// llamada anidada falla, se registra y el watchdog sigue de respaldo.
///
/// SÓLO sobre removeFlag: beginConfigurationFlag también se dispara para el
/// externo durante nuestro propio apagado de la interna y deshacía el apagado.
private func pantallaReconfigCallback(display: CGDirectDisplayID,
                                      flags: CGDisplayChangeSummaryFlags,
                                      userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.removeFlag) {
        DisplayControl.shared.fastPathReenable(departing: display, flags: flags)
    }
    DispatchQueue.main.async {
        DisplayControl.shared.evaluateSafety(trigger: "reconfig(\(display))")
    }
}
