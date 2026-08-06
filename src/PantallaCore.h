/*
 * PantallaCore — núcleo compartido de PantallaOff.
 *
 * Este fichero es la ÚNICA implementación del predicado de seguridad y de la
 * mutación de displays. Lo usan tanto las herramientas C (probe/rescue/selftest)
 * como la app Swift (vía src/Bridge.h). No duplicar esta lógica en Swift.
 *
 * Principios (ver el plan v2):
 *   P1 fail-open   — ninguna ruta automática puede desactivar un display.
 *   P2 rescate     — no depende de enumerar; usa API pública + ID persistido.
 *   P3 dead-man    — fuera de proceso.
 *   P4 externo 1º  — validar contra el externo antes de tocar la interna.
 *   P5 estado      — se escribe a disco ANTES de mutar.
 */
#ifndef PANTALLA_CORE_H
#define PANTALLA_CORE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stddef.h>

/* ---------------------------------------------------------------------------
 * API privada de CoreGraphics.
 *
 * Verificado en macOS 26.6 / arm64: el símbolo está exportado en
 * CoreGraphics.tbd del SDK y enlaza estáticamente. No hace falta dlsym.
 *
 * OJO: existe el setter pero NO existe ningún getter (`CGSGetDisplayEnabled` no
 * está en el .tbd). Por eso el estado se persiste a disco: es imposible
 * preguntarle al sistema si un display está desactivado por nosotros.
 * ------------------------------------------------------------------------- */
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

#define PC_MAX_DISPLAYS 16

/* Rutas de estado (bajo $HOME). */
#define PC_STATE_FILE  ".pantallaoff-state"   /* IDs desactivados por nosotros  */
#define PC_ARMED_FILE  ".pantallaoff-armed"   /* PID del dead-man armado        */

typedef struct {
    CGDirectDisplayID id;
    bool     builtin;
    bool     active;
    bool     asleep;
    bool     in_mirror_set;
    CGDirectDisplayID mirrors;   /* 0 = no es esclavo de nadie */
    uint32_t vendor;
    size_t   px_w, px_h;
} pc_display;

/* --- Enumeración --------------------------------------------------------- */

uint32_t pc_snapshot(pc_display *out, uint32_t cap);

/* ID de la pantalla interna, o kCGNullDirectDisplay si no hay/desapareció.
 * OJO: si la interna está desactivada, sale de la lista online y esto
 * devuelve 0. Para el rescate hay que usar el ID persistido, no esto. */
CGDirectDisplayID pc_builtin_id(void);

/* --- Predicado de seguridad (el corazón del proyecto) -------------------- */

/* Un externo es UTILIZABLE si:
 *   - no es la interna
 *   - con vendor 0, exige tamaño EDID real (≠ estimación 72 dpi): un panel
 *     físico lo declara; por HDMI el vendor llega a 0 en monitores reales
 *   - está en CGGetActiveDisplayList  <-- Active, NO Online.
 *   - no está dormido (cubre DPMS / monitor apagado por su botón)
 *   - no es esclavo de un espejo cuya fuente es la interna
 */
bool pc_is_usable_external(CGDirectDisplayID id, CGDirectDisplayID builtin_id);

uint32_t pc_usable_external_count(void);

/* Displays en la lista Active. */
uint32_t pc_active_display_count(void);

/* ¿La interna es la FUENTE de un mirror set?
 *
 * No basta con `inMirrorSet && mirrors == 0`: cuando las pantallas se duermen,
 * TODOS los displays pueden reportar `inMirrorSet=1, mirrors=0` a la vez, y ese
 * criterio da un falso positivo. Se exige además que exista otro display online
 * que declare explícitamente estar espejando a la interna. */
bool pc_builtin_is_mirror_master(CGDirectDisplayID builtin_id);

/* Motivo por el que no se puede apagar la interna.
 *
 * El código va aparte del texto para que la app pueda traducirlo sin duplicar
 * el predicado ni, peor, parsear cadenas. Las herramientas C siguen usando la
 * versión con texto, que se implementa encima de ésta. */
typedef enum {
    PC_DENY_OK = 0,          /* sí se puede apagar                            */
    PC_DENY_ALREADY_OFF,     /* ya consta apagada por nosotros                */
    PC_DENY_NO_BUILTIN,      /* no se encuentra la pantalla interna           */
    PC_DENY_MIRROR_MASTER,   /* la interna es la fuente de una duplicación    */
    PC_DENY_NO_EXTERNAL,     /* sin externo utilizable donde seguir viendo    */
} pc_deny_reason;

pc_deny_reason pc_can_disable_builtin_why(void);

/* ¿Se puede apagar la interna ahora mismo?
 * Si devuelve false, escribe en `reason` un motivo legible EN ESPAÑOL. Para la
 * app usa `pc_can_disable_builtin_why` y traduce el código. */
bool pc_can_disable_builtin(char *reason, size_t reason_len);

