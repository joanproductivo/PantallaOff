# PantallaOff

**Turn off your MacBook's built-in display with one click — without closing the lid.**

English · [Español](README.es.md)

Apple Silicon · macOS 13+ · MIT · No Xcode required

---

## Why

You're working on an external monitor. Or watching a film on the TV. Either way, the MacBook
screen below is doing nothing useful: it splits your attention, drags windows into it, glows
in the dark, and burns battery.

You could close the lid — but then you lose the keyboard, the trackpad, and Touch ID. And if
you're halfway through a film, closing the lid isn't an option at all.

PantallaOff makes that screen **genuinely disappear**. Not dimmed: gone. macOS behaves as if
you were running a single display. Windows stop wandering there. One click brings it back.

```
┌──────────────────────────────────────┐
│  Pantalla del MacBook: encendida     │
│  Pantallas externas utilizables: 1   │
│  ──────────────────────────────────  │
│  Apagar pantalla del MacBook         │  ← that's the whole idea
│  ──────────────────────────────────  │
│  ☑ Mantener el Mac despierto         │
│      …y la pantalla encendida        │
│  ──────────────────────────────────  │
│  ☑ Abrir al iniciar sesión           │
│  ──────────────────────────────────  │
│  Salir de PantallaOff                │
└──────────────────────────────────────┘
```

## What you get

- **Turn the built-in display off and on** from the menu bar.
- **Keep your Mac awake** — the essential half of Amphetamine, as a single switch. Optionally
  keep the screen on too.
- **Start at login**, if you want it.
- **Nothing else.** No timers, no triggers, no dashboard. It does two things well.

## Install

**Without touching the terminal:**

