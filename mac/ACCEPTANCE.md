# Mac helper acceptance evidence

Measured results only. No host names, serials, Bluetooth addresses, display UUIDs, config or logs.

## First implementation, PC build and tests — 18 November 2026

Written on the Windows PC; nothing has run on a Mac.

| Check | Result |
| --- | --- |
| Toolchain | Swift 6.4.2 (swift-6.4.2-RELEASE) for Windows, x86_64-unknown-windows-msvc, installed per user with winget; Visual Studio 2022 C++ tools, Windows SDK 10.0.22621 |
| `swift build` from `mac/` | Build complete; no warnings from `mac/Sources` (the toolchain's own WinSDK module prints `wchar_t` warnings) |
| `swift test` from `mac/` | 46 tests, 0 failures |
| Executable on Windows | Prints "runs only on macOS", exit 21 |
| macOS-only code | `IOKitHid.swift`, `Platform.swift` and the macOS branch of `main.swift` are not compiled on Windows; first compiled by the CI `mac-helper` job |

Covered by the tests: fixed HID++ packets and reply matching, error frames, unrelated notifications, one query retry and bounded deadlines, ambiguous feature indexes, host-name pages and strict UTF-8, change-host rejection in the passive window and during later queries, foreign software-ID errors, at most one change-host per session even when the write throws, Left versus StillHere versus Unknown; preflight of every device before any send, keyboard before mouse, AlreadyThere, Rejected overriding departure; button action order (display check, preflight, one monitor command, sends), no send after monitor failure or timeout, no monitor command after a refused preflight, lock and cooldown touching nothing, dry-run, `follow`, `followers`, `probe-trigger`; strict config and enrollment refusals with a kept previous config; command-line parsing; `m1ddc` arguments and whole-token display matching.

## First CI macOS build — 18 November 2026

Run 44313632840, commit `d087c9f`, job `mac-helper`. The first attempt was cancelled after 15 minutes with no runner assigned ("capacity constraints" for macOS arm64 runners); the re-run succeeded.

| Check | Result |
| --- | --- |
| Runner | macOS 15.8.2 (24H232), Apple Swift 6.1.2, target arm64-apple-macosx15.0 |
| `swift build` | Succeeded, including the macOS-only IOKit, `m1ddc`, lock and file code, first time compiled; no warnings |
| `swift test` | 46 tests, 0 failures |
| Release arm64 build and ad hoc signature | `codesign --verify`: valid on disk, satisfies its Designated Requirement |
| Binary SHA-256 | `6417d714f38636322d84e47982304fbbfd63e4615996e69230ed994eae0e4203` |
| Archive SHA-256 | `43643a95be69f32dc05b4b2985364436cb390ee80452a31599ff8b3b27a320b7` (`monitor-switch-mac.tar.gz`) |
| Artifact | `monitor-switch-mac-d087c9faeb3a3b4dcdebf778b5ea480a9e8585f2`, kept until 2 December 2026 |

Compiling is not running: nothing has executed on a Mac yet. Pending: plan §8 steps 1 to 10, starting with the read-only `followers` and `displays` commands.

## First run on the Mac (plan §8 steps 1–2, read-only) — 18 November 2026

The owner installed the `mac-helper-test-d087c9f` pre-release (anonymous download; release created because the owner does not sign in to GitHub on the work Mac). Results were reported verbally because output cannot be copied off the Mac.

| Check | Result |
| --- | --- |
| macOS | 26.7.3 |
| Gatekeeper | Blocked the first launch ("Apple could not verify … is free of malware"); the owner allowed this binary with Open Anyway in System Settings |
| `--version` | 0.1.0 |
| `m1ddc help` | Lists `display list` and `set` commands for `input n`, `input-alt n` and `pbp-input n`; no version shown |
| `displays` | Exit normally; two displays: "Unknown Display" as 1 and "LU28R55" as 2, each with a UUID-like identifier |
| `followers` | `accessStatus` `inputMonitoring=unknown`; `devices` empty |

Interpretation: the binary runs and `m1ddc` is reachable. No follower was found, so device discovery is unproven. Two candidate causes, not yet distinguished: devices copied from the HID manager before its matching ran (hidapi schedules the manager and runs the run loop first), or the HID++ collection presented differently on macOS. Version 0.1.1 settles the manager first and reports every visible Logitech HID device with a plain-text summary.

## Second Mac run, 0.1.1 (step 2, read-only) — 18 November 2026

Pre-release `mac-helper-test-ebea075` (archive SHA-256 `69eaf1bf…88327e0a`). The owner pasted the `followers` output.

| Check | Result |
| --- | --- |
| HID devices visible | 18; one Logitech device |
| K860 (B359) | Bluetooth Low Energy; primary usage 0001:0006; usage pairs 0001:0006, 0001:0002, 0001:0001, 000C:0001, FF43:0202; max input/output report 20/20, feature 1 |
| Identity | `SerialNumber` is exposed, so enrollment can use a hashed per-device identity (hash kept out of Git) |
| Open | `IOHIDDeviceOpen` refused with `0xe00002e2` (`kIOReturnNotPermitted`) |
| Input Monitoring | `IOHIDCheckAccess` reported unknown; no prompt appeared |
| LIFT (B031) | Not visible in this run |

Discovery is fixed by settling the HID manager before copying devices. The HID++ collection is present on macOS in the device's usage pairs, with the same report sizes as on Windows. Opening it needs Input Monitoring, which the owner grants in System Settings. Pending: re-run with the grant and with the LIFT on the Mac.

## Step 2 passed: read-only HID++ from the Mac — 18 November 2026

The owner granted Input Monitoring to Terminal in System Settings, restarted Terminal, put both devices on the Mac and ran 0.1.1 `followers` (output pasted by the owner; host names and hashes kept out of Git).

| Check | Result |
| --- | --- |
| Input Monitoring | `inputMonitoring=granted` (granted to Terminal, the responsible process when run from a shell) |
| Elevation | None; no `sudo` |
| Devices | K860 (B359) and LIFT (B031), both Bluetooth Low Energy, HID++ collection FF43:0202 in usage pairs, 20/20-byte reports; one IOHIDDevice each |
| Identity | Both expose `SerialNumber`; enrollment uses its SHA-256 |
| Resolved features | K860 change host 8 (version 1), hosts info 9; LIFT change host 10 (version 1), hosts info 11 — same as Windows |
| State and slots | Three paired, named slots on each. Current channel is the Mac's (K860 1, LIFT 3); the PC is channel 2 on both, consistent with the Windows enrollment |
| Errors | 0 timeouts, 0 I/O failures |

IOKit report handling works for every read-only request (output report with the report ID byte included; input reports accepted). Opening without seizing coexists with Options+. Still unproven: change host from the Mac (gate M2), the removal callback as `Left` evidence, and permissions when Options+ launches the helper.

## Steps 3–4: enrollment and dry-run on the Mac — 18 November 2026

Owner-pasted output, 0.1.1.

| Check | Result |
| --- | --- |
| `m1ddc help` | A display is chosen by number or `(method=)<id>`, defaulting to the system UUID; `set input n` exists. Confirms `display <UUID> set input 5` |
| `displays` | This time only the LU28R55, listed as display 1 (it was display 2 in the first run), confirming numbers are not identity |
| `enroll --display <UUID> --keyboard-channel 2 --mouse-channel 2` | Both enrolled: channel 2, the PC's host name, identity hashed from `SerialNumber` |
| `--dry-run` | `DryRun`, exit 0, 763 ms; both devices Ready / WouldSend; monitor not attempted |

No monitor command and no channel change were sent. Next: gate M2, keyboard only.

## Gate M2: Mac sends each device to the PC — 18 November 2026

Supervised, owner present, 0.1.1, one device per run. Recovery was each device's own Easy-Switch control.

| Run | Mac result | PC-side evidence |
| --- | --- | --- |
| `follow --device keyboard` | Followed, exit 0: one change-host sent, Accepted, Left; no rejection, 0 timeouts, 0 I/O failures (reported by the owner) | Owner typed in the PC session: "I being able to type here is a good sign". Read-only Windows `followers`: K860 current channel 2 |
| `follow --device mouse` | Owner: "All worked"; pasted result Followed, commandSent true, Accepted, Left, 0 timeouts, 0 I/O failures | Read-only Windows `followers`: LIFT current channel 2 |

Between runs the owner moved the mouse to the PC and back by its own button (it was not moved by the keyboard run), then returned both devices to the Mac.

M2 passes: a one-shot, non-elevated process on macOS, with Input Monitoring granted to Terminal, moved each device to the PC with exactly one change-host command, and the IOKit removal callback produced `Left`. Not yet shown: both devices in one run, the monitor command from the helper (M1), permissions when launched by Options+ (M3), and repeated reliability.

## Step 7: full Mac action from Terminal — 18 November 2026

Supervised, 0.1.1, `monitor-switch-mac` with no arguments, after a PC button press had moved everything to the Mac.

Installed Windows helper log for the session (UTC):

| Time | PC press | Result |
| --- | --- | --- |
| 17:50:30 | toggle | Confirmed 5→6, both followers Left |
| 17:51:58 | toggle | Confirmed 6→5, no follower sent (monitor on the Mac while the mouse was on the PC) |
| 17:53:34 | toggle | Confirmed 5→6, both followers Left |

The last Mac run moved the monitor, keyboard and mouse to the PC. Owner: "all worked perfectly!!!" and "The last test I ran switched the mouse, keyboard and the monitor". Afterwards, read-only checks from the PC: monitor input 5, K860 and LIFT both on channel 2, no problems.

Step 7 passes for that run. The 17:51:58 monitor-only press is not yet explained: it implies that before it the monitor showed the Mac while the mouse was on the PC, which an earlier Mac run with an unchanged image would cause. The Mac's own log for these runs has not been read yet. Gate M1 (ten monitor switches from the helper) remains open.

## Gate M3: Options+ for Mac launches the probe — 18 November 2026

Pre-release `mac-helper-test-4ed2491` (0.1.2, archive SHA-256 `5dc82aa6…7e2a78f1`), installed under `~/Applications/MonitorSwitch`. The owner bound the LIFT round button in Options+ for Mac to `MonitorSwitch Probe.app`, which runs only `probe-trigger` and touches no device.

| Check | Result |
| --- | --- |
| Launch type | Background-only app bundle (`LSUIElement`), no arguments; the bundle's fixed `MonitorSwitchCommand` selects the probe |
| Ten separate presses and one ~3 s hold | Probe log grew by exactly the expected eleven lines. Owner: "All worked, the number of lines were exactly what expected" |

M3 passes: one launch per press, none repeated while held. Still to record: the Options+ action type used and the button's previous assignment (for rollback). Next: Input Monitoring for `MonitorSwitch.app`, then bind it and run the first button-launched return.

## First button-launched round trips — 18 November 2026

The owner granted Input Monitoring to `MonitorSwitch.app` in System Settings and bound the LIFT round button in Options+ for Mac to it. Owner: "Everything is working perfectly!!! I press a mouse button and switch everything from mac to PC then press again and pc -> mac!!!!!!"

Installed Windows helper log after 17:54 UTC:

| UTC | PC press | Result |
| --- | --- | --- |
| 18:01:39 | toggle | Confirmed 5→6, both followers Accepted / Left, 2468 ms |
| 18:14:20 | toggle | Confirmed 6→5, no follower sent, 1078 ms |
| 18:15:49 | toggle | Confirmed 5→6, both followers Accepted / Left, 3109 ms |
| 18:18:47 | toggle | Confirmed 5→6, both followers Accepted / Left, 2672 ms |

Afterwards, read-only checks from the PC: monitor input 5, K860 and LIFT on channel 2, no problems, so the last Mac press returned the monitor and both devices.

The 18:14:20 press, like the one at 17:51:58, ran while the monitor showed the Mac and the mouse was on the PC. Its cause (a Mac press whose monitor command did not change the image, or devices moved by hand during setup) is not established; the Mac log has not been read. R1 (ten full round trips with counted results on both sides), S1 and lifecycle cases remain open.

## Owner-reported completion — 18 November 2026

The owner reported: "All tests passed." No Mac-side output was provided for these runs; the counts and the sleep, reboot and Options+ restart cases are therefore the owner's report, not measured here.

Measured on the PC (installed helper log, after 18:19 UTC): three more button presses PC→Mac at 18:21–18:23 UTC, each Confirmed 5→6 with both followers Accepted / Left, 2187–3391 ms. Counting from the binding of `MonitorSwitch.app`, the PC log shows five button-launched PC→Mac handoffs, all successful. Nothing pending and no helper process left running. The PC log alone cannot show ten round trips or the Mac's own results, and the two monitor-only PC presses at 17:51:58 and 18:14:20 remain unexplained.
