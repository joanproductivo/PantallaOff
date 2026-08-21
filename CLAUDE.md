# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

App de barra de menú para macOS que **desactiva la pantalla interna del MacBook** (Apple
Silicon, macOS 13+), más mantener despierto, dormir al cerrar la tapa, restauración del
apagado al despertar/arrancar (P1-R), apagado automático al conectar un externo (P1-C),
luz del teclado y arranque al inicio.
Swift + AppKit sobre un núcleo en C, compilado con Command Line Tools — **sin Xcode**.

El código, los comentarios y los mensajes de commit están en **español**. La interfaz es
bilingüe (ver *Idioma* más abajo); los README están en inglés (`README.md`) y español
(`README.es.md`).

## Comandos

```bash
make            # ayuda con todos los objetivos
make all        # herramientas + app + bundle firmado ad-hoc
make install    # instala /Applications/PantallaOff.app y ~/rescue
make release    # build/PantallaOff-<versión>.zip para GitHub Releases
make probe      # SOLO LECTURA: qué ve CoreGraphics ahora mismo
make status     # estado de pantallas + dead-man (solo lectura)
make icon       # regenera resources/AppIcon.icns desde tools/make-icon.swift
make clean
```

El zip de release se empaqueta **siempre con `ditto --sequesterRsrc`, nunca con `zip`**:
`zip` deja ficheros AppleDouble (`._Contents`, `._PantallaOff`…) DENTRO del bundle y eso rompe
el sello de la firma — quien descomprima con `unzip` desde la terminal recibe una app «dañada»
que macOS se niega a abrir (medido: la release 1.2.1 salió así y hubo que rehacerla). `make
release` valida el paquete descomprimiéndolo y verificando la firma antes de darlo por bueno.

Diagnósticos que no abren interfaz. `--kb-diag` es de solo lectura; `--login-item-diag`
**registra y restaura** el estado previo del arranque (y con `requiresApproval` o «no
disponible» no muta nada):

```bash
/Applications/PantallaOff.app/Contents/MacOS/PantallaOff --kb-diag
/Applications/PantallaOff.app/Contents/MacOS/PantallaOff --login-item-diag
```

Ejecútalos **desde el bundle**, no desde `./build`: un binario sin bundle id usa otro dominio
de `UserDefaults` y reporta un estado que no es el de la app.

Y no dejes `build/PantallaOff.app` corriendo a la vez que la instalada: comparten bundle id
(salen dos «PantallaOff» en Ajustes → Barra de menús) y, con P1-C activado, las dos armarían
su propia ventana de apagado sobre las mismas pantallas.

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
| `DisplayControl.swift` | watchdog, vigía IOKit, dead-man, ventana de apagado diferido (P1-R y P1-C), registro, cola de trabajo |
| `AppDelegate.swift` | menú y acciones (el apagado sólo entra por `turnOffBuiltIn`: menú, restauración P1-R y apagado al conectar P1-C) |
| `KeepAwake.swift` | `IOPMAssertion` (API pública) |
| `LidSleep.swift` | «dormir al cerrar la tapa»: vigía clamshell + `IOPMSleepSystem` (públicas) |
| `KeyboardLight.swift` | `KeyboardBrightnessClient` de CoreBrightness (privada) |
| `LoginItem.swift` | arranque al inicio (`SMAppService`, pública) |
| `L10n.swift` | cadenas es/en |
| `MenuRow.swift` | filas de menú que no cierran al hacer clic (interruptores) |
| `main.swift` | punto de entrada y CLIs de diagnóstico (`--kb-diag`, `--login-item-diag`) |

Estado en disco: `~/.pantallaoff-state` (IDs apagados, con `flock` entre procesos),
`~/.pantallaoff-armed` (pid del dead-man), `~/Library/Logs/PantallaOff.log`. En
`UserDefaults` (dominio del bundle id — de ahí el aviso de arriba): `restoreOffEnabled` y
`restoreIntent` (P1-R; la intención sobrevive al reinicio y NUNCA es el ancla del rescate —
eso es el fichero de estado), `autoOffOnConnect` (P1-C; sin intención asociada: es una
regla revocable que sobrevive al reinicio y se reevalúa en cada arranque, pero que un
«Encender pantalla» explícito desactiva), `sleepOnLidClose`, `verboseLogging` y
`language`.

### Las cinco invariantes

Romper cualquiera de éstas es un fallo grave, no un detalle de estilo:

- **P1 — fail-open.** *Ninguna ruta automática puede DESACTIVAR un display*, con DOS
  excepciones acotadas, ambas gobernadas por un interruptor del usuario y ambas por la
  **misma ventana de apagado diferido**: 60 s (con el reloj pausado mientras el sistema
  tiene las pantallas dormidas), el MISMO externo utilizable ≥5 s (continuidad por ID),
  ≥5 s sin reconfiguraciones, un solo intento, y la transacción completa del menú
  (precondición + P5 + dead-man + postcondición).
  - **P1-R, restauración** («Mantener configuración de pantalla al despertar/arrancar»,
    activada por defecto, desactivable en ⌥ → Diagnóstico): re-aplica una decisión
    explícita previa del usuario tras despertar o arrancar.
  - **P1-C, apagado al conectar** («…Apagarla siempre al conectar una externa»,
    **desactivada por defecto**): aplica una regla del usuario al conectar un monitor.
    Su fila es una **sub-opción del ítem principal y sólo existe con la interna ya
    apagada** —como «…y la pantalla encendida» bajo «Mantener despierto»—: automatiza una
    decisión que hay que haber tomado antes, así que no se puede programar un apagado sin
    haber apagado. Y **«Encender pantalla» la desactiva**: encender a mano contradice la
    regla, y dejarla armada convertiría el clic del usuario en una pelea contra la app a
    cada reconexión. Tiene TRES disparadores, y ninguno es CoreGraphics: el nacimiento de
    un `DCPAVServiceProxy` con `Location == External` en IOKit (conexión física), el
    arranque de la app con el monitor puesto —que es lo que hace que la preferencia siga
    valiendo tras reiniciar— y el **re-armado tras un encendido automático** de la interna
    (§ abajo). **Nunca lo que enumere CG**: un zombi es un externo utilizable para CG (se
    re-registra con ID nuevo y parece una conexión), y apagar ahí deja cero pantallas
    reales.

    El **re-armado** existe porque un encendido de una red de seguridad no deroga la regla
    del usuario: medido 2026-08-21, el externo se re-registró en CG (4→25) sin tocar el
    cable, el acelerador encendió la interna y P1-C se quedaba muerta con el monitor
    delante. Espera 12 s (el proxy tarda ~10-13 s en morir: antes de ese plazo «hay proxy» no
    distingue el cable puesto del recién quitado) y exige proxy External vivo. Contra el
    zombi hay cuatro capas, en este orden: la ventana **sólo decide con la interna
    encendida** (si consta apagada cierra por `ALREADY_OFF`), el predicado sobre CG, la
    presencia física al decidir, y por último esos 12 s. **No relajes las tres primeras
    fiándote de la cuarta.** Lleva anti-oscilación: si la interna vuelve sola en menos de
    300 s tras un apagado de P1-C, al segundo intento seguido se deja de re-armar y se
    registra como anomalía. Sólo re-arman las redes de seguridad; la reversión de una
    postcondición fallida y los encendidos preventivos de dormir/apagar/salir, no. **Se calla** —y cierra su ventana— 90 s desde que el Mac se duerme o se apaga,
    renovados 60 s al despertar: ahí un match de proxies no significa «acabas de conectar
    un monitor». El silencio se comprueba al abrir la ventana Y al decidir. Un display
    virtual no la dispara (no tiene proxy).

  Watchdog, wake, callbacks y el vigía de **terminación** de IOKit sólo pueden
  **encender**; la notificación de **match** del mismo puerto no enciende ni apaga: sólo
  abre una ventana. Sólo hay dos callers de `pc_set_display_enabled(..., false)` — el
  flujo `turnOffBuiltIn` (menú, restauración P1-R y apagado al conectar P1-C) y la CLI de
  `selftest`. Si añades otro caller u otra ruta automática, párate a pensar.
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
- **El zombi**: con la interna apagada, desenchufar el externo **físico** **no llega a
  CoreGraphics** — CG
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
  mata su propio proxy Embedded y dispara el vigía (ruido esperado: la terminación
  solo-Embedded se clasifica por `Location` y se delega al watchdog — ver el bullet del
  display virtual). En el instante de la terminación el moribundo puede seguir
  enumerándose: la cuenta de la rama física excluye los registry IDs que la notificación
  declaró muertos.