/* --- Mutación ------------------------------------------------------------ */

/* Toda mutación pasa por un único helper interno: begin -> bloque -> complete,
 * cancelando la transacción SÓLO si el fallo ocurre antes de llamar a Complete.
 *
 * (Tras CGCompleteDisplayConfiguration la referencia queda inválida haya ido
 * bien o mal — así lo dice el header del SDK: "On return, the configuration is
 * no longer valid" — así que cancelarla después sería usar memoria liberada.)
 *
 * `option` importa mucho:
 *   kCGConfigureForAppOnly  -> para DESACTIVAR desde la app. OJO, MEDIDO
 *                              (2026-08-04, kill -9): el WindowServer revierte
 *                              modo y topología al morir el proceso, pero NO el
 *                              bit privado 'enabled'. NO es una red contra
 *                              SIGKILL; la red real es el dead-man. Se mantiene
 *                              ForAppOnly porque es gratis y no estorba.
 *   kCGConfigurePermanently -> persiste y además pasa a ser la config de sesión.
 *                              Úsalo para ACTIVAR desde el rescate: si el
 *                              rescate usara ForAppOnly, el enable se revertiría
 *                              al salir el propio proceso de rescate.
 */
CGError pc_set_display_enabled(CGDirectDisplayID id, bool enabled,
                               CGConfigureOption option);

/* Saca del mirror set a todos los esclavos cuya fuente sea `master`.
 *
 * CGConfigureDisplayMirrorOfDisplay se aplica al ESCLAVO, no al master: pasarle
 * el master es un no-op silencioso. Por eso esta función itera los esclavos. */
CGError pc_unmirror_slaves_of(CGDirectDisplayID master, CGConfigureOption option);

/* --- Estado persistido (P5) ---------------------------------------------- */

typedef struct {
    CGDirectDisplayID id;
    bool was_builtin;   /* si el ID era la pantalla interna al desactivarla */
    unsigned tries;     /* intentos fallidos de reactivación (para podar
                           entradas rancias de externos; la interna no se
                           poda jamás) */
} pc_state_entry;

uint32_t pc_state_read(CGDirectDisplayID *out, uint32_t cap);
uint32_t pc_state_read_entries(pc_state_entry *out, uint32_t cap);

/* Añade un ID al estado. Llamar SIEMPRE ANTES de mutar. */
bool pc_state_add(CGDirectDisplayID id, bool was_builtin);

bool pc_state_remove(CGDirectDisplayID id);
bool pc_state_contains(CGDirectDisplayID id);

/* ¿Consta la PANTALLA INTERNA como desactivada por nosotros?
 *
 * Distinto de "hay algo en el fichero": selftest puede haber dejado ahí el ID
 * de un monitor externo, y confundir ambas cosas hace que la UI mienta. */
bool pc_state_builtin_disabled(void);

/* --- Rescate (P2) -------------------------------------------------------- */

typedef struct {
    bool     ok;
    uint32_t targeted_attempts;
    uint32_t targeted_ok;          /* IDs que volvieron a estar ONLINE de verdad */
    bool     used_permanent_restore;
    bool     had_evidence;         /* había motivos para creer que algo estaba apagado */
    bool     stranded;             /* cero pantallas y no se pudo recuperar ninguna */
    uint32_t active_before, active_after;
} pc_rescue_result;

/* LIMITACIÓN MEDIDA (2026-08-04, macOS 26.6):
 *
 * Con CERO pantallas activas, `CGSConfigureDisplayEnabled(id, true)` NO puede
 * completarse. El WindowServer necesita al menos un display vivo para aceptar
 * un cambio de configuración. Medido en vivo: ~50 intentos durante 18 minutos,
 * todos devolviendo `activos 0 -> 0`, incluido
 * CGRestorePermanentDisplayConfiguration(). El sistema sólo se recuperó al
 * reconectar físicamente el monitor externo.
 *
 * Consecuencia: si te quedas sin ninguna pantalla, el rescate por software es
 * imposible. Las únicas salidas son reconectar un monitor o reiniciar. */

/* Reactiva lo que pueda. Si `force_restore`, usa el martillo público
 * (CGRestorePermanentDisplayConfiguration) sin pedir indicios. */
pc_rescue_result pc_rescue_ex(bool force_restore);
pc_rescue_result pc_rescue(void);   /* = pc_rescue_ex(false) */

/* --- Utilidades ---------------------------------------------------------- */

bool pc_home_path(const char *filename, char *out, size_t out_len);
const char *pc_cgerror_name(CGError e);

/* Añade una línea a ~/Library/Logs/PantallaOff.log, para que app y dead-man
 * compartan un único registro cronológico. El disparo del dead-man no tiene
 * terminal: sin log, sería invisible. */
void pc_log(const char *fmt, ...) __printflike(1, 2);

/* Variante no variádica: Swift no puede importar funciones variádicas de C. */
void pc_log_str(const char *message);

#endif /* PANTALLA_CORE_H */
