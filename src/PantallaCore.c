#include "PantallaCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

/* ===========================================================================
 * Enumeración
 * ======================================================================== */

static uint32_t pc_active_list(CGDirectDisplayID *out, uint32_t cap) {
    uint32_t n = 0;
    if (CGGetActiveDisplayList(cap, out, &n) != kCGErrorSuccess) return 0;
    return n;
}

static uint32_t pc_online_list(CGDirectDisplayID *out, uint32_t cap) {
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(cap, out, &n) != kCGErrorSuccess) return 0;
    return n;
}

static bool pc_in_active_list(CGDirectDisplayID id) {
    CGDirectDisplayID act[PC_MAX_DISPLAYS];
    uint32_t n = pc_active_list(act, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) if (act[i] == id) return true;
    return false;
}

static bool pc_in_online_list(CGDirectDisplayID id) {
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = pc_online_list(on, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) if (on[i] == id) return true;
    return false;
}

uint32_t pc_snapshot(pc_display *out, uint32_t cap) {
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = pc_online_list(on, PC_MAX_DISPLAYS);
    if (n > cap) n = cap;

    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID d = on[i];
        out[i].id            = d;
        out[i].builtin       = CGDisplayIsBuiltin(d);
        out[i].online        = true;
        out[i].active        = CGDisplayIsActive(d);
        out[i].asleep        = CGDisplayIsAsleep(d);
        out[i].in_mirror_set = CGDisplayIsInMirrorSet(d);
        out[i].mirrors       = CGDisplayMirrorsDisplay(d);
        out[i].vendor        = CGDisplayVendorNumber(d);
        out[i].px_w          = CGDisplayPixelsWide(d);
        out[i].px_h          = CGDisplayPixelsHigh(d);
    }
    return n;
}

CGDirectDisplayID pc_builtin_id(void) {
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = pc_online_list(on, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayIsBuiltin(on[i])) return on[i];
    }
    return kCGNullDirectDisplay;
}

bool pc_is_laptop(void) {
    char model[256];
    size_t len = sizeof model;
    if (sysctlbyname("hw.model", model, &len, NULL, 0) != 0) return false;
    model[sizeof model - 1] = '\0';
    return strstr(model, "Book") != NULL;
}

/* ===========================================================================
 * Predicado de seguridad
 * ======================================================================== */

bool pc_is_usable_external(CGDirectDisplayID id, CGDirectDisplayID builtin_id) {
    if (id == kCGNullDirectDisplay)        return false;
    if (CGDisplayIsBuiltin(id))            return false;
    /* Los displays virtuales / dummy no tienen vendor. No cuentan como
     * pantalla real en la que el usuario pueda ver algo. */
    if (CGDisplayVendorNumber(id) == 0)    return false;
    /* Active, NO Online: bajo espejo hardware el esclavo desaparece de la
     * lista Active. Usar Online aquí era el bug de la v1. */
    if (!pc_in_active_list(id))            return false;
    if (CGDisplayIsAsleep(id))             return false;
    /* Si este externo es esclavo de un espejo cuya fuente es la interna,
     * apagar la interna lo deja sin fuente: no cuenta como salida válida. */
    if (builtin_id != kCGNullDirectDisplay &&
        CGDisplayMirrorsDisplay(id) == builtin_id) return false;
    return true;
}

uint32_t pc_usable_external_count(void) {
    CGDirectDisplayID builtin = pc_builtin_id();
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = pc_online_list(on, PC_MAX_DISPLAYS), count = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (pc_is_usable_external(on[i], builtin)) count++;
    }
    return count;
}

bool pc_builtin_is_mirror_master(CGDirectDisplayID builtin_id) {
    if (builtin_id == kCGNullDirectDisplay)                       return false;
    if (!CGDisplayIsInMirrorSet(builtin_id))                      return false;
    if (CGDisplayMirrorsDisplay(builtin_id) != kCGNullDirectDisplay) return false;

    /* Lo anterior no basta. Con las pantallas dormidas, TODOS los displays
     * pueden reportar a la vez inMirrorSet=1 y mirrors=0, y entonces este
     * criterio marcaría como "master" a cualquiera. Exigimos la prueba
     * positiva: que alguien declare estar espejando a la interna. */
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = pc_online_list(on, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) {
        if (on[i] == builtin_id) continue;
        if (CGDisplayMirrorsDisplay(on[i]) == builtin_id) return true;
    }
    return false;
}

