# PantallaOff

App de barra de menú para **apagar la pantalla interna del MacBook** con un clic, sin cerrar
la tapa, mientras usas un monitor externo.

Usa `CGSConfigureDisplayEnabled`, API privada de CoreGraphics — la misma que emplean
BetterDisplay y [DisplayDeck](https://github.com/oabdrabo/DisplayDeck). No requiere Xcode,
ni entitlements, ni desactivar SIP.

---

## ⚠️ Lee esto antes de nada

Un display desactivado con esta API **desaparece del sistema**: sale de
`CGGetOnlineDisplayList` y de Información del Sistema. Sólo se puede reactivar si algo
**recuerda su `CGDirectDisplayID`**. Y la pantalla interna de un MacBook **no se puede
reconectar físicamente**.

De ahí todo el diseño de este proyecto. Y de ahí esta regla:

> **Valida siempre contra el monitor EXTERNO antes de tocar la interna.**
> El externo se puede desenchufar y volver a enchufar. La interna, no.

---

## Rescate — apréndetelo antes de usar la app

**Antes de apagar la interna, deja una ventana de Terminal abierta y en el prompt.**
Elimina el paso frágil de tener que lanzar Terminal sin ver nada.

### 1. A ciegas, en la propia máquina
```
~/rescue
```

### 2. Por SSH desde el móvil u otro ordenador (no depende de ver nada)

**Requisito previo, hazlo ahora:** Ajustes del Sistema → General → Compartir → activar
**Inicio de sesión remoto**. Sin esto, la única vía de rescate que no necesita ver la
pantalla no existe.

```bash
ssh joan@<esta-mac> '~/rescue'
```
Si eso no funciona porque el proceso no alcanza al WindowServer, usa la forma canónica:
```bash
ssh joan@<esta-mac> 'launchctl asuser $(id -u joan) ~/rescue'
```
**Comprueba cuál de las dos funciona ANTES de necesitarla.** No lo descubras en la emergencia.

### 3. Si `rescue` dice que no hay nada que rescatar y sigues a ciegas
```
~/rescue --restore
```
`rescue` a secas es deliberadamente conservador: sólo actúa si hay **indicios** de que algo
está desactivado (fichero de estado, un display online pero inactivo, o la interna ausente
de la lista online en un portátil). Cero pantallas activas **no** cuenta como indicio,
porque eso es exactamente lo que ocurre cuando el equipo simplemente ha dormido las
pantallas — y ese es el momento típico en que alguien teclea `rescue` a ciegas. `--restore`
salta esa comprobación y aplica `CGRestorePermanentDisplayConfiguration()` sin preguntar.

### 4. Si nada de lo anterior funciona: reiniciar la sesión gráfica (sin reboot)

**Hecho medido (2026-08-04):** con 0 pantallas activas, el enable llega a WindowServer pero
el *hotplug* del panel falla en la capa IOMFB (`Failed to plug display`, mismo log en
[BetterDisplay#5658](https://github.com/waydabber/BetterDisplay/issues/5658)). Reintentar es
inútil; cerrar y abrir la tapa tampoco funciona (medido aquí y confirmado allí). Las vías
"clásicas" están muertas: `launchctl kickstart -k` está bloqueado desde macOS 14.4 y
`CGSession -suspend` ya no existe en macOS 26.

La que sí funciona ([displayplacer#109](https://github.com/jakehilborn/displayplacer/issues/109),
[#126](https://github.com/jakehilborn/displayplacer/issues/126)):

```bash
sudo killall -HUP WindowServer
```

Reinicia la sesión gráfica en ~10 s: vuelves al login **en la pantalla interna**, sin
reiniciar el equipo (pierdes las apps abiertas, como un logout). Por SSH funciona
directamente. Atajo: `~/rescue --last-resort` (usa `sudo -n`; para que funcione sin teclear
contraseña, instala la regla mínima de `tools/sudoers-pantallaoff` — instrucciones dentro
del fichero).

### 5. Último recurso físico
Mantén pulsado el botón de encendido ~10 s y reinicia. La configuración se aplica con
`kCGConfigureForAppOnly`, que no es permanente: el arranque la descarta.

### Comandos de `rescue`
| Comando | Qué hace |
|---|---|
| `rescue` | Reactiva sólo si hay indicios. **Si no los hay, no toca absolutamente nada.** |
| `rescue --status` | Solo informa. No toca nada. |
| `rescue --restore` | Martillo: `CGRestorePermanentDisplayConfiguration()` sin pedir indicios. Puede recolocar las pantallas. |
| `rescue --arm N` | Arma un dead-man: rescata en N s salvo que lo desarmen. Deja rastro en el log al disparar. |
| `rescue --disarm` | Desarma el dead-man pendiente. |

---

## Instalación

```bash
make all
make install
```

Instala `~/rescue` (ruta corta a propósito, para teclearla a ciegas) y
`/Applications/PantallaOff.app`. No habrá aviso de Gatekeeper: un binario compilado
localmente no lleva el xattr `com.apple.quarantine`. **Si aparece un aviso, es síntoma de un
problema real de firma**, no algo normal que ignorar.

---

## Cómo está construida la seguridad

Siete capas, pensadas para que ninguna dependa de la anterior.

| # | Capa | Sobrevive a `kill -9` |
|---|---|---|
| 1 | **Precondición** sobre la lista **Active** (no Online) | n/a |
| 2 | **Estado persistido** en `~/.pantallaoff-state`, escrito **antes** de mutar | ✅ |
| 3 | **Dead-man fuera de proceso** (`rescue --arm`, reparentado a launchd) | ✅ |
| 4 | **`kCGConfigureForAppOnly`** | ❌ **medido: no** (ver abajo) |
| 5 | **Watchdog**: callback + `screenParameters` + wake + **timer de 3 s** | ❌ |
| 5b | **Fast-path en el callback**: re-enable síncrono *durante* la desconexión del externo | ❌ |
| 5c | **Re-encendido preventivo** en `willSleep` / `willPowerOff` | ❌ |
| 5d | **Vigía IOKit**: terminación de `DCPAVServiceProxy` → enable en la ventana zombi (~10 s) | ❌ |
| 5e | **Acelerador CG**: un externo desaparece o se re-registra con otro ID → enable inmediato | ❌ |
| 6 | **`~/rescue` + SSH** fuera de banda, con `--last-resort` (reinicio de WindowServer) | ✅ |
| 7 | **Arranque automático opcional**, y que nunca re-aplica el apagado | n/a |

### ⚠️ La trampa de las 0 pantallas, y cómo se defiende esto

Incidente medido: interna apagada + desconexión física del externo → 0 pantallas → el
hotplug del panel interno **falla en WindowServer** y ningún enable lo arregla (~50
reintentos en 18 min, todos `activos 0 -> 0`). El watchdog *detectó* el problema en
segundos pero no pudo *curarlo*: llegó tarde, el sistema ya estaba sin pantallas.

Defensas añadidas tras el incidente, en orden de actuación:
1. **Fast-path (capa 5b)**: el callback de reconfiguración intenta el re-enable en
   síncrono *mientras* el externo se está yendo, dentro de la ventana de la transición.
   Sólo sobre `removeFlag` — `beginConfigurationFlag` también se dispara durante nuestro
   propio apagado y lo deshacía (bug medido y corregido).
2. **Preventivo (capa 5c)**: al dormir o apagar el Mac con la interna apagada, se
   enciende antes. Cubre el caso "cierro la tapa y me llevo el portátil" — verificado en
   vivo. (Coste asumido: al despertar con el monitor puesto, re-apagar es un clic.)
3. **Vigía IOKit (capa 5d)** y **acelerador CG (capa 5e)**: ver la sección siguiente.
4. Si aun así se llega a 0 pantallas: `rescue` ya no martillea — lo detecta, lo dice en
   el log y las salidas son reconectar el cable o `--last-resort`.

### El zombi: por qué quitar el cable era invisible, y cómo se resolvió

Medido con el latido del watchdog (2026-08-05): con la interna desactivada, al quitar el
cable del externo **WindowServer no procesa la desconexión**. CoreGraphics sigue listando
el externo como online, activo y despierto — un zombi. Sin `removeFlag` y con
`usables=1`, el watchdog y el fast-path son estructuralmente ciegos:

```
23:17:07  cg-ve: 2[ext,act] usables=1     ← cable puesto
23:17:40  cg-ve: 2[ext,act] usables=1     ← CABLE FUERA — y CG lo ve igual
23:17:56  cg-ve: 22[ext,act]              ← reconexión: vuelve con ID nuevo
```

**La vuelta a la tortilla:** mientras el zombi existe, WindowServer cree que tiene una
pantalla viva — que es exactamente la condición en la que el enable de la interna SÍ se
completa (con 0 pantallas "de verdad" el hotplug falla; también medido). Solo hacía falta
enterarse del desenchufe por una vía que no dependa de WindowServer:

- **Capa 5d — IOKit**: el `DCPAVServiceProxy` (Location=External) del monitor **termina**
  al desenchufar físicamente. macOS tarda ~10 s en terminarlo (timeout del enlace); en
  cuanto llega la notificación, el enable entra en la ventana zombi. Verificado en vivo:
  `iokit: desenchufe físico, enable en ventana zombi; enable(1) -> CGError 0` — la
  interna se encendió sola ~10 s después del tirón del cable.
- **Capa 5e — acelerador**: a veces CG sí emite un evento al desenchufar: re-registra el
  zombi con un **ID nuevo** (2→23, observado). Un externo que desaparece del conjunto
  conocido —aunque sea reemplazado por otro ID— dispara el enable al instante. Falso
  positivo posible y asumido: la acción es encender (fail-open), cuesta un clic.

El comportamiento varía entre desenchufes (a veces evento CG inmediato, a veces silencio
total, y en el incidente original CG llegó a quedarse headless de verdad): las capas
5b + 5d + 5e cubren los tres modos observados.

### Sobre el arranque al iniciar sesión

El plan lo había pospuesto por miedo a un bucle de arranque en negro. Ese miedo sólo tiene
sentido si la app re-aplica el apagado al arrancar — y **no lo hace**: P1 prohíbe que
ninguna ruta automática desactive un display. Arrancar al inicio sólo coloca el icono en la
barra de menú; apagar sigue exigiendo un clic. Peor caso si la app fallara al arrancar: no
aparece el icono.

Se activa desde el menú (**Abrir al iniciar sesión**), vía `SMAppService` (macOS 13+).
Requiere tener la app en `/Applications` (`make install`): el elemento de inicio guarda la
**ruta** del bundle, y registrarlo desde `./build` dejaría un arranque roto en cuanto
hicieras `make clean`. La app lo comprueba y se niega con un mensaje explicativo.

**Detalle medido, por si vuelve a confundir:** antes del primer registro,
`SMAppService.mainApp.status` devuelve `.notFound` con una firma ad-hoc. **No** significa
que no se pueda usar — `register()` funciona igualmente y el estado pasa a `.enabled`.
Tratarlo como "no disponible" deshabilitaba el menú sin motivo. Para diagnosticar:

```bash
/Applications/PantallaOff.app/Contents/MacOS/PantallaOff --login-item-diag
```

### ⚠️ Veredicto medido de la capa 4: NO protege

El experimento del plan se ejecutó el 2026-08-04 en macOS 26.6 / M3 Max:
`selftest 2 hold` → `kill -9` → **el display seguía desaparecido 12 segundos después**.

`kCGConfigureForAppOnly` revierte modo y topología, pero **no el bit privado `enabled`**.
Consecuencia directa, tal como anticipaba el plan: **la capa 3 (dead-man fuera de proceso)
deja de ser una red redundante y pasa a ser la única protección real ante la muerte
violenta del proceso.** Por eso `turnOffBuiltIn()` aborta si no consigue armarlo.

(La reversión sí hace *algo*: al terminar el proceso limpiamente se observa un transitorio
de re-enumeración de pantallas de ~1 s. Simplemente no restaura el bit `enabled`.)

### Los principios que hacen que funcione

**Ninguna ruta automática puede apagar un display, jamás.** El watchdog, el handler de
despertar y el de cambio de configuración **sólo pueden encender**. Apagar exige siempre un
clic. Un re-aplicador tras el wake sería una carrera contra la re-enumeración del externo
—que tarda segundos, más a través de un dock— y podría dejar cero pantallas justo al abrir
la tapa.

**El estado se persiste, no se infiere.** No existe ningún getter del bit `enabled`
(`CGSGetDisplayEnabled` no está en el `.tbd` del SDK). Y `CGDisplayIsActive == false` **no**
significa "apagada": bajo espejo hardware el esclavo también da `false` con el panel
perfectamente encendido. Por eso la app distingue *encendida*, *espejando a otra*, *fuente
del espejo*, *apagada por nosotros* y *no encontrada*. Y el fichero de estado guarda, junto
al ID, **si ese ID era la interna** — sin esa marca, un `selftest` interrumpido sobre el
monitor externo haría que la barra de menú declarase apagada una interna encendida.

**Detectar "es la fuente del espejo" necesita prueba positiva.** El criterio obvio
—`inMirrorSet && mirrors == 0`— da falso positivo: con las pantallas dormidas, *todos* los
displays reportan eso a la vez. Hay que exigir que otro display declare explícitamente estar
espejando a la interna.

**El timer del watchdog no es opcional.** El caso peligroso —el externo se duerme por DPMS,
cambias el KVM, cambias la entrada del monitor— **no genera callback de reconfiguración**.
Sólo lo detecta el sondeo periódico.

### El predicado, en un único sitio

`src/PantallaCore.c` es la única implementación. Swift no la reimplementa: enlaza el mismo
objeto a través de `src/Bridge.h`, así que no pueden divergir.

```
externo utilizable = !interna
                  && vendor != 0                    (descarta virtuales/dummy)
                  && ∈ CGGetActiveDisplayList       (Active, NO Online)
                  && !dormido                       (cubre DPMS / monitor apagado)
                  && no es esclavo de un espejo cuya fuente es la interna

se puede apagar   = ∃ externo utilizable
                  && la interna NO es la fuente de un mirror set
```

---

## Procedimiento de validación

**El orden importa. No lo saltes.** Todo se valida contra el externo antes de tocar la interna.

Estado a 2026-08-04, macOS 26.6 / M3 Max: **Fase 1 completa y en verde.** Falta la
prueba 3 (reinicio) y la Fase 2 (contra la interna).

### Fase 0 — Vías de escape
| # | Prueba | Cómo | Resultado |
|---|---|---|---|
| 0 | Instalar | `make install` — sin `~/rescue` no hay rescate a ciegas ni por SSH | ✅ `~/rescue` instalado |
| 1 | SSH fuera de banda | Activar Inicio de sesión remoto; `ssh` desde el móvil, ambas variantes | Remote Login activo; falta probar desde el móvil |
| 2 | **Rescate real** | Desactivar el **externo** → `~/rescue` → ¿vuelve? | ✅ **PASA** — recuperó un display ausente de la lista online, `IDs recuperados 1/1`, sin usar el martillo |
| 3 | **Reinicio** | Desactivar el **externo** → reiniciar → ¿vuelve? | ⏳ pendiente |

### Fase 1 — Validar la API (siempre contra el externo)
| # | Prueba | Cómo | Resultado |
|---|---|---|---|
| 4 | API funciona | `./build/selftest <idExterno> 6` | ✅ **PASA** — apagado y reactivado |
| 5 | **`kill -9` con `ForAppOnly`** | `./build/selftest <idExterno> hold`, luego `kill -9 <pid>` | ✅ ejecutada — **la capa 4 NO protege** (ver arriba) |
| 6 | Dead-man | Ver abajo | ✅ **PASA** — sobrevivió al `kill -9` del padre (PPID 1, seguía armado) |

La prueba 5 decide la capa 4: si el display vuelve solo tras el `kill -9`, el WindowServer
cubre el bit privado `enabled` y tenemos la mejor protección del proyecto gratis. Si no
vuelve, la capa 3 (dead-man) pasa de recomendada a imprescindible.

**Cómo se prueba el dead-man (prueba 6).** No sirve `rescue --arm N` y "matar al padre":
`--arm` re-ejecuta el binario con `POSIX_SPAWN_SETSID` y retorna enseguida, así que no queda
ningún padre al que matar. El procedimiento real es el de la prueba 5, que ejerce ambas
capas a la vez:

```bash
./build/selftest <idExterno> hold      # arma el dead-man y desactiva el externo
kill -9 <pid que imprime>              # desde otra terminal
```
Entonces hay dos resultados posibles y ambos son informativos:
- el display vuelve **al instante** → lo hizo el WindowServer: **capa 4 confirmada**;
- el display vuelve **a los ~300 s** → lo hizo el dead-man: **capa 3 confirmada**, capa 4 no cubre el bit privado.

Comprueba cuál fue en `~/Library/Logs/PantallaOff.log`: el dead-man escribe siempre una
línea `dead-man DISPARA` al actuar. Sin esa línea, fue el WindowServer.

### Fase 2 — Sólo si 1-6 están en verde: la interna
| # | Prueba | Esperado |
|---|---|---|
| 7 | Toggle desde el menú | Interna se apaga, el externo sigue igual |
| 8 | Precondición | Sin externo → ítem deshabilitado, con el motivo |
| 9 | Espejo con master invertido | Se niega, y ofrece romper el espejo |
| 10 | Estado en espejo | La UI dice *espejada*, no *apagada* |
| 11 | Watchdog: desconexión | Interna apagada → quitar cable → vuelve en <3 s |
| 12 | Watchdog: **externo dormido** | Apagar el monitor por su botón → vuelve (esto no genera callback: lo pilla el timer) |
| 13 | Sleep/wake | Dormir y despertar **sin el externo** → nunca cero pantallas |
| 14 | Salir | Interna apagada → Salir → vuelve |

### ⚠️ En modo espejo no se puede ejecutar la Fase 1

Con espejo activo sólo hay **una** pantalla en la lista Active (el master), así que
`selftest` se niega correctamente a desactivar el externo: dejaría cero. **Cambia a modo
extendido** antes de la Fase 1.

---

## Mantener el Mac despierto

Un interruptor en el menú, equivalente al modo básico de Amphetamine y nada más: sin
temporizadores, sin activación por app, sin disparadores.

| Opción | Equivale a | Qué hace |
|---|---|---|
| **Mantener el Mac despierto** | `caffeinate -i` | El sistema no se duerme por inactividad. La pantalla sí puede apagarse. |
| **…y la pantalla encendida** | `caffeinate -d` | Además mantiene la pantalla encendida. Gasta más batería. |

Usa `IOPMAssertionCreateWithName`, API **pública** de gestión de energía — la misma que hay
debajo de `caffeinate`. Esta parte del proyecto no necesita ningún truco. Puedes verificarlo
mientras esté activo:

```bash
pmset -g assertions | grep PantallaOff
```

**No impide el reposo al cerrar la tapa**, y es deliberado por partida doble: macOS lo fuerza
al margen de cualquier assertion, y en este proyecto cerrar la tapa es además tu vía fiable
para recuperar la pantalla interna (capa 5c).

Las assertions se sueltan al salir de la app, así que nunca queda el Mac insomne por un
proceso olvidado.

## Estructura

```
src/PantallaCore.{h,c}    núcleo compartido: predicado, mutación, estado, rescate
src/Bridge.h              expone el núcleo a Swift
src/DisplayControl.swift  watchdog, vigía IOKit, dead-man, log, estado observable
src/KeepAwake.swift       mantener despierto (IOPMAssertion, API pública)
src/LoginItem.swift       arranque al iniciar sesión (SMAppService)
src/AppDelegate.swift     NSStatusItem y menú
src/main.swift            entrada (.accessory)
tools/probe.c             sonda de SOLO LECTURA
tools/rescue.c            botón de pánico + dead-man
tools/selftest.c          validación contra un display concreto
```

Ficheros en `$HOME`: `.pantallaoff-state` (IDs apagados), `.pantallaoff-armed` (pid del
dead-man), `Library/Logs/PantallaOff.log`.

---

## Limitaciones conocidas

- **API privada**: no distribuible en App Store; Apple puede romperla en una macOS futura.
- **El estado no persiste entre reinicios**, a propósito: es la red de seguridad final.
- **Arranque automático**: opcional y desactivado por defecto. Requiere la app en
  `/Applications`. Nunca re-aplica el apagado al arrancar (P1).
- **Firma ad-hoc**: `codesign -s -` da una identidad distinta en cada build. Irrelevante
  ahora (sin entitlements), pero si añades un atajo global necesitarás permiso de
  Accesibilidad y se revocará en cada `make`. Entonces habrá que pasar a un certificado
  autofirmado estable en el llavero.
- `rescue --restore` restaura la configuración permanente del usuario y **puede recolocar
  las pantallas**. Por eso sólo se usa como último recurso, nunca en el camino normal.
- **Romper el espejo** se aplica con `kCGConfigureForSession`: dura hasta que cierres sesión
  y no reescribe tu configuración permanente. Si quieres que persista, desactiva la
  duplicación desde Ajustes del Sistema → Pantallas.
- **No borres `~/.pantallaoff-state` con una pantalla apagada.** Es lo que permite volver a
  encenderla. Si lo pierdes, queda `~/rescue --restore` y, en un portátil, la detección de
  "falta la pantalla interna en la lista online".

## Plan B

Si `CGSConfigureDisplayEnabled` resulta inestable, existe una alternativa sin riesgo de
perder todas las pantallas: poner el brillo de la interna a 0 con `DisplayServicesSetBrightness`
(privada pero benigna). La retroiluminación se apaga del todo, pero el escritorio sigue
existiendo y las ventanas pueden irse ahí. Resuelve menos, no puede dejarte a ciegas.

## Licencia

MIT.
