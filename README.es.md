# PantallaOff

**Apaga la pantalla interna de tu MacBook con un clic — sin cerrar la tapa.**

[English](README.md) · Español

Apple Silicon · macOS 13+ · MIT · No necesita Xcode

---

## Por qué

Estás trabajando en un monitor externo. O viendo una película en la tele. En cualquier caso,
la pantalla del MacBook, ahí abajo, no aporta nada: te parte la atención, se traga ventanas,
alumbra a oscuras y gasta batería.

Podrías cerrar la tapa, pero entonces pierdes el teclado, el trackpad y el Touch ID. Y si
estás a media película, cerrarla no es ni una opción.

PantallaOff hace que esa pantalla **desaparezca de verdad**. No atenuada: fuera. macOS se
comporta como si sólo tuvieras un monitor. Las ventanas dejan de irse ahí. Un clic la
devuelve.

```
┌──────────────────────────────────────┐
│  Apagar pantalla del MacBook         │  ← toda la idea es esto
│  ──────────────────────────────────  │
│  ☐ Mantener el Mac despierto         │
│  ☐ Apagar luz del teclado            │
│  ──────────────────────────────────  │
│  ☐ Abrir al iniciar sesión           │
│  ──────────────────────────────────  │
│  Salir de PantallaOff                │
│  Idioma / Language              ▶    │
└──────────────────────────────────────┘
```

## Qué te llevas

- **Apagar y encender la pantalla interna** desde la barra de menú.
- **Mantener el Mac despierto** — la mitad imprescindible de Amphetamine, en un interruptor.
  Y si quieres, mantener también la pantalla encendida.
- **Apagar y encender la luz del teclado.** Sólo el interruptor: para graduarla ya están las
  teclas de brillo. Al encenderla te devuelve tu ajuste de brillo automático.
- **Abrir al iniciar sesión**, si te apetece.
- **Español e inglés**, conmutables desde el menú y al instante.
- **Nada más.** Sin temporizadores, sin disparadores, sin panel de control. Cada interruptor
  está a un clic.

## Instalación

**Sin tocar la terminal:**