bool pc_can_disable_builtin(char *reason, size_t reason_len) {
    CGDirectDisplayID builtin = pc_builtin_id();

    if (pc_state_builtin_disabled()) {
        snprintf(reason, reason_len, "La pantalla interna ya está apagada");
        return false;
    }
    if (builtin == kCGNullDirectDisplay) {
        snprintf(reason, reason_len, "No se encuentra la pantalla interna");
        return false;
    }
    /* El espejo se comprueba ANTES que la disponibilidad de externos: si la
     * interna es la fuente del espejo, su único externo es forzosamente su
     * esclavo y por tanto no cuenta como utilizable. Con el orden inverso el
     * usuario siempre leería "sin pantalla externa", que es un motivo
     * engañoso, en vez del motivo real y accionable. */
    if (pc_builtin_is_mirror_master(builtin)) {
        snprintf(reason, reason_len,
                 "La pantalla interna es la fuente del espejo: rompe el espejo primero");
        return false;
    }
    if (pc_usable_external_count() == 0) {
        snprintf(reason, reason_len,
                 "Sin pantalla externa utilizable (desconectada, dormida o virtual)");
        return false;
    }
    snprintf(reason, reason_len, "OK");
    return true;
}

/* ===========================================================================
 * Mutación — un único wrapper de transacción
 * ======================================================================== */

typedef CGError (*pc_config_block)(CGDisplayConfigRef cfg, void *ctx);

/* begin -> bloque -> complete.
 *
 * Se cancela SÓLO si el fallo es anterior a Complete. Tras
 * CGCompleteDisplayConfiguration la referencia queda inválida pase lo que pase
 * (header del SDK: "On return, the configuration is no longer valid"), así que
 * cancelarla después sería usar una referencia ya liberada. */
static CGError pc_with_config(pc_config_block block, void *ctx,
                              CGConfigureOption option) {
    CGDisplayConfigRef cfg = NULL;
    CGError err = CGBeginDisplayConfiguration(&cfg);
    if (err != kCGErrorSuccess) return err;

    err = block(cfg, ctx);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(cfg);   /* Complete aún no se ha llamado */
        return err;
    }
    return CGCompleteDisplayConfiguration(cfg, option);
}

typedef struct { CGDirectDisplayID id; bool enabled; } pc_enable_ctx;

static CGError pc_enable_block(CGDisplayConfigRef cfg, void *ctx) {
    pc_enable_ctx *c = (pc_enable_ctx *)ctx;
    return CGSConfigureDisplayEnabled(cfg, c->id, c->enabled);
}

CGError pc_set_display_enabled(CGDirectDisplayID id, bool enabled,
                               CGConfigureOption option) {
    pc_enable_ctx ctx = { id, enabled };
    return pc_with_config(pc_enable_block, &ctx, option);
}

static CGError pc_unmirror_block(CGDisplayConfigRef cfg, void *ctx) {
    CGDirectDisplayID master = *(CGDirectDisplayID *)ctx;
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = pc_online_list(on, PC_MAX_DISPLAYS);
    CGError last = kCGErrorSuccess;
    bool touched = false;

    for (uint32_t i = 0; i < n; i++) {
        if (on[i] == master) continue;
        if (CGDisplayMirrorsDisplay(on[i]) != master) continue;
        /* La llamada se aplica al ESCLAVO. Pasarle el master sería un no-op. */
        CGError e = CGConfigureDisplayMirrorOfDisplay(cfg, on[i], kCGNullDirectDisplay);
        touched = true;
        if (e != kCGErrorSuccess) last = e;
    }
    if (!touched) return kCGErrorIllegalArgument;   /* nadie espejaba a `master` */
    return last;
}

CGError pc_unmirror_slaves_of(CGDirectDisplayID master, CGConfigureOption option) {
    return pc_with_config(pc_unmirror_block, &master, option);
}