1. [**Download the project**](https://github.com/joanproductivo/PantallaOff/archive/refs/heads/main.zip)
   and unzip it.
2. **Right-click** `install.command` → **Open** → **Open**.
3. Done. It checks your Mac, builds, installs and launches the app.

> Use right-click → Open, not double-click. Anything downloaded from the internet is
> quarantined by macOS, and that's the standard way to authorise it the first time. If you
> cloned with `git` instead, a plain double-click works.

**If you live in the terminal:**

```bash
git clone https://github.com/joanproductivo/PantallaOff.git
cd PantallaOff && make install && open /Applications/PantallaOff.app
```

Either way you get `/Applications/PantallaOff.app` and a small rescue tool at `~/rescue`.
The app itself never triggers a Gatekeeper warning: you compiled it, so it carries no
quarantine flag.

The only requirement is the Xcode Command Line Tools. If they're missing, the installer opens
Apple's installer for you and tells you to run it again afterwards. No Xcode needed.

Look for the laptop icon in the menu bar, next to the clock.

To enable **Abrir al iniciar sesión**, the app must live in `/Applications`, which is where
`make install` puts it. It never re-applies the "off" state at startup: launching PantallaOff
only puts the icon in your menu bar.

## Using it

Click **Apagar pantalla del MacBook**. That's it.

The item is greyed out with a reason when it wouldn't be safe — no usable external display,
or your built-in is currently the source of a mirror set. To bring the screen back, click
again, quit the app, or run `~/rescue`.

**Hidden diagnostics.** Hold **⌥ Option** while opening the menu to reveal *Open the log*
and *Force re-enable all displays*. Neither is needed in normal use — the app only ever turns
off one screen, so "re-enable all" does the same thing as the regular toggle. They're there
for when something goes wrong.

**One caveat about mirroring.** If your built-in is the *source* of a mirror set, turning it
off would leave the whole set without a source, so the app refuses and offers to break the
mirror first. Being the mirrored *copy* is fine — it turns off normally.

---

## How it works — and what we learned the hard way

The interesting part isn't turning the screen off. That's three calls to
`CGSConfigureDisplayEnabled`, a private CoreGraphics API — the same one behind BetterDisplay
and [DisplayDeck](https://github.com/oabdrabo/DisplayDeck).

The interesting part is everything the documentation doesn't tell you. All of the following
was **measured on real hardware** (M3 Max, macOS 26.6), not inferred:

**A disabled display vanishes from the system.** It leaves `CGGetOnlineDisplayList` and even
System Information. You can only bring it back if something remembered its `CGDirectDisplayID`
first — and a MacBook's built-in panel can't be replugged by hand. So the ID is written to
disk, with `fsync`, *before* the display is touched.

**There is no getter.** `CGSConfigureDisplayEnabled` exists; `CGSGetDisplayEnabled` does not.
You cannot ask the system whether a display is off. The app has to remember.

**`CGDisplayIsActive == false` does not mean "off".** Under hardware mirroring the slave
display reports `false` with its panel perfectly lit. Every safety check here runs against
`CGGetActiveDisplayList`, never the online list — an early version got this wrong and
confidently reported a lit screen as disabled.

**`kCGConfigureForAppOnly` does not protect you.** The SDK header promises the system reverts
app-scoped configuration when the process dies. It reverts mode and topology — but *not* the
private `enabled` bit. Verified by `kill -9`: twelve seconds later, the display was still
gone. That's why the recovery watchdog lives in a **separate process**, reparented to launchd,
which survives `SIGKILL`.

**At zero active displays, recovery is impossible.** If you unplug the external while the
built-in is off, WindowServer accepts the enable request and then fails the panel's hotplug at
the framebuffer layer. Roughly fifty retries over eighteen minutes changed nothing. The same
failure appears in [BetterDisplay#5658](https://github.com/waydabber/BetterDisplay/issues/5658)
with WindowServer's own log: `Failed to plug display 1`.

### The zombie

That last one had a twist worth writing down, because we couldn't find it documented anywhere.

With the built-in disabled, unplugging the external monitor **never reaches CoreGraphics**.
WindowServer doesn't process the disconnection, and CG keeps reporting the monitor as online,
active and awake. A zombie. Captured by the app's own heartbeat:

```
23:17:07  cg-ve: 2[ext,act] usables=1     ← cable connected
23:17:40  cg-ve: 2[ext,act] usables=1     ← CABLE UNPLUGGED — no change
23:17:56  cg-ve: 22[ext,act]              ← reconnected: comes back with a new ID
```

Any watchdog built on CoreGraphics is structurally blind here. It cannot see the problem.

But the zombie is also the opportunity: **while it exists, WindowServer still believes it has
a live display** — which is exactly the condition under which re-enabling the built-in
*succeeds*. We only needed to learn about the unplug through a channel that doesn't depend on
WindowServer. IOKit is that channel: the monitor's `DCPAVServiceProxy` terminates on physical
disconnect. macOS takes ~10 s to tear it down, and the moment the notification arrives, the
enable lands inside the zombie window:

```
iokit: physical unplug, enable in zombie window; enable(1) -> CGError 0
```

And there's a faster tell. Sometimes CG *does* react to the unplug — by re-registering the
zombie under a **new display ID** (`2 → 23` above). A known external vanishing from the set,
even if another ID replaces it, now triggers the recovery instantly.

The three observed failure modes are each covered:

| What happens when you unplug | Covered by | Latency |
|---|---|---|
| CG re-enumerates with a new ID | Accelerator | instant |
| CG processes the removal properly | Reconfiguration callback | instant |
| CG stays silent (pure zombie) | IOKit watcher | ~10 s |
| You close the lid / sleep the Mac | Pre-emptive re-enable before sleep | before sleeping |

One rule ties it together: **no automatic path may ever turn a display off.** The watchdog,
the wake handler and every callback can only turn displays *on*. Turning one off always takes
a click.

---

## If something goes wrong

You're unlikely to need this — the layers above handle the cases we could find. But the
recovery paths exist, they're tested, and they're worth two minutes of your attention.

**The built-in didn't come back.** Reconnect the external monitor and the built-in returns.
Or close and reopen the lid: the app turns the screen on before the Mac sleeps, so it's
already alive when you open it.

**No display at all.** Reconnect the monitor first. If you can't:

```bash
sudo killall -HUP WindowServer
```

This restarts the graphics session in about ten seconds — you land at the login screen on the
built-in display, without rebooting. You lose open apps, like a logout. It works over SSH,
which is worth setting up (System Settings → General → Sharing → Remote Login) if you plan to
use this on the road. Shortcut: `~/rescue --last-resort`.

Worst case: hold the power button. The configuration is never permanent, so a reboot always
restores the display.

**The `~/rescue` tool** is a standalone binary, deliberately at a short path so you can type it
blind. It does nothing at all when there's nothing to rescue.

| Command | What it does |
|---|---|
| `~/rescue` | Restores anything that's off. A genuine no-op otherwise. |
| `~/rescue --status` | Reports only. Touches nothing. |
| `~/rescue --restore` | Forces a full display-configuration restore. |
| `~/rescue --last-resort` | Restarts the graphics session (logout, not reboot). |

The app keeps a log at `~/Library/Logs/PantallaOff.log` (⌥ + menu → *Open the log*) . It records real events
only — switching displays, rescues, errors — which is a handful of lines a day. It rotates at
128 KB, so it can't grow without bound.

If you're chasing something, ⌥ + menu → *Registro detallado* adds a heartbeat every 30 seconds
while a display is off, so silence stops being a possible result. Off by default: with a
screen turned off all day it wrote about a thousand lines.

---

## Building and hacking

```bash
make          # help
make all      # tools + app + signed bundle
make probe    # read-only: what CoreGraphics currently sees
make status   # display state + dead-man status
```

```
src/PantallaCore.{h,c}    the safety predicate, mutation, state, rescue — one implementation
src/Bridge.h              exposes the C core to Swift
src/DisplayControl.swift  watchdog, IOKit watcher, dead-man, logging
src/KeepAwake.swift       keep awake (IOPMAssertion — public API)
src/LoginItem.swift       start at login (SMAppService)
src/AppDelegate.swift     menu bar
tools/probe.c             read-only probe
tools/rescue.c            rescue tool + out-of-process dead-man
tools/selftest.c          validation against a chosen display
install.command           one-click installer (double-clickable in Finder)
```

`PantallaCore.c` is the single implementation of the safety predicate. Swift doesn't reimplement
it — it links the same object through `Bridge.h`, so the two can't drift apart.

If you're contributing: validate against an **external** monitor first. It's the only display
you can replug by hand. `selftest` refuses to target the built-in unless you pass
`--allow-builtin`.

## Limitations

- **Private API.** Not App Store material, and Apple could break it in a future macOS.
- **Verified on macOS 26.6 only.** The build targets macOS 13+ and compiles cleanly there, and
  the disconnect API is documented as working from macOS 13 on Apple Silicon — but everything
  in this README was measured on 26.6. On older releases, treat it as untested.
- **Apple Silicon only.** Nothing here was tried on Intel.
- **The off state doesn't survive a reboot.** That's deliberate — it's the final safety net.
- **Keep-awake doesn't override closing the lid.** macOS forces sleep regardless of any
  assertion, and here that's a feature: closing the lid is your reliable way back.
- **Ad-hoc signature.** Fine today. If you ever add a global hotkey you'll need Accessibility
  permission, which a fresh ad-hoc identity revokes on every build — switch to a stable
  self-signed certificate then.

## Credits

Built on the API surface mapped out by [BetterDisplay](https://github.com/waydabber/BetterDisplay),
[Lunar](https://lunar.fyi), [DisplayDeck](https://github.com/oabdrabo/DisplayDeck) and
[displayplacer](https://github.com/jakehilborn/displayplacer). Alin Panaitiu's write-up on
[reverse engineering clamshell mode](https://alinpanaitiu.com/blog/turn-off-macbook-display-clamshell/)
saved us from a dead end.

## License

MIT.
