# MonitorSwitch

An on-demand Windows helper that switches André's Samsung LU28R55 between the PC and a MacBook from a Logitech LIFT button, using Logi Options+ to launch it.

**Status: implemented, installed and in daily use on the target PC. Supervised switching, the fresh-process gate, the button probe matrix, ten round trips and busy/debounce behavior passed on 12 November 2026. Sleep/resume, monitor reconnect and laptop-asleep checks are still open; see [acceptance](docs/ACCEPTANCE.md).**

The implementation follows [the v1.1 design](docs/DESIGN-v1.1.md).

This branch also implements the Windows half of [v1.2 keyboard/mouse following](docs/DESIGN-v1.2.md). The current build passes 232 hardware-free tests, both individual follower gates, and one owner-confirmed combined monitor/keyboard/mouse handoff. It has not been installed. The installed v1.1 executable rejects the local config while followers are enrolled, so its existing button action is not currently usable. See the [Windows follower setup](docs/SETUP.md#windows-v12-keyboard-and-mouse-followers), [acceptance ledger](docs/ACCEPTANCE.md), and [Windows findings for Mac development](mac/WINDOWS-HANDOFF.md).

## Using it

Press the small round button next to the LIFT scroll wheel. Each press toggles the monitor's input (VCP 0x60) between the two tested values:

| Value | Source on this PC |
| --- | --- |
| 5 | PC |
| 6 | MacBook |

A switch takes about 1.1 s and is confirmed by reading the input back. The button keeps working while the monitor shows the MacBook, and always toggles from the input actually showing, including after a change made with the monitor's own buttons.

- A press while a switch is still running is ignored silently (Busy). A press within 1.5 s of the last switch is ignored with a short beep (Debounced). Nothing is queued.
- Any other failure beeps once. `%LOCALAPPDATA%\MonitorSwitch\last-result.json` says what happened; an uncertain monitor write is reconciled on the next launch.
- The monitor's own input button always works as a fallback.

## How it works

`MonitorSwitch.exe` with no arguments (or `toggle`) runs once and exits:

1. Takes a nonblocking per-user lock. A second launch returns Busy instead of waiting.
2. If an earlier run was interrupted, reads the monitor to resolve that operation and stops without switching.
3. Applies the cooldown, finds the enrolled monitor by exact device path and EDID hash, and reads VCP 0x60.
4. Saves a pending record, calls `SetVCPFeature(0x60, 5↔6)` exactly once, and reads back until the target is seen or the deadline passes. It never retries the write or rolls back.
5. Saves the outcome to `state.json` atomically, writes `last-result.json` and a JSONL log line, then releases the monitor handles and the lock.

Other commands: `discover --json --output PATH`, `status --output PATH`, `diagnose --output PATH`, `enroll --device-path PATH --edid-hash HASH [--replace]`, `set --input 5|6`, `toggle --dry-run`, `probe-trigger`.

With v1.2 followers enrolled, a confirmed toggle toward the away input also moves the keyboard, then the mouse. All followers must pass preflight before any channel change. `set --input` and `toggle --no-follow` move only the monitor. A homeward toggle keeps the devices on the PC. `toggle --dry-run` includes a read-only follower plan when following would apply.

New commands: `followers --output PATH`, `enroll-follower --name NAME --product-id PID --channel N [--replace]`, `enroll-follower --name NAME --remove`, and supervised `follow [--device NAME]`. The optional `follow` section keeps config schema 1. Without it, the helper retains v1.1 behavior.

| Exit | Meaning |
| --- | --- |
| 0 | Confirmed, already selected, or a successful read-only/enrollment/probe command |
| 2 | Busy or Debounced |
| 10 | Invalid configuration or command |
| 11 | Monitor missing or ambiguous |
| 12 | Input unreadable |
| 13 | Unexpected input value |
| 14 | Write made no change |
| 15 | Outcome unverified; the pending operation is kept |
| 16 | Interrupted operation resolved; no switch made |
| 17 | Follow incomplete or follower dry-run preflight refused; the monitor may already have switched |
| 20 | Internal or persistence error |

Full semantics are in design §7.

Follower observations appear only in derived reports, never in `state.json`. `Left` means a native disconnect was observed here; it does not prove arrival on the other computer. Silence or uncertain I/O is `Unknown`. Sends are never retried or rolled back. Recover with the K860 Easy-Switch keys, the LIFT underside button, and the monitor's input button.

`MonitorSwitch.TriggerProbe.exe` (no arguments) only appends a JSON line to `%LOCALAPPDATA%\MonitorSwitch\logs\trigger-probe-YYYY-MM-DD.jsonl`. It proves a button fires once per press before the real switch is bound.

## Files on the PC

Everything lives under `%LOCALAPPDATA%\MonitorSwitch` and stays out of Git:

| Path | Contents |
| --- | --- |
| `bin\` | Installed package; Options+ launches `bin\MonitorSwitch.exe` |
| `config.json` | Enrollment (device path, EDID hash) and settings; `config.previous.json` after re-enrollment |
| `state.json` | Authoritative pending/last outcome and cooldown |
| `last-result.json` | Most recent result |
| `logs\` | Daily JSONL logs, rotated at 1 MB, kept seven days |

## Build and test

Install a .NET 10 SDK. From the repository root in PowerShell 7+:

```powershell
.\scripts\Build.ps1                     # restore, build, hardware-free tests
.\scripts\Publish.ps1 -Runtime win-x64
```

Tests use deterministic fakes and never touch hardware. They cover command parsing, config/EDID validation, every orchestrator branch (including interruption at each persistence boundary), read-only commands, enrollment, the state store, lock, logs and probe. They do not prove the physical switch or the button works.

`Publish.ps1` writes separate self-contained `app` and `probe` folders under `artifacts` with SHA-256 manifests. It does not install, enroll, bind or switch anything.

First-time setup, enrollment, the button test and installation are in [setup](docs/SETUP.md). To update, copy a tested package over `bin\` while no switch is running. To undo everything, follow [rollback](docs/ROLLBACK.md): restore the button to Task View in Options+ and remove `%LOCALAPPDATA%\MonitorSwitch`.

## Project layout

| Path | Purpose |
| --- | --- |
| `src/MonitorSwitch` | Silent WinExe command boundary |
| `src/MonitorSwitch.Core` | Contracts, command parser, config/EDID validation, orchestrator, read-only commands |
| `src/MonitorSwitch.Windows` | DisplayConfig/GDI/SetupAPI discovery, dxva2 DDC session, boot-aware clock |
| `src/MonitorSwitch.Runtime` | Per-user paths, atomic files, state/config stores, file lock, logs, reports, probe |
| `src/MonitorSwitch.TriggerProbe` | Dedicated no-argument probe executable |
| `tests/MonitorSwitch.Tests` | Hardware-free tests and fakes |
| `config.example.json` | Illustrative config shape; not a valid enrollment |
| `docs/` | Design, setup, acceptance evidence, rollback |

No license has been selected. The source is published at https://github.com/andrepaim/monitor-switch. The app runs no service or background process, and building or publishing changes no mouse assignment or Deskflow setting.