/* ===========================================================================
 * Estado persistido
 * ======================================================================== */

bool pc_home_path(const char *filename, char *out, size_t out_len) {
    const char *home = getenv("HOME");
    if (!home || !*home) return false;
    int written = snprintf(out, out_len, "%s/%s", home, filename);
    return written > 0 && (size_t)written < out_len;
}

uint32_t pc_state_read_entries(pc_state_entry *out, uint32_t cap) {
    char path[1024];
    if (!pc_home_path(PC_STATE_FILE, path, sizeof path)) return 0;

    FILE *f = fopen(path, "r");
    if (!f) return 0;

    uint32_t count = 0;
    char line[256];
    while (count < cap && fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue;
        unsigned long v = 0;
        int b = 0;
        if (sscanf(line, "disabled=%lu builtin=%d", &v, &b) >= 1 && v != 0) {
            out[count].id = (CGDirectDisplayID)v;
            out[count].was_builtin = (b != 0);
            count++;
        }
    }
    fclose(f);
    return count;
}

uint32_t pc_state_read(CGDirectDisplayID *out, uint32_t cap) {
    pc_state_entry e[PC_MAX_DISPLAYS];
    uint32_t n = pc_state_read_entries(e, PC_MAX_DISPLAYS);
    if (n > cap) n = cap;
    for (uint32_t i = 0; i < n; i++) out[i] = e[i].id;
    return n;
}

bool pc_state_builtin_disabled(void) {
    pc_state_entry e[PC_MAX_DISPLAYS];
    uint32_t n = pc_state_read_entries(e, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) if (e[i].was_builtin) return true;
    return false;
}

/* Escritura atómica y DURABLE: fsync antes del rename y fsync del directorio.
 * P5 exige que el ID esté realmente en disco antes de tocar el display; si el
 * proceso muere durante CGCompleteDisplayConfiguration, el rescate tiene que
 * poder encontrarlo. */
static bool pc_state_write(const pc_state_entry *e, uint32_t n) {
    char path[1024], tmp[1088];
    if (!pc_home_path(PC_STATE_FILE, path, sizeof path)) return false;
    snprintf(tmp, sizeof tmp, "%s.tmp", path);

    FILE *f = fopen(tmp, "w");
    if (!f) return false;
    fprintf(f, "# PantallaOff — displays desactivados por nosotros.\n"
               "# NO BORRAR mientras alguna pantalla esté apagada: es lo que\n"
               "# permite volver a encenderla. Si lo pierdes: ~/rescue --restore\n");
    fprintf(f, "ts=%lld\n", (long long)time(NULL));
    for (uint32_t i = 0; i < n; i++) {
        fprintf(f, "disabled=%u builtin=%d\n", e[i].id, e[i].was_builtin ? 1 : 0);
    }

    if (fflush(f) != 0)        { fclose(f); unlink(tmp); return false; }
    if (fsync(fileno(f)) != 0) { fclose(f); unlink(tmp); return false; }
    if (fclose(f) != 0)        { unlink(tmp); return false; }
    if (rename(tmp, path) != 0){ unlink(tmp); return false; }

    const char *home = getenv("HOME");
    if (home) {
        int dfd = open(home, O_RDONLY);
        if (dfd >= 0) { fsync(dfd); close(dfd); }
    }
    return true;
}

bool pc_state_contains(CGDirectDisplayID id) {
    pc_state_entry e[PC_MAX_DISPLAYS];
    uint32_t n = pc_state_read_entries(e, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) if (e[i].id == id) return true;
    return false;
}

bool pc_state_add(CGDirectDisplayID id, bool was_builtin) {
    pc_state_entry e[PC_MAX_DISPLAYS];
    uint32_t n = pc_state_read_entries(e, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) {
        if (e[i].id == id) { e[i].was_builtin = was_builtin; return pc_state_write(e, n); }
    }
    if (n >= PC_MAX_DISPLAYS) return false;
    e[n].id = id; e[n].was_builtin = was_builtin; n++;
    return pc_state_write(e, n);
}

