/*
 * rescue — botón de pánico de PantallaOff.
 *
 * Diseñado para funcionar CUANDO NO SE VE NADA y para no depender de la app.
 *
 *   rescue                 reactiva todo lo que pueda y reporta
 *   rescue --arm N         arma un dead-man: dentro de N s ejecuta el rescate
 *                          salvo que alguien lo desarme. Sobrevive a que el
 *                          proceso que lo armó muera por SIGKILL.
 *   rescue --disarm        desarma el dead-man pendiente
 *   rescue --status        solo informa, no toca nada
 *   rescue --restore       fuerza CGRestorePermanentDisplayConfiguration()
 *
 * Por qué no basta con enumerar displays: un display desactivado con
 * CGSConfigureDisplayEnabled SALE de CGGetOnlineDisplayList y de Información
 * del Sistema. Sólo se puede reactivar si recuerdas su CGDirectDisplayID, y la
 * pantalla interna de un MacBook no se puede reconectar físicamente. De ahí el
 * fichero de estado y el uso de la API pública como último recurso.
 */
#include "../src/PantallaCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <spawn.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>
#include <libproc.h>
#include <limits.h>
#include <stdlib.h>

extern char **environ;

/* --------------------------------------------------------------------- */

static void print_displays(const char *title) {
    pc_display d[PC_MAX_DISPLAYS];
    uint32_t n = pc_snapshot(d, PC_MAX_DISPLAYS);
    CGDirectDisplayID builtin = pc_builtin_id();

    printf("%s (%u online, %u externos utilizables)\n",
           title, n, pc_usable_external_count());
    for (uint32_t i = 0; i < n; i++) {
        printf("  id=%-4u %-8s activo=%d dormido=%d espejo_de=%-4u "
               "en_set_espejo=%d vendor=%-6u %zux%zu%s\n",
               d[i].id, d[i].builtin ? "INTERNA" : "externa",
               d[i].active, d[i].asleep, d[i].mirrors, d[i].in_mirror_set,
               d[i].vendor, d[i].px_w, d[i].px_h,
               pc_is_usable_external(d[i].id, builtin) ? "  <- utilizable" : "");
    }

    CGDirectDisplayID ids[PC_MAX_DISPLAYS];
    uint32_t ns = pc_state_read(ids, PC_MAX_DISPLAYS);
    if (ns == 0) {
        printf("  estado: ningún display marcado como apagado por nosotros\n");
    } else {
        printf("  estado: apagados por nosotros:");
        for (uint32_t i = 0; i < ns; i++) printf(" %u", ids[i]);
        printf("\n");
    }
}

/* --------------------------------------------------------------------- */

static bool armed_pid_path(char *out, size_t len) {
    return pc_home_path(PC_ARMED_FILE, out, len);
}

static pid_t read_armed_pid(void) {
    char path[1024];
    if (!armed_pid_path(path, sizeof path)) return 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    long pid = 0;
    if (fscanf(f, "%ld", &pid) != 1) pid = 0;
    fclose(f);
    return (pid_t)pid;
}

/* Confirma que el pid corresponde a un `rescue` y no a un pid reciclado por
 * otro proceso cualquiera: matar a ciegas por número de pid es una forma
 * estupenda de cargarse algo ajeno.
 *
 * Se compara el NOMBRE del ejecutable, no la ruta completa. Este binario vive
 * a la vez en ./build/rescue, en ~/rescue y dentro del bundle de la app, y
 * cualquiera de las copias tiene que poder desarmar un dead-man armado por
 * otra. Comparar rutas dejaba dead-man huérfanos armados — pasó de verdad. */
static bool pid_is_our_deadman(pid_t pid) {
    char running[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, running, sizeof running) <= 0) return false;

    const char *slash = strrchr(running, '/');
    const char *base = slash ? slash + 1 : running;
    return strcmp(base, "rescue") == 0;
}

