# PantallaOff

**Turn off your MacBook's built-in display with one click — without closing the lid.**

English · [Español](README.es.md)

macOS 14+ · Apple Silicon · MIT · No Xcode required

---

## Why

You're working on an external monitor. The MacBook screen below it is doing nothing useful:
it splits your attention, drags windows into it, and burns battery.

You could close the lid — but then you lose the keyboard, the trackpad, and Touch ID.

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
│  Reactivar todas las pantallas       │
│  ☑ Abrir al iniciar sesión           │
│  Abrir el registro                   │
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

Requires only the Xcode Command Line Tools (`xcode-select --install`). No Xcode.

```bash
git clone https://github.com/joanproductivo/PantallaOff.git
cd PantallaOff
make install
```

That installs `/Applications/PantallaOff.app` and a small rescue tool at `~/rescue`. Then:

```bash
open /Applications/PantallaOff.app
```

Look for the laptop icon in the menu bar, next to the clock. There's no Gatekeeper warning —
software you compiled yourself doesn't carry the quarantine flag.

To enable **Abrir al iniciar sesión**, the app must live in `/Applications`, which is where
`make install` puts it. It never re-applies the "off" state at startup: launching PantallaOff
only puts the icon in your menu bar.

## Using it

Click **Apagar pantalla del MacBook**. That's it.

The item is greyed out with a reason when it wouldn't be safe — no usable external display,
or your built-in is currently the source of a mirror set. To bring the screen back, click
again, quit the app, or run `~/rescue`.

**Mirroring vs. extended.** If you're mirroring, the built-in is showing a copy of the
external. Turning it off works fine. To actually gain desk space, use System Settings →
Displays → *Extended display*.

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

The app logs everything to `~/Library/Logs/PantallaOff.log` — while a display is off it
records every change plus a heartbeat every 30 seconds, so silence is never a possible result.

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
```

`PantallaCore.c` is the single implementation of the safety predicate. Swift doesn't reimplement
it — it links the same object through `Bridge.h`, so the two can't drift apart.

If you're contributing: validate against an **external** monitor first. It's the only display
you can replug by hand. `selftest` refuses to target the built-in unless you pass
`--allow-builtin`.

## Limitations

- **Private API.** Not App Store material, and Apple could break it in a future macOS.
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