bool pc_state_remove(CGDirectDisplayID id) {
    pc_state_entry e[PC_MAX_DISPLAYS], keep[PC_MAX_DISPLAYS];
    uint32_t n = pc_state_read_entries(e, PC_MAX_DISPLAYS), k = 0;
    for (uint32_t i = 0; i < n; i++) if (e[i].id != id) keep[k++] = e[i];
    if (k == n) return true;
    return pc_state_write(keep, k);
}

bool pc_state_clear(void) { return pc_state_write(NULL, 0); }

/* ===========================================================================
 * Rescate
 * ======================================================================== */

static uint32_t pc_active_count(void) {
    CGDirectDisplayID act[PC_MAX_DISPLAYS];
    return pc_active_list(act, PC_MAX_DISPLAYS);
}

/* Online, inactivo y fuera de todo mirror set: sospechoso de estar desactivado.
 * Los esclavos de espejo se excluyen a propósito — también salen de la lista
 * Active, pero su panel está encendido y tocarlos rehace la configuración de
 * espejo del usuario sin que nadie lo haya pedido. */
static bool pc_is_rescue_candidate(CGDirectDisplayID id) {
    return !CGDisplayIsActive(id) && !CGDisplayIsInMirrorSet(id);
}

bool pc_rescue_evidence(void) {
    pc_state_entry e[PC_MAX_DISPLAYS];
    if (pc_state_read_entries(e, PC_MAX_DISPLAYS) > 0) return true;

    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = pc_online_list(on, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) if (pc_is_rescue_candidate(on[i])) return true;

    /* En un portátil siempre hay pantalla interna. Que no aparezca en la lista
     * online sólo puede significar que está desactivada — y es la única señal
     * que sigue funcionando si se pierde el fichero de estado. */
    if (pc_is_laptop() && pc_builtin_id() == kCGNullDirectDisplay) return true;

    return false;
}

pc_rescue_result pc_rescue_ex(bool force_restore) {
    pc_rescue_result r;
    memset(&r, 0, sizeof r);
    r.active_before = pc_active_count();
    r.had_evidence  = pc_rescue_evidence();

    /* Salida temprana: sin indicios, NO TOCAR NADA.
     *
     * Importa porque `rescue` es lo que el usuario va a teclear a ciegas, y el
     * momento típico para hacerlo es con las pantallas dormidas — donde
     * active_before vale 0 sin que nada esté roto. Escalar por "0 activos"
     * rehacía la configuración permanente del usuario sin motivo. */
    if (!r.had_evidence && !force_restore) {
        r.active_after = r.active_before;
        r.ok = true;
        return r;
    }

    pc_state_entry st[PC_MAX_DISPLAYS];
    uint32_t n = pc_state_read_entries(st, PC_MAX_DISPLAYS);
    r.targeted_attempts = n;

    /* 1. IDs persistidos: el único camino para un display que ya desapareció
     *    de la lista online, que es exactamente lo que le pasa a uno
     *    desactivado.
     *
     *    Permanently, no ForAppOnly: con ForAppOnly el enable se revertiría al
     *    salir este mismo proceso de rescate. */
    for (uint32_t i = 0; i < n; i++) {
        CGError e = pc_set_display_enabled(st[i].id, true, kCGConfigurePermanently);
        /* El código de error importa: en el incidente del 2026-08-04 no se
         * registró y costó saber si fallaba Begin, el set o Complete. */
        if (e != kCGErrorSuccess) {
            pc_log("rescate: enable(%u) -> CGError %d (%s)",
                   st[i].id, e, pc_cgerror_name(e));
        }
    }

    /* 2. Barrido acotado a los sospechosos. */
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t no = pc_online_list(on, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < no; i++) {
        if (pc_is_rescue_candidate(on[i])) {
            pc_set_display_enabled(on[i], true, kCGConfigurePermanently);
        }
    }

    /* Éxito real = el ID ha vuelto a la lista online, no que la transacción
     * devolviera kCGErrorSuccess. */
    for (uint32_t i = 0; i < n; i++) {
        if (pc_in_online_list(st[i].id)) { r.targeted_ok++; pc_state_remove(st[i].id); }
    }

    /* 3. Martillo público: sólo si algo sigue sin volver, o si nos lo piden. */
    bool unrecovered = (r.targeted_ok < r.targeted_attempts);
    bool laptop_builtin_missing = pc_is_laptop() && pc_builtin_id() == kCGNullDirectDisplay;
    if (force_restore || unrecovered || laptop_builtin_missing || pc_active_count() == 0) {
        CGRestorePermanentDisplayConfiguration();
        r.used_permanent_restore = true;
        sleep(1);
        for (uint32_t i = 0; i < n; i++) {
            if (pc_in_online_list(st[i].id)) pc_state_remove(st[i].id);
        }
        r.targeted_ok = 0;
        for (uint32_t i = 0; i < n; i++) if (pc_in_online_list(st[i].id)) r.targeted_ok++;
    }

    r.active_after = pc_active_count();
    r.ok = (r.active_after > 0) && (r.targeted_ok >= r.targeted_attempts);

    /* Cero pantallas antes y cero después: estamos en el estado que NO tiene
     * salida por software (ver la nota en el .h). Marcarlo explícitamente para
     * que quien llame deje de reintentar y diga al usuario qué hacer, en vez
     * de martillear el WindowServer cada pocos segundos. */
    r.stranded = (r.active_before == 0 && r.active_after == 0);
    if (r.stranded) {
        /* Medido y contrastado con los logs de WindowServer de un caso idéntico
         * (BetterDisplay#5658): el enable llega, pero el hotplug del panel
         * falla en la capa IOMFB ("Failed to plug display 1"). Reintentar es
         * inútil. Las salidas reales, por orden: reconectar un monitor,
         * `sudo killall -HUP WindowServer` por SSH (logout, ~10 s, sin
         * reiniciar), o reiniciar. */
        pc_log("SIN SALIDA POR ENABLE: 0 pantallas activas; el hotplug del panel "
               "falla en WindowServer. Reconecta un monitor, o por SSH: "
               "sudo killall -HUP WindowServer (logout sin reinicio).");
    }
    return r;
}

