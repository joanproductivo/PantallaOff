# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

App de barra de menú para macOS que **desactiva la pantalla interna del MacBook** (Apple
Silicon, macOS 13+), más mantener despierto, luz del teclado y arranque al inicio.
Swift + AppKit sobre un núcleo en C, compilado con Command Line Tools — **sin Xcode**.

El código, los comentarios y los mensajes de commit están en **español**. La interfaz es
bilingüe (ver *Idioma* más abajo); los README están en inglés (`README.md`) y español
(`README.es.md`).

## Comandos

```bash
make            # ayuda con todos los objetivos
make all        # herramientas + app + bundle firmado ad-hoc
make install    # instala /Applications/PantallaOff.app y ~/rescue
make probe      # SOLO LECTURA: qué ve CoreGraphics ahora mismo
make status     # estado de pantallas + dead-man (solo lectura)
make icon       # regenera resources/AppIcon.icns desde tools/make-icon.swift
make clean
```

Diagnósticos que no abren interfaz. `--kb-diag` es de solo lectura; `--login-item-diag`
**registra y restaura** el estado previo del arranque (y con `requiresApproval` o «no
disponible» no muta nada):

```bash
/Applications/PantallaOff.app/Contents/MacOS/PantallaOff --kb-diag
/Applications/PantallaOff.app/Contents/MacOS/PantallaOff --login-item-diag
```

Ejecútalos **desde el bundle**, no desde `./build`: un binario sin bundle id usa otro dominio
de `UserDefaults` y reporta un estado que no es el de la app.

## No hay tests automáticos: la validación es contra hardware

No existe suite de tests. Lo más parecido es `build/selftest`, que **desactiva un display de
verdad**. Reglas de trabajo, no negociables:

- **Valida siempre contra el monitor EXTERNO primero.** Es el único display que se puede
  reconectar a mano. `selftest` se niega a apuntar a la interna sin `--allow-builtin`.
- **Nunca ejecutes mutaciones sin el usuario delante.** `probe`, `rescue --status` y
  `--kb-diag` son de solo lectura y puedes usarlos libremente; `--login-item-diag` registra
  y restaura el estado previo del arranque (no toca pantallas, pero muta y revierte);
  todo lo demás no.
- En modo espejo `selftest` se negará: sólo hay un display en la lista Active.

```bash
./build/selftest <idExterno> 6        # apaga 6 s y revierte
./build/selftest <idExterno> hold     # apaga y espera (para el experimento de kill -9)
~/rescue                              # reactiva; no-op real si no hay nada que rescatar
~/rescue --last-resort                # reinicia la sesión gráfica (logout, no reboot)
```

## Arquitectura

**`src/PantallaCore.{h,c}` es la única implementación del predicado de seguridad, de la
mutación de displays, del estado persistido y del rescate.** Lo enlazan a la vez las tres
herramientas C (`tools/probe.c`, `rescue.c`, `selftest.c`) y la app Swift, que lo importa vía
`src/Bridge.h` (`-import-objc-header` en el Makefile). **Swift no reimplementa nada de esto**:
si necesitas lógica de pantallas, va en C, o las dos mitades divergirán.

Reparto del lado Swift:

| Fichero | Responsabilidad |
|---|---|
| `DisplayControl.swift` | watchdog, vigía IOKit, dead-man, registro, cola de trabajo |
| `AppDelegate.swift` | menú y acciones (única puerta por la que se apaga) |
| `KeepAwake.swift` | `IOPMAssertion` (API pública) |
| `KeyboardLight.swift` | `KeyboardBrightnessClient` de CoreBrightness (privada) |
| `L10n.swift` | cadenas es/en |
| `MenuRow.swift` | filas de menú que no cierran al hacer clic (interruptores) |

Estado en disco: `~/.pantallaoff-state` (IDs apagados, con `flock` entre procesos),
`~/.pantallaoff-armed` (pid del dead-man), `~/Library/Logs/PantallaOff.log`.

### Las cinco invariantes

Romper cualquiera de éstas es un fallo grave, no un detalle de estilo:

- **P1 — fail-open.** *Ninguna ruta automática puede DESACTIVAR un display.* Watchdog, wake,
  callbacks y vigía IOKit sólo pueden **encender**. Sólo hay dos callers de
  `pc_set_display_enabled(..., false)` y ambos nacen de una acción explícita: el menú y la CLI
  de `selftest`. Si añades un tercero, párate a pensar.
- **P2 — el rescate no depende de enumerar.** Un display desactivado desaparece de
  `CGGetOnlineDisplayList`; sólo se recupera por su ID persistido o con la API pública
  `CGRestorePermanentDisplayConfiguration()`.
- **P3 — el dead-man vive fuera del proceso.** `rescue --arm N` re-ejecuta el binario con
  `posix_spawn` + `POSIX_SPAWN_SETSID` (no `fork`: CoreGraphics no es fork-safe) y queda
  reparentado a launchd, así que sobrevive a un `SIGKILL` de quien lo armó.
