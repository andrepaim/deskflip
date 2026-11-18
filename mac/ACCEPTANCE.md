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