pc_rescue_result pc_rescue(void) { return pc_rescue_ex(false); }

/* ===========================================================================
 * Utilidades
 * ======================================================================== */

/* Rotación simple: al pasar de PC_LOG_MAX_BYTES, el fichero actual pasa a .1 y
 * se empieza de cero. Dos ficheros son suficientes — esto es un registro de
 * diagnóstico, no un histórico. El tope garantiza que nunca crezca sin freno. */
#define PC_LOG_MAX_BYTES (128 * 1024)

static void pc_log_rotate_if_needed(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return;
    if (st.st_size < PC_LOG_MAX_BYTES) return;

    char previous[1200];
    snprintf(previous, sizeof previous, "%s.1", path);
    rename(path, previous);
}

void pc_log(const char *fmt, ...) {
    char path[1024];
    if (!pc_home_path("Library/Logs/PantallaOff.log", path, sizeof path)) return;
    pc_log_rotate_if_needed(path);
    FILE *f = fopen(path, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm tm;
    char stamp[32];
    gmtime_r(&now, &tm);
    strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", &tm);
    fprintf(f, "%s ", stamp);

    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);

    fprintf(f, "\n");
    fclose(f);
}

void pc_log_str(const char *message) {
    pc_log("%s", message ? message : "(null)");
}

const char *pc_cgerror_name(CGError e) {
    switch (e) {
        case kCGErrorSuccess:           return "success";
        case kCGErrorFailure:           return "failure";
        case kCGErrorIllegalArgument:   return "illegalArgument";
        case kCGErrorInvalidConnection: return "invalidConnection";
        case kCGErrorInvalidContext:    return "invalidContext";
        case kCGErrorCannotComplete:    return "cannotComplete";
        case kCGErrorNotImplemented:    return "notImplemented";
        case kCGErrorRangeCheck:        return "rangeCheck";
        case kCGErrorTypeCheck:         return "typeCheck";
        case kCGErrorInvalidOperation:  return "invalidOperation";
        case kCGErrorNoneAvailable:     return "noneAvailable";
        default:                        return "unknown";
    }
}