- **Un display virtual no tiene `DCPAVServiceProxy`** (medido 2026-08-06, gafas VR en modo
  extendido): es visible para CG e invisible para el canal IOKit. Con sólo un virtual como
  externo, apagar la interna dejaba la cuenta física en 0 y el vigía reencendía dentro de
  la propia transacción (fuego amigo). Por eso la terminación solo-Embedded (Location
  leída positivamente) no actúa en ioQueue: delega en el watchdog, que ve la topología
  asentada. Y al revés que el cable, **el desmontaje de un virtual SÍ lo procesa CG**
  (medido: el acelerador lo ve desaparecer al instante y cg-reenum reenciende al primer
  intento — sin zombi): las redes CG cubren a los virtuales de forma nativa.
- **El proxy External tarda ~10 s en morir tras el desenchufe, pero nace y se puebla al
  instante al conectar** (medido 2026-08-21, sonda de solo lectura sobre el monitor de
  2560×1080): al tirar del cable, CG re-enumera el externo (4→14) en el mismo segundo y
  la terminación IOKit llega **10 s** después; al reenchufar, el match llega con registry
  ID nuevo y con `Location` ya legible, y CG añade el display **2,5 s** más tarde. De ahí
  que P1-C dispare con el match (fiable e inmediato) pero NO se fíe de la presencia del
  proxy como prueba de «sigue conectado»: para eso está el predicado sobre CG.
- **El acelerador dispara solo con frecuencia, sin tocar el cable**: medido en el registro
  del 2026-08-21, **19 re-encendidos** de la interna en 6 h 47 min (`cg-reenum; enable(1)
  -> CGError 0`), siempre con `usables=1` y el monitor quieto. La causa es que CG
  re-registra el externo con ID nuevo (4→25) y el acelerador, por diseño, trata un ID nuevo
  como la firma del zombi. Es fail-open y por sí solo sólo cuesta un clic, pero condiciona
  cualquier cosa que se acople a él —de ahí el anti-oscilación de P1-C—. **La causa raíz
  merece su propio ciclo**: si el acelerador pudiera distinguir el re-registro con cable
  puesto del zombi, sobrarían tanto esos 19 encendidos como el re-armado.
- **Recién conectado, el externo parpadea en CG**: medido 2026-08-21 (08:24:36 match,
  08:24:37 `4[ext,act]`, **08:24:40 desaparece**, 08:24:41 vuelve). Por eso la ventana
  exige el MISMO ID ≥5 s y ≥5 s sin reconfiguraciones: un disparo a la primera lectura
  apagaría la interna en mitad del baile.
- **Apagar la interna desde el menú sólo mata su propio proxy Embedded** (medido
  2026-08-21, cuatro veces): el External conserva su registry ID. El re-encendido
  **automático** tras un desenchufe tampoco crea ningún External (tres veces). La vía
  «Encender pantalla» del menú con el monitor puesto **no está medida**, y ya no hace
  falta: ese clic desactiva P1-C, así que aunque re-creara el proxy External no habría
  regla que disparar.
- **`hw.model` ya no contiene "Book"** desde 2022 (`Mac15,10`). Para detectar portátil se usa
  la presencia de `AppleSmartBattery`.

### Concurrencia

Toda mutación ordinaria de pantallas (apagado, rescate, espejo) va en `workQueue`, **nunca
en el hilo principal**: se midieron transacciones de CoreGraphics bloqueadas ~21 s, y
bloquear `main` congelaría el timer del watchdog justo en la ventana más peligrosa. Las
emergencias mutan in situ (el fast-path en el hilo del callback CG; el vigía en `ioQueue`)
y se serializan con `fastPathLock` — pero la rama solo-Embedded del vigía no toca CG en
`ioQueue`: delega en el watchdog. `LidSleep` confina su estado en su propia cola, y el
estado de la ventana de apagado diferido (P1-R y P1-C) vive confinado en `workQueue`. El
**match** de IOKit se recibe en `ioQueue` sin estado propio —sólo lee el registro y
despacha a `workQueue`— por la misma razón que la rama solo-Embedded: una llamada
bloqueada ahí retrasaría la siguiente terminación física, que sí es urgente.

Las mutaciones ordinarias **no** se serializan con las emergencias: `turnOffBuiltInSync` no
toma `fastPathLock` a propósito, porque el vigía puede tenerlo 30 s (medido: tres intentos
con `CGError 1014` a ~10 s cada uno) y bloquear ahí el hilo del callback CG sería peor. El
solapamiento está cubierto aguas abajo: la comprobación de integridad tras el apagado acepta
la interferencia y limpia, y re-escribe el ancla si un tercero la borró. P1-C no cambia ese
diseño, pero sí la frecuencia: dispara justo en eventos de cable, que es cuando el vigía
martillea.

