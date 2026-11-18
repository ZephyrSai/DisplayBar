# DisplayBar

A native macOS menu bar app for controlling displays — Swift + AppKit, no third-party
code, 1.7 MB, under 9 MB of memory and 0% CPU when idle. Apple silicon, macOS 14+.

**Website:** https://zephyrsai.github.io/DisplayBar/ · **Download:** [latest release](https://github.com/ZephyrSai/DisplayBar/releases/latest)

## What it does

| | |
|---|---|
| **Turn displays off** | Every display has a switch. Off disconnects it the way BetterDisplay does (SkyLight `CGSConfigureDisplayEnabled`): it leaves the desktop, windows move away, and the panel stops being driven. Works for the built-in screen with the lid open. |
| **Brightness & volume** | Built-in/Apple displays through DisplayServices; external monitors through DDC/CI (brightness and speaker volume sliders, click the speaker to mute — emulated when the monitor has no mute command); gamma dimming for anything that doesn't answer DDC. |
| **Keyboard keys (optional)** | Brightness keys drive the external display under the pointer; volume keys drive a monitor's speakers when sound plays through them. Needs Accessibility; off by default. |
| **Monitor controls (DDC)** | Contrast, input source, and "sleep monitor" (DDC standby while macOS keeps it connected). |
| **Arrange Displays** | The System Settings arrangement canvas: drag screens (edge snapping and alignment), drag the menu bar to choose the main display. |
| **Resolution & refresh rate** | HiDPI "looks like" sizes on Retina-class panels, plain resolutions elsewhere, or every mode with *Show All Resolutions*. |
| **More** | Rotation, HDR on/off, XDR/reference presets, main display, mirroring, renaming. |
| **Virtual displays** | Create dummy displays (HiDPI too) — handy for screen sharing, or mirror a real monitor onto a HiDPI virtual one. |

## Keyboard shortcuts

Global shortcuts use Carbon hotkeys, so they work in every app and need no Accessibility or
Input Monitoring permission. Change them in **Settings › Shortcuts**, where you can also give
each display its own on/off shortcut.

| Shortcut | Action |
|---|---|
| ⌃⌥⌘D | Open the DisplayBar menu |
| ⌃⌥⌘B | Turn the built-in display off / on |
| ⌃⌥⌘E | Turn external displays off / on |
| ⌃⌥⌘R | Turn all displays back on (and wake monitors put to sleep over DDC) |
| ⌃⌥⌘↑ / ⌃⌥⌘↓ | Brightness up / down on the display under the pointer (or all displays) |
| — | Turn off the display under the pointer, make it main, monitor volume up / down / mute, Arrange Displays *(unassigned by default)* |

## Safety

- The last physical screen can never be turned off (a virtual display doesn't count).
- If no screen is left anyway — say the external monitor is unplugged while the built-in display
  is off — DisplayBar turns displays back on by itself (not while the lid is closed or the Mac sleeps).
- Quitting (including `kill`/logout) turns displays back on unless you switch that off in Settings.
  Disconnects only last for the login session, so logging out or restarting always restores them.
- Software dimming is restored by macOS when the app exits, even after a crash.

## Any number of displays

Nothing assumes two screens: each display gets its own section, switch, sliders and shortcut,
and DDC is matched per port, so identical monitors stay separate. The self-test runs the real
displays plus four virtual ones at once. Limits come from elsewhere: how many external screens
the chip drives (M4 Pro: two, M4 Max: four), docks/DisplayLink adapters that don't pass DDC
through (those screens still turn off and arrange, and dim in software), and the menu
scrolling once there are roughly eight displays.

## Build

```bash
scripts/build-app.sh                       # ad-hoc signed build/DisplayBar.app
SIGN_IDENTITY=<identity> scripts/build-app.sh
swift scripts/make-icon.swift              # regenerate Resources/AppIcon.icns
```

## Checking it

```bash
.build/release/DisplayBar --list       # read-only report: displays, DDC values, modes, presets
.build/release/DisplayBar --selftest   # 62 checks: safety rules, snapping, shortcuts, real off/on,
                                       # the no-screen rescue, 5+ displays at once, live arrangement
.build/release/DisplayBar --selftest --no-displays   # logic only: no display is added or changed
```

The full self-test never turns off or reconfigures a physical display; it uses temporary virtual
displays (each change makes macOS redraw the menu bar, so expect it to flicker while it runs),
reads the real ones, and does a same-value DDC write. Debug hooks (environment variables):
`DISPLAYBAR_OPEN_MENU=1`, `DISPLAYBAR_SETTINGS=0|1`, `DISPLAYBAR_SNAPSHOT=<dir>` (renders
Settings, Arrange, menu rows and the HUD to PNGs, then quits), `DISPLAYBAR_TOUR=1` (opens and
closes each part of the UI on a timeline, for footprint measurements).

## Footprint (M4 Pro, macOS 26)

| State | Memory |
|---|---|
| Idle | 8.7 MB |
| Menu open / closed | 15 / 14 MB |
| Settings open / closed | 23 / 17 MB |
| Arrange open / closed | 19 / 17 MB |

0.0% CPU and ~0 wakeups when idle (no timers, no polling). The menu, Settings, Arrange and the
HUD are built on demand and released when closed; freed pages are handed back to macOS.

## How it's put together

| File | Role |
|---|---|
| `DisplayManager.swift` | Display list, off/on with the remembered "off" records, rescue logic, modes, arrangement, DDC volume/mute |
| `ArrangeWindow.swift` | Arrange Displays canvas and the snapping rules |
| `MediaKeys.swift` | Optional brightness/volume key handling and the monitor-audio lookup |
| `DDC.swift` | DDC/CI over `IOAVService`, matched to displays via CoreDisplay's `IODisplayLocation` |
| `Brightness.swift` | DisplayServices / DDC / gamma brightness |
| `VirtualDisplays.swift` | `CGVirtualDisplay` dummies |
| `Hotkeys.swift`, `Actions.swift` | Shortcut model, Carbon hotkeys, actions |
| `MenuController.swift`, `MenuViews.swift`, `HUD.swift`, `Settings.swift` | UI |
| `Sources/CDisplayPrivate` | Declarations for private CoreGraphics classes + a MonitorPanel wrapper (runtime lookups only) |

Private APIs are resolved at runtime, so a missing symbol disables a single feature instead of
stopping the app from launching.

## Credits

Inspired by [BetterDisplay](https://github.com/waydabber/BetterDisplay) by waydabber (no code shared).
The DDC-over-IOAVService approach follows the open research in
[MonitorControl](https://github.com/MonitorControl/MonitorControl) and
[m1ddc](https://github.com/waydabber/m1ddc). The `CGVirtualDisplay` interfaces are as documented
by Chromium's test harness.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
