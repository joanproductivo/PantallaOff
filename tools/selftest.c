/*
 * selftest — valida CGSConfigureDisplayEnabled contra UN display concreto.
 *
 *   selftest <displayID> <segundos>     apaga N s y reactiva
 *   selftest <displayID> hold           apaga y se queda vivo (para el
 *                                       experimento de kill -9)
 *
 * Opciones:
 *   --session        usa kCGConfigureForSession en vez de ForAppOnly
 *   --allow-builtin  permite apuntar a la pantalla INTERNA (por defecto se niega)
 *
 * P4: por defecto sólo deja apuntar al display EXTERNO, que es el único de esta
 * máquina con recuperación física garantizada (hotplug). La interna de un
 * MacBook no se puede reconectar: si algo sale mal, no hay plan B por hardware.
 *
 * El experimento de la capa 4 YA SE EJECUTÓ (2026-08-04, macOS 26.6):
 *     ./selftest <idExterno> hold  +  kill -9 <pid>
 *   Resultado: el display NO volvió (12 s después seguía desaparecido).
 *   kCGConfigureForAppOnly revierte modo y topología pero NO el bit privado
 *   'enabled'. Conclusión vigente: la única red contra SIGKILL es el dead-man.
 *   El modo hold se conserva para poder reproducir la medición.
 */
#include "../src/PantallaCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <libgen.h>
#include <spawn.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

extern char **environ;

static CGDirectDisplayID g_target = kCGNullDirectDisplay;
static volatile sig_atomic_t g_interrupted = 0;

/* ¿Quedaría alguna pantalla REALMENTE utilizable si desactivásemos `target`?
 *
 * Se apoya en el mismo predicado compartido que usa la app, no en un simple
 * conteo de la lista Active: un display dormido por DPMS sigue apareciendo en
 * Active, así que contar a secas dejaría pasar el caso de "sobrevive uno, pero
 * está apagado y no ves nada". */
static uint32_t survivors_excluding(CGDirectDisplayID target) {
    CGDirectDisplayID builtin = pc_builtin_id();
    CGDirectDisplayID on[PC_MAX_DISPLAYS];
    uint32_t n = 0, count = 0;
    if (CGGetOnlineDisplayList(PC_MAX_DISPLAYS, on, &n) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < n; i++) {
        if (on[i] == target) continue;
        if (pc_is_usable_external(on[i], builtin)) { count++; continue; }
        /* La interna cuenta como superviviente si está activa y despierta. */
        if (on[i] == builtin && CGDisplayIsActive(on[i]) && !CGDisplayIsAsleep(on[i])) {
            count++;
        }
    }
    return count;
}

static void restore_now(void) {
    if (g_target == kCGNullDirectDisplay) return;
    /* ForSession, no Permanently: una prueba de 6 segundos no debe reescribir
     * la configuración permanente del usuario. Basta con deshacer nuestro
     * propio ForAppOnly durante esta sesión. */
    pc_set_display_enabled(g_target, true, kCGConfigureForSession);
    pc_state_remove(g_target);
    g_target = kCGNullDirectDisplay;
}

static void on_signal(int sig) { (void)sig; g_interrupted = 1; }

/* Lanza `rescue --arm N` o `--disarm`, buscando el binario junto a este.
 * Devuelve true sólo si el rescate salió con código 0. */