static int do_disarm(bool quiet) {
    pid_t pid = read_armed_pid();
    char path[1024];

    if (pid > 0) {
        if (!pid_is_our_deadman(pid)) {
            /* El pid se ha reciclado: el fichero está rancio, se limpia. */
            if (armed_pid_path(path, sizeof path)) unlink(path);
            if (!quiet) printf("el pid %d ya no es un dead-man; fichero limpiado\n", pid);
            return 0;
        }
        if (kill(pid, SIGTERM) == 0) {
            if (armed_pid_path(path, sizeof path)) unlink(path);
            if (!quiet) printf("dead-man desarmado (pid %d)\n", pid);
            return 0;
        }
        if (errno == ESRCH) {
            if (armed_pid_path(path, sizeof path)) unlink(path);
            if (!quiet) printf("dead-man ya no existía (pid %d)\n", pid);
            return 0;
        }
        if (!quiet) fprintf(stderr, "no se pudo desarmar pid %d: %s\n",
                            pid, strerror(errno));
        return 1;
    }
    if (!quiet) printf("no había ningún dead-man armado\n");
    return 0;
}

/* Arma el dead-man RE-EJECUTANDO este binario.
 *
 * Es deliberado no usar fork() a secas: las conexiones de CoreGraphics al
 * WindowServer no son fork-safe, y el hijo tiene que poder llamar a CG cuando
 * dispare. Un exec limpio evita ese problema por completo. */
static int do_arm(int seconds) {
    do_disarm(true);   /* nunca dos dead-man a la vez */

    char self[4096];
    uint32_t size = sizeof self;
    if (_NSGetExecutablePath(self, &size) != 0) {
        fprintf(stderr, "no se pudo determinar la ruta del ejecutable\n");
        return 1;
    }

    char secs[32];
    snprintf(secs, sizeof secs, "%d", seconds);
    char *argv[] = { self, (char *)"--armed-child", secs, NULL };

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, self, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        fprintf(stderr, "no se pudo armar el dead-man: %s\n", strerror(rc));
        return 1;
    }

    char path[1024];
    if (armed_pid_path(path, sizeof path)) {
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "%d\n", pid); fflush(f); fsync(fileno(f)); fclose(f); }
    }
    printf("dead-man armado: pid %d, dispara en %d s\n", pid, seconds);
    return 0;
}

static volatile sig_atomic_t g_disarmed = 0;
static void on_term(int sig) { (void)sig; g_disarmed = 1; }

static int do_armed_child(int seconds) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);

    for (int i = 0; i < seconds && !g_disarmed; i++) sleep(1);

    char path[1024];
    if (g_disarmed) {                       /* alguien confirmó que todo va bien */
        pc_log("dead-man desarmado sin disparar (pid %d)", getpid());
        return 0;
    }

    /* Nadie nos desarmó: el proceso que armó esto murió o se colgó. Rescatar.
     *
     * Se deja rastro en el log SIEMPRE: este proceso no tiene terminal (sesión
     * desasociada), así que sin log su disparo sería invisible y la prueba del
     * dead-man no tendría forma de distinguir "funcionó" de "no se ejecutó". */
    pc_log("dead-man DISPARA (pid %d): nadie lo desarmó en %d s", getpid(), seconds);
    pc_rescue_result r = pc_rescue();
    pc_log("dead-man resultado: ok=%d indicios=%d activos %u->%u IDs %u/%u restore=%d",
           r.ok, r.had_evidence, r.active_before, r.active_after,
           r.targeted_ok, r.targeted_attempts, r.used_permanent_restore);

    if (armed_pid_path(path, sizeof path)) unlink(path);
    return r.ok ? 0 : 1;
}

/* --------------------------------------------------------------------- */