## Convenciones

**Idioma.** Todo lo que ve el usuario pasa por `L10n.t` (`struct Strings` con dos instancias
constantes; el compilador obliga a rellenar ambas). **El registro se queda en español a
propósito**: monolingüe y greppable, y los README citan líneas literales. Si añades una cadena
de interfaz, añádela a `Strings`; si es de log, no.

**Motivos que vienen de C.** `pc_can_disable_builtin_why()` devuelve un `pc_deny_reason` y
Swift lo traduce; la variante con texto (`pc_can_disable_builtin`) existe sólo para `probe`.
Nunca parsees cadenas del núcleo para decidir nada.

**Registro.** `write()` va a un búfer en memoria de 200 eventos y **no toca el disco** —
salvo con «Registro detallado» activado (⌥ → Diagnóstico), que vuelca cada evento a disco y
añade un latido cada 30 s mientras haya algo apagado; `writeProblem()` vuelca ese búfer
junto con la anomalía (en modo detallado omite el volcado: ya está todo en disco). En marcha
normal el fichero de log ni se crea. Rota a 128 KB. Usa `writeProblem` sólo para lo que
merece investigación.

**El icono se dibuja por código** (`tools/make-icon.swift`), no es un binario opaco: los
tamaños ≤ 64 px usan una variante más rotunda porque el diseño normal se empasta.

## Riesgos asumidos

APIs privadas (`CGSConfigureDisplayEnabled`, `KeyboardBrightnessClient`): no es distribuible en
App Store y Apple puede romperlas. Firma ad-hoc sin entitlements — si algún día se añade un
atajo global hará falta permiso de Accesibilidad, que una identidad ad-hoc nueva revoca en cada
compilación.

**El `CGError 1014` del vigía, con su alcance real.** Con la interna apagada, desenchufar el
externo hace que el vigía intente el re-encendido en la ventana zombi, y en el registro de
este equipo (05→21 ago 2026, ahora en `PantallaOff.log.1`) ése **agotó los tres intentos con
`CGError 1014` en 15 de 29 desenchufes**.

**Ojo con lo que ese número NO dice.** «El enable del vigía falló» ≠ «el usuario se quedó sin
pantalla», y el registro no puede distinguirlo: hasta el 21-ago el «Registro detallado» estaba
desactivado, así que los rescates posteriores (`write("rescate: …")`) no llegaban a disco.
Sólo `writeProblem` se registraba, y ahí están los datos que sí acotan el daño:

- **`*** SIN SALIDA POR SOFTWARE ***` aparece CERO veces en los 16 días.** Ése es el mensaje
  del estado irrecuperable de verdad (cero displays activos), y nunca se alcanzó.
- El watchdog registró 5 rescates por `usables=0`, y tras cada fallo del vigía el registro
  continúa con normalidad (la interna vuelve a constar apagada más tarde).
- **Joan, que es quien lo usa, reporta no haberse quedado nunca sin pantalla.**

O sea: el vigía es la PRIMERA red, no la última. Cuando falla en la ventana zombi quedan el
acelerador, el watchdog cuando CG procesa por fin la desconexión, reenchufar y la tapa. La
lectura correcta es «la primera red falla a menudo y las siguientes lo tapan», no «se pierde
la pantalla la mitad de las veces». No repitas la segunda: se afirmó en una sesión sin
verificar el desenlace de cada fallo, y el dato empírico la contradice.

Sigue mereciendo su ciclo —una primera red que falla el 52 % es un mal sitio donde estar, y
P1-C hace habitual el estado de partida—, pero **no es un bloqueante de publicación**.

**Sin medir** (pendiente con la sonda):

- Si un monitor que se apaga por su botón mata su `DCPAVServiceProxy`. Si lo mata,
  encenderlo cuenta como conexión y P1-C vuelve a apagar la interna — coherente con la
  preferencia, pero conviene medirlo antes de documentarlo como comportamiento.
- **La cuarta capa del re-armado, en un dock o hub**: si ahí el proxy External tarda MÁS de
  20 s en morir, o no muere, el re-armado abriría ventana con el cable fuera. Entonces todo
  depende de que, con la interna ya encendida, `pc_usable_external_count()` caiga a 0 — algo
  que se da por cierto pero **no está medido**: el zombi sólo se midió con la interna
  apagada. Medirlo: interna apagada, sonda mirando, tirar del cable, y registrar cuándo
  muere el proxy y si los externos utilizables llegan a 0 tras el enable de emergencia.
