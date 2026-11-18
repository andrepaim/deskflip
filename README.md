# deskflip

One button moves André's desk between a Windows PC and a MacBook: a press of the round button on the Logitech LIFT switches the Samsung LU28R55 to the other computer, then sends the ERGO K860 keyboard and the LIFT itself there too. Each computer has a small one-shot helper that Logi Options+ launches from that button. There is no network link, background service or KVM hardware.

The project was called MonitorSwitch until 18 November 2026, and that name stays inside the code: the executable, the install folders and the Mac app's bundle identifier keep it, because the button bindings and the Mac's Input Monitoring permission depend on them.

**Status, 18 November 2026: in daily use in both directions.** The Windows helper (v1.2) and the Mac helper (0.1.2) are installed and bound to the button. Measured evidence, including the open items, is in the [Windows acceptance ledger](docs/ACCEPTANCE.md) and the [Mac acceptance ledger](mac/ACCEPTANCE.md).

## Using it

Press the small round button next to the LIFT scroll wheel.

| Pressed on | What happens |
| --- | --- |
| PC, monitor showing the PC | Monitor to the Mac (input 6), confirmed by reading it back; then the keyboard, then the mouse, change to their Mac Easy-Switch channels |
| PC, monitor showing the Mac | Monitor back to the PC only; the devices stay. This recovers from a stranded picture |
| Mac | Monitor to the PC (input 5) through `m1ddc`; then the keyboard and the mouse to their PC channel |

A PC→Mac press takes about 2–3 s, as measured on the PC. A press while a switch is running, or within the cooldown, is ignored; nothing is queued. Any failure beeps on the PC and is described in `last-result.json` on that computer.

Manual controls always work and are the recovery path: the monitor's own input button, the K860's Easy-Switch keys and the button under the LIFT.

## How it works

The design is in [v1.1](docs/DESIGN-v1.1.md) (the monitor switch) and [v1.2](docs/DESIGN-v1.2.md) (keyboard and mouse follow). In short:

- **Monitor:** DDC/CI, VCP 0x60, fixed values 5 (PC) and 6 (Mac). One write per press, never retried or rolled back. The PC reads the input back; the Mac cannot, so its command is "accepted", not confirmed.
- **Keyboard and mouse:** Logitech HID++ "change host" (feature 0x1814), the command the physical Easy-Switch buttons send. Both devices are paired directly over Bluetooth LE. Each device must pass every check (exact identity, destination paired, destination host name as enrolled) before any device is sent, and each gets at most one command per press.
- **Order:** on the PC, monitor first, then devices; on the Mac, device checks first, then the monitor, then devices. The keyboard always moves before the mouse, because the mouse carries the button.
- **No resident processes:** each press launches a helper that runs once and exits. Logitech Flow stays off.

## The two helpers

| | Windows | Mac |
| --- | --- | --- |
| Code | `src/`, C# / .NET 10 | `mac/`, Swift |
| Launched by | Options+: `%LOCALAPPDATA%\MonitorSwitch\bin\MonitorSwitch.exe` | Options+ for Mac: `~/Applications/MonitorSwitch/MonitorSwitch.app` |
| Per-user files | `%LOCALAPPDATA%\MonitorSwitch` | `~/Library/Application Support/MonitorSwitch` |
| Monitor control | dxva2 `SetVCPFeature`, readback | `m1ddc display <UUID> set input 5` |
| Device access | Shared HID handle | IOKit HID, not seized; needs Input Monitoring |
| Setup | [Windows setup](docs/SETUP.md) | [Mac helper](mac/README.md) |

Both use the same per-device protocol surface and the same guards; they share no code and never talk to each other.

### Windows commands

`MonitorSwitch.exe` with no arguments (or `toggle`) is the button action. Other commands: `discover`, `status`, `diagnose`, `enroll`, `set --input 5|6` (monitor only), `toggle --dry-run`, `toggle --no-follow`, `followers`, `enroll-follower`, `follow [--device NAME]` and `probe-trigger`. Details and exit codes are in [setup](docs/SETUP.md) and design [v1.1 §7](docs/DESIGN-v1.1.md) / [v1.2 §6](docs/DESIGN-v1.2.md).

### Mac commands

`MonitorSwitch.app`, or `monitor-switch-mac` with no arguments, is the button action. Other commands: `--dry-run`, `followers`, `displays`, `enroll`, `follow [--device keyboard|mouse]`, `probe-trigger` and `--version`. See the [Mac helper README](mac/README.md).

## Build and test

Automated tests use fakes only and never touch the monitor or the devices.

**Windows helper**, from the repository root with the .NET 10 SDK in PowerShell 7+:

```powershell
.\scripts\Build.ps1                     # restore, build, hardware-free tests
.\scripts\Publish.ps1 -Runtime win-x64  # self-contained package under artifacts\, not installed
```

**Mac helper**, from `mac/`: `swift build` and `swift test`. On Windows (Swift for Windows, in a Visual Studio developer shell) this builds and tests the shared core; the IOKit and `m1ddc` code compiles only on macOS. The `mac-helper` CI job builds, tests and ad hoc signs the macOS binary and app bundles. No source code lives on the Mac: test builds are published as GitHub pre-releases and downloaded there.

CI (`.github/workflows/build.yml`) runs the .NET build and tests on Ubuntu and Windows, and the Mac helper on macOS.

## Project layout

| Path | Purpose |
| --- | --- |
| `src/MonitorSwitch` | Windows WinExe command boundary |
| `src/MonitorSwitch.Core` | Contracts, parser, config, orchestrator, HID++ session, followers |
| `src/MonitorSwitch.Windows` | Monitor discovery, DDC session, HID transport, clock |
| `src/MonitorSwitch.Runtime` | Per-user paths, atomic files, stores, lock, logs, reports |
| `src/MonitorSwitch.TriggerProbe` | Harmless probe for testing the button |
| `tests/MonitorSwitch.Tests` | Windows hardware-free tests |
| `mac/` | Mac helper: Swift package, tests, app bundle script, Mac docs and evidence |
| `docs/` | Designs, Mac build plan, Windows setup, acceptance evidence, rollback |
| `config.example.json` | Illustrative Windows config shape; not a valid enrollment |

Machine configuration, state, logs, serials, host names and local evidence stay out of Git. To undo the setup, follow [rollback](docs/ROLLBACK.md).

No license has been selected. The source is published at https://github.com/andrepaim/deskflip (formerly `monitor-switch`; old links redirect).
