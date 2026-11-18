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

Pending: CI macOS build, then plan §8 steps 1 to 10 on the Mac.
