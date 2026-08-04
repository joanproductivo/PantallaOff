/*
 * probe — sonda de SOLO LECTURA. No modifica absolutamente nada.
 *
 * Sirve para (a) ver el estado real de las pantallas, incluido el efecto del
 * modo espejo sobre las listas Active/Online, y (b) confirmar que los símbolos
 * privados que necesita el proyecto existen en esta versión de macOS.
 */
#include "../src/PantallaCore.h"

#include <stdio.h>
#include <dlfcn.h>
#include <sys/utsname.h>

int main(void) {
    struct utsname u;
    if (uname(&u) == 0) printf("sistema: %s %s (%s)\n\n", u.sysname, u.release, u.machine);

    CGDirectDisplayID on[PC_MAX_DISPLAYS], act[PC_MAX_DISPLAYS];
    uint32_t no = 0, na = 0;
    CGGetOnlineDisplayList(PC_MAX_DISPLAYS, on, &no);
    CGGetActiveDisplayList(PC_MAX_DISPLAYS, act, &na);

    printf("ONLINE count=%u :", no); for (uint32_t i = 0; i < no; i++) printf(" %u", on[i]);
    printf("\nACTIVE count=%u :", na); for (uint32_t i = 0; i < na; i++) printf(" %u", act[i]);
    printf("\n");
    if (no != na) {
        printf("  ^ Online != Active. Normalmente significa espejo hardware: el\n"
               "    esclavo desaparece de Active aunque su panel esté ENCENDIDO.\n"
               "    Por eso el predicado usa Active y el estado se persiste a disco.\n");
    }
    printf("\n");

    CGDirectDisplayID builtin = pc_builtin_id();
    pc_display d[PC_MAX_DISPLAYS];
    uint32_t n = pc_snapshot(d, PC_MAX_DISPLAYS);
    for (uint32_t i = 0; i < n; i++) {
        printf("id=%-4u %-8s activo=%d dormido=%d espejo_de=%-4u en_set_espejo=%d "
               "vendor=%-6u %zux%zu%s\n",
               d[i].id, d[i].builtin ? "INTERNA" : "externa", d[i].active,
               d[i].asleep, d[i].mirrors, d[i].in_mirror_set, d[i].vendor,
               d[i].px_w, d[i].px_h,
               pc_is_usable_external(d[i].id, builtin) ? "  <- externo utilizable" : "");
    }

    char reason[256];
    bool can = pc_can_disable_builtin(reason, sizeof reason);
    printf("\ninterna id=%u | es master de espejo: %s\n",
           builtin, pc_builtin_is_mirror_master(builtin) ? "SÍ" : "no");
    printf("externos utilizables: %u\n", pc_usable_external_count());
    printf("¿se puede apagar la interna?: %s — %s\n", can ? "SÍ" : "NO", reason);

    CGDirectDisplayID ids[PC_MAX_DISPLAYS];
    uint32_t ns = pc_state_read(ids, PC_MAX_DISPLAYS);
    printf("estado persistido: %u display(s)", ns);
    for (uint32_t i = 0; i < ns; i++) printf(" %u", ids[i]);
    printf("\n");

    printf("\nsímbolos:\n");
    const char *syms[] = { "CGSConfigureDisplayEnabled",
                           "CGRestorePermanentDisplayConfiguration",
                           "CGBeginDisplayConfiguration",
                           "CGCompleteDisplayConfiguration",
                           "CGSGetDisplayEnabled" };
    for (int i = 0; i < 5; i++) {
        void *p = dlsym(RTLD_DEFAULT, syms[i]);
        printf("  %-40s %s\n", syms[i], p ? "presente" : "AUSENTE");
    }
    printf("  (CGSGetDisplayEnabled ausente es lo esperado: no hay getter del bit\n"
           "   'enabled', por eso el estado se persiste en ~/%s)\n", PC_STATE_FILE);
    return 0;
}