static int do_rescue(bool force_restore) {
    print_displays("ANTES");

    pc_rescue_result r = pc_rescue_ex(force_restore);

    printf("\nrescate: indicios de algo apagado: %s | activos %u -> %u | "
           "IDs recuperados %u/%u | restauración permanente: %s\n",
           r.had_evidence ? "SÍ" : "no",
           r.active_before, r.active_after, r.targeted_ok, r.targeted_attempts,
           r.used_permanent_restore ? "SÍ" : "no");

    if (!r.had_evidence && !force_restore) {
        printf("\nNo había nada que rescatar, así que NO se ha tocado nada.\n"
               "Si estás a ciegas y esto no lo ha arreglado, la pantalla puede\n"
               "estar simplemente dormida (mueve el ratón). Si aun así nada:\n"
               "  ~/rescue --restore\n");
        return 0;
    }

    print_displays("DESPUÉS");

    if (!r.ok) {
        fprintf(stderr,
            "\n*** NO SE HA PODIDO RECUPERAR ***\n"
            "Con 0 pantallas activas el hotplug del panel falla en WindowServer\n"
            "(medido; reintentar el enable es inútil). Salidas reales, en orden:\n"
            "  1. Reconecta el cable de la pantalla externa (la más rápida)\n"
            "  2. Por SSH:  sudo killall -HUP WindowServer\n"
            "     Reinicia la sesión gráfica en ~10 s: vuelves al login en la\n"
            "     pantalla interna SIN reiniciar el equipo (pierdes las apps\n"
            "     abiertas, como un logout).\n"
            "  3. Mantén pulsado el botón de encendido ~10 s y reinicia\n"
            "Nota: cerrar/abrir la tapa NO funciona en este estado (medido).\n");
        return 1;
    }
    printf("\nOK: %u pantalla(s) activa(s).\n", r.active_after);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 1) return do_rescue(false);

    const char *cmd = argv[1];

    if (strcmp(cmd, "--status") == 0) {
        print_displays("ESTADO");
        pid_t pid = read_armed_pid();
        if (pid > 0 && kill(pid, 0) == 0) printf("  dead-man armado: pid %d\n", pid);
        else printf("  dead-man: no armado\n");
        return 0;
    }
    if (strcmp(cmd, "--restore") == 0)  return do_rescue(true);
    if (strcmp(cmd, "--disarm") == 0)   return do_disarm(false);

    /* Último recurso: reiniciar la sesión gráfica (logout, NO reboot).
     * Única vía medida que recupera el panel cuando el enable falla con 0
     * pantallas. Requiere sudo; con la regla NOPASSWD de tools/sudoers-pantallaoff
     * funciona sin teclear contraseña (imprescindible a ciegas). */
    if (strcmp(cmd, "--last-resort") == 0) {
        pc_log("last-resort: sudo killall -HUP WindowServer");
        fprintf(stderr, "Reiniciando la sesión gráfica (perderás las apps abiertas)...\n");
        int rc = system("sudo -n /usr/bin/killall -HUP WindowServer");
        if (rc != 0) {
            fprintf(stderr,
                "sudo sin contraseña no disponible (instala tools/sudoers-pantallaoff).\n"
                "Hazlo a mano por SSH:  sudo killall -HUP WindowServer\n");
            return 1;
        }
        return 0;
    }

    if (strcmp(cmd, "--arm") == 0) {
        if (argc < 3) { fprintf(stderr, "uso: rescue --arm <segundos>\n"); return 2; }
        int s = atoi(argv[2]);
        if (s < 1 || s > 600) { fprintf(stderr, "segundos fuera de rango (1-600)\n"); return 2; }
        return do_arm(s);
    }
    if (strcmp(cmd, "--armed-child") == 0) {   /* interno */
        if (argc < 3) return 2;
        return do_armed_child(atoi(argv[2]));
    }

    fprintf(stderr,
        "uso: rescue [--arm N | --disarm | --status | --restore | --last-resort]\n"
        "  (sin argumentos) reactiva todas las pantallas\n"
        "  --last-resort   reinicia la sesión gráfica (logout, no reboot)\n");
    return 2;
}
