# Mac helper (`deskflip-mac`)

One-shot tool for the Mac half of [design v1.2](../docs/DESIGN-v1.2.md). On a button press it brings the monitor, the K860 and the LIFT to the PC. Build plan and rules: [MAC-HELPER-PLAN](../docs/MAC-HELPER-PLAN.md). Windows findings it is based on: [WINDOWS-HANDOFF](WINDOWS-HANDOFF.md).

**Status, 18 November 2026: version 0.1.2 is installed on the Mac and bound to the LIFT round button. That install predates the rename to deskflip (`~/Applications/MonitorSwitch/MonitorSwitch.app`); see [migration](#migrating-from-before-the-rename). Read-only access, M2 and M3 passed with measured evidence; the owner reports the remaining tests passed. See [ACCEPTANCE](ACCEPTANCE.md).**

## Where things happen

| Where | What |
| --- | --- |
| Windows PC | All source code. `swift build` / `swift test` from `mac/` build the package and run the hardware-free tests (the IOKit, `m1ddc`, lock and file code is macOS-only and is skipped) |
| CI, `mac-helper` job | Builds and tests everything on macOS, builds a release arm64 binary, signs it ad hoc and uploads `deskflip-mac-<commit>` |
| Mac (work machine) | Only the built binary. No source, no toolchain, no commits |

Windows build environment: Swift for Windows (`winget install Swift.Toolchain`) needs the Visual Studio C++ tools and Windows SDK on `PATH`, so run it from a VS developer shell (`Launch-VsDevShell.ps1 -Arch amd64`) with `SDKROOT` set. On Windows the executable only prints "runs only on macOS" and exits 21.

## On the Mac

1. Download the artifact for the commit to test and check its SHA-256 against `SHA256SUMS.txt` and the CI log.
2. Install at one stable path, because macOS ties privacy permissions to the binary:
   ```sh
   mkdir -p ~/Applications/Deskflip
   tar -xzf deskflip-mac.tar.gz -C ~/Applications/Deskflip
   ~/Applications/Deskflip/deskflip-mac --version
   ```
   A file downloaded through a browser is quarantined, and macOS may refuse to run it. What to do about that is the owner's decision; the helper never changes security settings.
3. Each new build has a new ad hoc signature, so expect to approve Input Monitoring again after updating. Only the owner grants it, in System Settings.

Files live in `~/Library/Application Support/Deskflip/`: `config.json`, `config.previous.json`, `last-result.json`, `operation.lock`, `logs/`.

## Migrating from before the rename

Builds before the rename were `monitor-switch-mac`, `MonitorSwitch.app` and `~/Library/Application Support/MonitorSwitch`. A new build has a new app name and bundle identifier, so macOS treats it as a new app. These one-time steps are all done by the owner; nothing is switched and no device is sent:

1. Download `deskflip-mac.tar.gz`, check its SHA-256 and extract it into `~/Applications/Deskflip`.
2. Create `~/Library/Application Support/Deskflip/` and copy `config.json` into it from `~/Library/Application Support/MonitorSwitch/`. The format did not change.
3. In System Settings → Privacy & Security → Input Monitoring, add and enable `~/Applications/Deskflip/Deskflip.app`. If Gatekeeper blocks it, use Open Anyway.
4. Run `~/Applications/Deskflip/deskflip-mac --dry-run`. It must exit 0 with both devices `Ready` / `WouldSend`.
5. In Options+ for Mac, point the round button at `Deskflip.app` and test one press each way.
6. Afterwards, remove `MonitorSwitch.app` from the Input Monitoring list and delete `~/Applications/MonitorSwitch` and the old Application Support folder.

## Commands

| Invocation | Effect |
| --- | --- |
| *(none)* | Button action: lock, 3 s cooldown, config and display check, preflight both devices, one `m1ddc … set input 5`, then keyboard and mouse to their PC channels |
| `--dry-run` | Same checks; switches and sends nothing |
| `followers` | Read-only: devices, IOKit facts, current channel, paired slots, host names, Input Monitoring status. Prints JSON |
| `displays [--m1ddc PATH]` | Read-only: `m1ddc display list` output |
| `enroll --display ID --keyboard-channel N --mouse-channel N [--m1ddc PATH] [--replace]` | Read-only checks, captures the PC host names, writes the config |
| `follow [--device keyboard\|mouse]` | Supervised use: sends devices only, never touches the monitor |
| `probe-trigger` | Appends one JSON line to `logs/trigger-probe-<date>.jsonl`. Touches no device |
| `--version` | Prints the version |

For Options+, which launches applications without arguments, the archive also has two background-only app bundles around the same binary (built by `scripts/make-bundles.sh`): `Deskflip.app` runs the button action, and `Deskflip Probe.app` runs only `probe-trigger`, named by the fixed `DeskflipCommand` key in its Info.plist. When an app is launched this way, macOS asks for Input Monitoring for that app rather than for Terminal.

Exit codes: 0 success, 2 busy or cooldown, 10 invalid configuration or command, 11 display missing or ambiguous, 17 preflight refused or devices did not all leave, 19 monitor command failed (nothing sent), 20 internal error, 21 not macOS.

## Assumptions to confirm on the Mac

These come from documentation and other tools, not measurement. Each is checked by the gate named.

- `m1ddc` syntax is `display list` and `display <ID> set input 5`, with the ID as a whole token in the list output. Check `m1ddc help` before enrolling (step 4).
- IOKit takes the output report with its report ID byte included, and input reports may arrive with or without it; both are accepted (step 2, `followers`).
- The HID++ collection appears as the primary usage or in `DeviceUsagePairs` of one IOHIDDevice per physical device (step 2; `followers` shows `collectionMatch` and duplicates are refused).
- A stable identifier is exposed as `SerialNumber` or `PhysicalDeviceUniqueID`; otherwise enrollment is by product ID with exactly one present (`identitySource` in `followers`).
- Opening the device without seizing it, with Input Monitoring granted, is enough; no root (step 2).
- The IOKit removal callback fires when a device switches host, which is what `Left` means here (gate M2).