static bool deadman(const char *flag, int seconds) {
    char self[4096];
    uint32_t size = sizeof self;
    if (_NSGetExecutablePath(self, &size) != 0) return false;

    char copy[4096];
    snprintf(copy, sizeof copy, "%s", self);
    char rescue_path[4200];
    snprintf(rescue_path, sizeof rescue_path, "%s/rescue", dirname(copy));

    char secs[32];
    snprintf(secs, sizeof secs, "%d", seconds);
    char *argv[] = { rescue_path, (char *)flag, secs, NULL };
    if (strcmp(flag, "--disarm") == 0) argv[2] = NULL;

    pid_t pid = 0;
    if (posix_spawn(&pid, rescue_path, NULL, NULL, argv, environ) != 0) {
        fprintf(stderr, "no se pudo ejecutar %s (%s)\n", rescue_path, flag);
        return false;
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return false;
    return WIFEXITED(st) && WEXITSTATUS(st) == 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr,
            "uso: selftest <displayID> <segundos|hold> [--session] [--allow-builtin]\n");
        return 2;
    }

    CGDirectDisplayID target = (CGDirectDisplayID)strtoul(argv[1], NULL, 10);
    bool hold = (strcmp(argv[2], "hold") == 0);
    int seconds = hold ? 0 : atoi(argv[2]);
    CGConfigureOption option = kCGConfigureForAppOnly;
    bool allow_builtin = false;

    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--session") == 0)       option = kCGConfigureForSession;
        else if (strcmp(argv[i], "--allow-builtin") == 0) allow_builtin = true;
        else { fprintf(stderr, "opción desconocida: %s\n", argv[i]); return 2; }
    }
    if (!hold && (seconds < 1 || seconds > 120)) {
        fprintf(stderr, "segundos fuera de rango (1-120)\n"); return 2;
    }

    /* --- Guardas ------------------------------------------------------- */
    /* Validar que el ID existe ANTES de nada: para un ID inventado,
     * CGDisplayIsBuiltin devuelve false y la guarda P4 se saltaría sola. */
    {
        CGDirectDisplayID on[PC_MAX_DISPLAYS];
        uint32_t n = 0;
        CGGetOnlineDisplayList(PC_MAX_DISPLAYS, on, &n);
        bool found = false;
        for (uint32_t i = 0; i < n; i++) if (on[i] == target) found = true;
        if (!found) {
            fprintf(stderr, "NEGADO: el display %u no está online. IDs disponibles:", target);
            for (uint32_t i = 0; i < n; i++) fprintf(stderr, " %u", on[i]);
            fprintf(stderr, "\n");
            return 1;
        }
    }

    if (CGDisplayIsBuiltin(target) && !allow_builtin) {
        fprintf(stderr,
            "NEGADO: %u es la pantalla INTERNA.\n"
            "Valida primero contra el monitor EXTERNO, que sí se puede reconectar\n"
            "físicamente si algo sale mal. Si de verdad quieres seguir, añade\n"
            "--allow-builtin, pero sólo después de que las pruebas 1-6 del plan\n"
            "estén en verde.\n", target);
        return 1;
    }

    uint32_t remaining = survivors_excluding(target);
    if (remaining == 0) {
        fprintf(stderr,
            "NEGADO: si desactivo %u no quedaría NINGUNA pantalla utilizable.\n"
            "Ahora mismo hay %u display(s) en la lista Active.\n"
            "Recuerda que 'utilizable' exige además estar despierto y no ser\n"
            "esclavo de un espejo. Si estás en modo ESPEJO, la pantalla esclava\n"
            "no cuenta: cambia a modo extendido antes de ejecutar esta prueba.\n",
            target, pc_active_display_count());
        return 1;
    }

    printf("objetivo: display %u (%s)\n", target,
           CGDisplayIsBuiltin(target) ? "INTERNA" : "externa");
    printf("quedarán %u display(s) activo(s) tras desactivarlo\n", remaining);
    printf("opción de configuración: %s\n",
           option == kCGConfigureForAppOnly ? "kCGConfigureForAppOnly (revierte al morir el proceso)"
                                            : "kCGConfigureForSession (NO revierte al morir el proceso)");

    /* --- Red de seguridad ---------------------------------------------- */
    /* Si el dead-man no se puede armar, NO se muta. Es la única capa que
     * sobrevive a un SIGKILL mientras no esté confirmado el experimento de
     * kCGConfigureForAppOnly; seguir sin ella sería quedarse sin red. */
    int deadman_secs = hold ? 300 : seconds + 10;
    if (!deadman("--arm", deadman_secs)) {
        fprintf(stderr,
            "ABORTADO: no se pudo armar el dead-man. No se toca ninguna pantalla.\n"
            "Comprueba que el binario 'rescue' está junto a este ejecutable.\n");
        return 1;
    }
    printf("dead-man armado para %d s\n", deadman_secs);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    atexit(restore_now);

    /* --- P5: estado a disco ANTES de mutar ------------------------------ */
    if (!pc_state_add(target, CGDisplayIsBuiltin(target))) {
        fprintf(stderr, "no se pudo persistir el estado; abortando por seguridad\n");
        deadman("--disarm", 0);
        return 1;
    }
    g_target = target;

    /* --- Mutación ------------------------------------------------------- */
    CGError err = pc_set_display_enabled(target, false, option);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "fallo al desactivar: CGError %d (%s)\n", err, pc_cgerror_name(err));
        pc_state_remove(target);
        g_target = kCGNullDirectDisplay;
        deadman("--disarm", 0);
        return 1;
    }
    printf("display %u DESACTIVADO (activos ahora: %u)\n", target, pc_active_display_count());

    if (hold) {
        printf("\n*** MODO HOLD — pid %d ***\n", getpid());
        printf("Desde otra terminal (o por SSH):  kill -9 %d\n", getpid());
        printf("Si el display vuelve solo, kCGConfigureForAppOnly cubre el bit\n"
               "privado 'enabled' y el WindowServer nos protege ante SIGKILL.\n");
        printf("El dead-man rescatará igualmente en %d s.\n", deadman_secs);
        fflush(stdout);
        while (!g_interrupted) sleep(1);
    } else {
        for (int i = 0; i < seconds && !g_interrupted; i++) {
            printf("  reactivando en %d s...\n", seconds - i);
            fflush(stdout);
            sleep(1);
        }
    }

    /* --- Reversión ------------------------------------------------------ */
    restore_now();
    sleep(1);
    uint32_t after = pc_active_display_count();
    printf("display reactivado (activos ahora: %u)\n", after);
    deadman("--disarm", 0);
    return after > 0 ? 0 : 1;
}