1. [**Descarga el proyecto**](https://github.com/joanproductivo/PantallaOff/archive/refs/heads/main.zip)
   y descomprímelo.
2. **Clic derecho** en `install.command` → **Abrir** → **Abrir**.
3. Ya está. Comprueba tu Mac, compila, instala y abre la app.

> Usa clic derecho → Abrir, no doble clic. macOS pone en cuarentena todo lo que se descarga de
> internet, y ésa es la forma estándar de autorizarlo la primera vez. Si lo clonaste con
> `git`, el doble clic funciona directamente.

**Si vives en la terminal:**

```bash
git clone https://github.com/joanproductivo/PantallaOff.git
cd PantallaOff && make install && open /Applications/PantallaOff.app
```

Por cualquiera de las dos vías acabas con `/Applications/PantallaOff.app` y una pequeña
herramienta de rescate en `~/rescue`. La app en sí nunca provoca un aviso de Gatekeeper: la
has compilado tú, así que no lleva la marca de cuarentena.

Lo único que necesitas son las Herramientas de Línea de Comandos de Xcode. Si te faltan, el
instalador abre el instalador de Apple por ti y te dice que lo vuelvas a ejecutar después.
Xcode completo no hace falta.

Busca el icono de portátil en la barra de menú, junto al reloj. La app sigue el idioma de
tu sistema; para cambiarlo, usa **Idioma / Language** al final del menú.

Para activar **Abrir al iniciar sesión**, la app tiene que estar en `/Applications`, que es
justo donde la deja `make install`. Nunca vuelve a aplicar el apagado al arrancar: abrir
PantallaOff sólo pone el icono en tu barra de menú.

## Cómo se usa

Clic en **Apagar pantalla del MacBook**. Ya está.

El ítem aparece en gris, con el motivo, cuando no sería seguro: sin pantalla externa
utilizable, o cuando tu pantalla interna es la fuente de una duplicación. Para recuperarla:
clic otra vez, salir de la app, o ejecutar `~/rescue`.

**Los interruptores no cierran el menú.** Mantener despierto, luz del teclado, abrir al
iniciar sesión y el idioma se aplican en el sitio: el menú se queda abierto y se re-etiqueta
solo. Las acciones que tocan pantallas sí lo cierran, como debe ser.

**Diagnóstico oculto.** Mantén **⌥ Opción** al abrir el menú para ver el estado actual de las
pantallas, *Abrir el registro*, *Registro detallado* y *Forzar reactivación de todas las
pantallas*. Nada de eso hace falta en el uso normal — la app sólo apaga una pantalla, así que
"reactivar todas" hace lo mismo que el interruptor de siempre. Está ahí para cuando algo va
mal.

**Un matiz sobre la duplicación.** Si tu pantalla interna es la *fuente* de una duplicación,
apagarla dejaría sin origen a todo el conjunto, así que la app se niega y te ofrece romper la
duplicación primero. Ser la *copia* duplicada no es problema: se apaga con normalidad.

---

## Cómo funciona — y lo que aprendimos por las malas

Lo interesante no es apagar la pantalla. Eso son tres llamadas a
`CGSConfigureDisplayEnabled`, una API privada de CoreGraphics — la misma que hay detrás de
BetterDisplay y [DisplayDeck](https://github.com/oabdrabo/DisplayDeck).

Lo interesante es todo lo que la documentación no cuenta. Todo lo que sigue está **medido
sobre hardware real** (M3 Max, macOS 26.6), no deducido:

**Una pantalla desactivada desaparece del sistema.** Sale de `CGGetOnlineDisplayList` y hasta
de Información del Sistema. Sólo puedes recuperarla si alguien recordó antes su
`CGDirectDisplayID` — y el panel interno de un MacBook no se puede reconectar a mano. Por eso
el ID se escribe en disco, con `fsync`, *antes* de tocar la pantalla.

**No existe getter.** `CGSConfigureDisplayEnabled` existe; `CGSGetDisplayEnabled` no. No
puedes preguntarle al sistema si una pantalla está apagada. La app tiene que acordarse.

**`CGDisplayIsActive == false` no significa "apagada".** Con duplicación por hardware, la
pantalla esclava responde `false` con el panel perfectamente encendido. Todas las
comprobaciones de seguridad usan `CGGetActiveDisplayList`, nunca la lista online — una versión
temprana se equivocó aquí y daba por apagada una pantalla que estaba encendida.

**`kCGConfigureForAppOnly` no te protege.** El header del SDK promete que el sistema revierte
la configuración del ámbito de app cuando el proceso muere. Revierte modo y topología, pero
*no* el bit privado `enabled`. Verificado con `kill -9`: doce segundos después, la pantalla
seguía desaparecida. Por eso el vigilante de recuperación vive en un **proceso aparte**,
reparentado a launchd, que sobrevive a `SIGKILL`.

**Con cero pantallas activas, la recuperación es imposible.** Si desconectas el externo con la
interna apagada, WindowServer acepta la petición de encendido y luego falla el hotplug del
panel en la capa del framebuffer. Unos cincuenta reintentos durante dieciocho minutos no
cambiaron nada. El mismo fallo aparece en
[BetterDisplay#5658](https://github.com/waydabber/BetterDisplay/issues/5658), con el log del
propio WindowServer: `Failed to plug display 1`.

### El zombi

Este último tenía un giro que merece quedar escrito, porque no lo encontramos documentado en
ningún sitio.

Con la interna desactivada, quitar el cable del monitor externo **no llega nunca a
CoreGraphics**. WindowServer no procesa la desconexión, y CG sigue informando del monitor como
online, activo y despierto. Un zombi. Capturado por el propio latido de la app:

```
23:17:07  cg-ve: 2[ext,act] usables=1     ← cable conectado
23:17:40  cg-ve: 2[ext,act] usables=1     ← CABLE FUERA — sin cambios
23:17:56  cg-ve: 22[ext,act]              ← al reconectar: vuelve con ID nuevo
```

Cualquier vigilante construido sobre CoreGraphics está estructuralmente ciego aquí. No puede
ver el problema.

Pero el zombi es también la oportunidad: **mientras existe, WindowServer aún cree que tiene
una pantalla viva** — que es exactamente la condición en la que reactivar la interna *sí*
funciona. Sólo faltaba enterarse del desenchufe por un canal que no dependa de WindowServer.
IOKit es ese canal: el `DCPAVServiceProxy` del monitor termina al desconectarlo físicamente.
macOS tarda unos 10 s en cerrarlo, y en cuanto llega el aviso, el encendido entra dentro de la
ventana zombi:

```
iokit: desenchufe físico, enable en ventana zombi; enable(1) -> CGError 0
```

Y hay una señal más rápida. A veces CG *sí* reacciona al desenchufe: vuelve a registrar el
zombi con un **ID de pantalla nuevo** (`2 → 23` arriba). Que un externo conocido desaparezca
del conjunto, aunque otro ID lo reemplace, ahora dispara la recuperación al instante.

Los tres modos de fallo observados están cubiertos:

| Qué pasa al desenchufar | Lo cubre | Latencia |
|---|---|---|
| CG re-enumera con un ID nuevo | Acelerador | instantáneo |
| CG procesa bien la desconexión | Callback de reconfiguración | instantáneo |
| CG se queda callado (zombi puro) | Vigía IOKit | ~10 s |
| Cierras la tapa / duermes el Mac | Encendido preventivo antes de dormir | antes de dormir |

Una regla lo sostiene todo: **ninguna ruta automática puede apagar jamás una pantalla.** El
vigilante, el manejador de despertar y todos los callbacks sólo pueden *encender*. Apagar
siempre requiere un clic.

---

## Si algo va mal

Es poco probable que lo necesites — las capas de arriba cubren los casos que supimos
encontrar. Pero las vías de recuperación existen, están probadas y merecen dos minutos de tu
atención.

**La interna no ha vuelto.** Reconecta el monitor externo y la interna regresa. O cierra y
abre la tapa: la app enciende la pantalla antes de que el Mac se duerma, así que ya está viva
cuando la abres.

**Ninguna pantalla.** Reconecta primero el monitor. Si no puedes:

```bash
sudo killall -HUP WindowServer
```

Reinicia la sesión gráfica en unos diez segundos: apareces en la pantalla de inicio de sesión,
en el panel interno, sin reiniciar el equipo. Pierdes las apps abiertas, como un cierre de
sesión. Funciona por SSH, que conviene tener activado (Ajustes del Sistema → General →
Compartir → Inicio de sesión remoto) si vas a usar esto fuera de casa. Atajo:
`~/rescue --last-resort` (para ejecutarlo sin teclear la contraseña a ciegas, instala la
regla mínima de sudo de `tools/sudoers-pantallaoff` — instrucciones dentro del fichero).

En el peor caso: mantén pulsado el botón de encendido. La configuración nunca es permanente,
así que un reinicio siempre devuelve la pantalla.

**La herramienta `~/rescue`** es un binario independiente, en una ruta corta a propósito para
poder teclearla a ciegas. No hace absolutamente nada cuando no hay nada que rescatar.

| Comando | Qué hace |
|---|---|
| `~/rescue` | Reactiva lo que esté apagado. Si no hay nada, no toca nada. |
| `~/rescue --status` | Sólo informa. No toca nada. |
| `~/rescue --restore` | Fuerza una restauración completa de la configuración de pantallas. |
| `~/rescue --last-resort` | Reinicia la sesión gráfica (cierre de sesión, no reinicio). |

**El registro se queda vacío.** En marcha normal PantallaOff no escribe nada en disco — el
fichero ni se crea. Los eventos se guardan en un búfer en memoria de 200 entradas.

Ese búfer sólo llega al disco cuando algo va mal de verdad: un rescate que falla, un error de
CoreGraphics, el dead-man disparando. Y entonces se vuelca *junto con* los eventos anteriores,
porque cuando investigas una pantalla en negro lo que necesitas no es el error suelto, son los
minutos previos. Así es exactamente como se encontró el zombi.

Si estás investigando algo, ⌥ + menú → *Registro detallado* lo escribe todo en directo,
incluido un latido cada 30 segundos mientras haya una pantalla apagada. Desactivado por
defecto. En cualquier caso el fichero rota a los 128 KB, así que nunca puede crecer sin freno.

---

## Compilar y trastear

```bash
make          # ayuda
make all      # herramientas + app + bundle firmado
make probe    # solo lectura: qué ve CoreGraphics ahora mismo
make status   # estado de pantallas + dead-man
```

```
src/PantallaCore.{h,c}    el predicado de seguridad, mutación, estado, rescate — una sola implementación
src/Bridge.h              expone el núcleo C a Swift
src/DisplayControl.swift  watchdog, vigía IOKit, dead-man, registro
src/KeepAwake.swift       mantener despierto (IOPMAssertion — API pública)
src/KeyboardLight.swift   luz del teclado (CoreBrightness, privada)
src/L10n.swift            cadenas en español e inglés
src/LoginItem.swift       abrir al iniciar sesión (SMAppService)
src/AppDelegate.swift     barra de menú
tools/probe.c             sonda de solo lectura
tools/rescue.c            herramienta de rescate + dead-man fuera de proceso
tools/selftest.c          validación contra una pantalla concreta
tools/make-icon.swift     dibuja el icono de la app por código (make icon)
tools/sudoers-pantallaoff regla NOPASSWD opcional para --last-resort
install.command           instalador de un clic (doble clic desde Finder)
```

`PantallaCore.c` es la única implementación del predicado de seguridad. Swift no lo
reimplementa: enlaza el mismo objeto a través de `Bridge.h`, así que no pueden divergir.

Si vas a contribuir: valida siempre primero contra un monitor **externo**. Es la única
pantalla que puedes volver a enchufar a mano. `selftest` se niega a apuntar a la interna a
menos que pases `--allow-builtin`.

## Limitaciones

- **API privada.** No es apta para la App Store, y Apple podría romperla en una macOS futura.
- **Verificado sólo en macOS 26.6.** La compilación apunta a macOS 13+ y ahí compila sin
  problemas, y la API de desconexión está documentada como funcional desde macOS 13 en Apple
  Silicon — pero todo lo que cuenta este README se midió en 26.6. En versiones anteriores,
  dalo por no probado.
- **Sólo Apple Silicon.** Nada de esto se ha probado en Intel.
- **El estado apagado no sobrevive a un reinicio.** Es deliberado: es la red de seguridad
  final.
- **Mantener despierto no vence al cierre de tapa.** macOS fuerza el reposo al margen de
  cualquier assertion, y aquí eso es una ventaja: cerrar la tapa es tu vía fiable de vuelta.
- **Firma ad-hoc.** Hoy no importa. Si algún día añades un atajo de teclado global necesitarás
  permiso de Accesibilidad, y una identidad ad-hoc nueva lo revoca en cada compilación —
  entonces toca pasar a un certificado autofirmado estable.

## Créditos

Construido sobre el mapa de APIs que trazaron
[BetterDisplay](https://github.com/waydabber/BetterDisplay), [Lunar](https://lunar.fyi),
[DisplayDeck](https://github.com/oabdrabo/DisplayDeck) y
[displayplacer](https://github.com/jakehilborn/displayplacer). El artículo de Alin Panaitiu
sobre [ingeniería inversa del modo clamshell](https://alinpanaitiu.com/blog/turn-off-macbook-display-clamshell/)
nos ahorró un callejón sin salida.

## Licencia

MIT.