- **P4 — externo primero** (ver arriba).
- **P5 — el estado a disco ANTES de mutar**, con `fsync` del fichero y del directorio. Si el
  proceso muere durante la transacción, el rescate necesita encontrar el ID.

### Hechos medidos que condicionan el diseño

Todo esto se midió sobre hardware real (M3 Max, macOS 26.6) y contradice lo que uno asumiría
leyendo la documentación. No los "corrijas" sin volver a medirlos:

- **`CGDisplayIsActive == false` NO significa "apagada".** Bajo espejo hardware el esclavo
  responde `false` con el panel encendido. Por eso todo predicado usa `CGGetActiveDisplayList`
  y **nunca** la lista online.
- **No existe getter del bit `enabled`** (`CGSGetDisplayEnabled` no está en el `.tbd`). El
  estado hay que recordarlo; de ahí el fichero.
- **`kCGConfigureForAppOnly` NO revierte el bit privado al morir el proceso** (verificado con
  `kill -9`). Revierte modo y topología, nada más. La red real contra `SIGKILL` es el dead-man.
- **Con cero pantallas activas la recuperación por software es imposible**: WindowServer acepta
  el enable y falla el hotplug del panel. Salidas: reconectar un monitor,
  `sudo killall -HUP WindowServer`, o reiniciar.
- **El zombi**: con la interna apagada, desenchufar el externo **no llega a CoreGraphics** — CG
  lo sigue reportando online y activo. Por eso existe el vigía IOKit
  (`DCPAVServiceProxy` + `kIOTerminatedNotification`): es el único canal que ve el desenchufe
  físico, y actúa dentro de la ventana en la que el enable todavía funciona.
- **Por HDMI la identidad EDID llega a cero** (medido 2026-08-06, M3 Max, monitor
  1920×1080): `CGDisplayVendorNumber`, model y serial devuelven 0 en un monitor real, pero
  el tamaño físico EDID sí llega. Y `CGDisplayScreenSize` sin EDID devuelve una estimación
  a 72 dpi desde los bounds, **nunca 0** — por eso el predicado compara los mm contra la
  estimación, no contra cero.
- **`CGDisplayIsActive` puede devolver true para un ID desactivado** (reuso de ID por un
  externo re-registrado o transitorio de reconfiguración; medido 2026-08-06, dos veces,
  durante un baile de cables). Ninguna lectura única de CG justifica tocar el estado
  persistido de la interna: borrar esa entrada desarma TODAS las redes a la vez (rescate,
  watchdog, acelerador, fast-path y vigía) — así se perdió el panel hasta reiniciar
  WindowServer.
- **El proxy `DCPAVServiceProxy` External es por conexión**: muere al desenchufar (a 1 Hz
  desaparece del registro) y renace con registry ID nuevo al reenchufar. Apagar la interna
  mata su propio proxy y dispara el vigía (ruido esperado, filtrado por la cuenta). En el
  instante de la terminación el moribundo puede seguir enumerándose: la cuenta excluye los
  registry IDs que la notificación declaró muertos.
- **`hw.model` ya no contiene "Book"** desde 2022 (`Mac15,10`). Para detectar portátil se usa
  la presencia de `AppleSmartBattery`.

### Concurrencia

Toda mutación de pantallas va en `workQueue`, **nunca en el hilo principal**: se midieron
transacciones de CoreGraphics bloqueadas ~21 s, y bloquear `main` congelaría el timer del
watchdog justo en la ventana más peligrosa. El fast-path del callback CG y el vigía IOKit
corren en sus propios hilos y se serializan con `fastPathLock`.

## Convenciones

**Idioma.** Todo lo que ve el usuario pasa por `L10n.t` (`struct Strings` con dos instancias
constantes; el compilador obliga a rellenar ambas). **El registro se queda en español a
propósito**: monolingüe y greppable, y los README citan líneas literales. Si añades una cadena
de interfaz, añádela a `Strings`; si es de log, no.

**Motivos que vienen de C.** `pc_can_disable_builtin_why()` devuelve un `pc_deny_reason` y
Swift lo traduce; la variante con texto (`pc_can_disable_builtin`) existe sólo para `probe`.
Nunca parsees cadenas del núcleo para decidir nada.

**Registro.** `write()` va a un búfer en memoria de 200 eventos y **no toca el disco**;
`writeProblem()` vuelca ese búfer junto con la anomalía. En marcha normal el fichero de log ni
se crea. Rota a 128 KB. Usa `writeProblem` sólo para lo que merece investigación.

**El icono se dibuja por código** (`tools/make-icon.swift`), no es un binario opaco: los
tamaños ≤ 64 px usan una variante más rotunda porque el diseño normal se empasta.

## Riesgos asumidos

APIs privadas (`CGSConfigureDisplayEnabled`, `KeyboardBrightnessClient`): no es distribuible en
App Store y Apple puede romperlas. Firma ad-hoc sin entitlements — si algún día se añade un
atajo global hará falta permiso de Accesibilidad, que una identidad ad-hoc nueva revoca en cada
compilación.
