# Mac helper: build plan

Plan · 16 November 2026 · For the session that builds the Mac half, on the Mac

This plan is written for someone who has not seen the earlier work.

**Update, 18 November 2026.** The Mac is a work machine and holds no source code. The helper is written on the Windows PC, where Swift for Windows builds the package and runs the hardware-free tests; the IOKit, `m1ddc`, lock and file code compiles only on macOS. CI (`mac-helper` job, macOS runner) builds, tests and ad hoc signs the binary and publishes it as a workflow artifact. On the Mac, the owner only downloads that binary, installs it at a stable path and runs it; evidence comes back to the PC session, which records it in `mac/ACCEPTANCE.md`. Where this plan says "on the Mac" for building or committing, read "on the PC". The first implementation is written; see `mac/README.md` for the Mac-side steps. Hardware gates are still all pending. The Windows half now has supervised device and combined-handoff evidence; read the [Windows handoff](../mac/WINDOWS-HANDOFF.md) for the current findings and limitations.

## 1. Read first

1. `AGENTS.md`: the project rules. They apply on the Mac too.
2. `docs/DESIGN-v1.2.md`: the approved design for this feature. All of it.
3. `docs/DESIGN-v1.1.md`: the original design. Skim §3 (constraints) and §7 (one write, no retry, no rollback) for the principles the Mac helper must share.
4. `mac/WINDOWS-HANDOFF.md`: successful Windows tests, the first failed keyboard attempt, protocol/observation regressions to port, and what remains unproven on macOS.

## 2. What you are building

A small one-shot Swift command-line tool, launched by the LIFT mouse's round button through Logi Options+ for Mac. When pressed, it brings everything to the PC:

1. Switch the Samsung monitor to input 5 (the PC).
2. Send the ERGO K860 keyboard and the LIFT mouse to their PC Easy-Switch channels.
3. Write a result file and exit.

The PC already has the other half (`MonitorSwitch.exe`), which sends everything to the Mac. The two halves share no code and no network connection; they only share the protocol in §6.

It needs no toggle logic. The button can only reach the Mac while the mouse is on the Mac, so the intent is always "go to the PC".

## 3. What is known and what is not

Known:

| Item | Fact | Source |
| --- | --- | --- |
| Mac | MacBook Pro M5, monitor on the built-in HDMI port, Options+ installed | Owner |
| Monitor | Samsung LU28R55; input select is VCP 0x60; value 5 shows the PC, 6 shows the Mac | Measured on the PC, 12 November 2026 |
| Mac DDC | `m1ddc set input 5` switched the monitor to the PC | Owner report, 16 November 2026 |
| `m1ddc` limits | Built-in HDMI support is reported to need version 1.3.1 or later, and no "get input" is documented | Earlier research, not re-checked; record the installed version in step 1 |
| Logitech Flow | Off on both computers, and must stay off | Owner, 13 November 2026 |
| Devices | LIFT is Logitech 046D:B031, ERGO K860 is 046D:B359, both Bluetooth LE direct, no receiver | Measured on the PC |
| HID++ | Both devices answer the requests in §6 and report "change host" (0x1814) and "hosts info" (0x1815) | Measured on the PC with read-only requests |
| Windows channel changes | Both individual device gates and one combined monitor/keyboard/mouse handoff passed with owner-confirmed arrival; the first keyboard attempt failed | Supervised tests on 16 November 2026; see the Windows handoff and acceptance ledger |

Not known. Each of these is a step in §8, and each may change the plan:

- Whether a one-shot process on macOS can open these devices' HID++ collection, and what permission it needs. Third-party tools disagree: one needs only Input Monitoring, another needed root.
- How Options+ for Mac launches a tool from a button, and whether it launches exactly once per press.
- Whether the Mac can read the monitor's current input back.
- Whether the actual channel-change command works from the Mac. Windows-to-Mac sends have now passed; Mac-to-PC is still untested.

The channel numbers and host names are machine configuration. They are deliberately not in Git. You discover them on the Mac in step 2.

## 4. Rules that are not negotiable

- **Fixed monitor write.** The helper writes VCP 0x60 with the value 5 and nothing else. At most one monitor write per run.
- **Fixed HID++ surface.** Only the requests in §6. No generic or raw-bytes option.
- **One send per device per run.** Never retried, never rolled back.
- **Monitor first.** If the monitor command fails, no device is sent.
- **Preflight all, then send all.** Every device must pass every check in §7 before any device is sent.
- **One-shot only.** No LaunchAgent, LaunchDaemon, login item, menu-bar app or other resident process. No network listener.
- **No `sudo`.** If step 2 shows root is unavoidable, stop and report; that needs a revised design.
- **Permissions are the owner's.** If macOS asks for Input Monitoring or anything else, the owner grants it in System Settings. Never script or edit privacy settings.
- **Options+ through its own UI only.** No edits to its private files.
- **Supervised hardware steps.** Every step that sends a channel change or switches the monitor is run with the owner present. Automated tests never touch hardware.
- **Nothing private in Git.** No host names, Bluetooth addresses, serials, display UUIDs, config, logs or screenshots.
- **Stay in your lane.** Mac helper code stays under `mac/`. The only change outside it is the `mac-helper` job in `.github/workflows/build.yml`. The PC half lives under `src/` and `tests/`.

## 5. Shape of the tool

Swift package under `mac/`, built and tested with `swift build` and `swift test` from `mac/`: on the Windows PC for the core library, and in CI on macOS for everything (see the update at the top).

| Target | Contents |
| --- | --- |
| `MonitorSwitchMacCore` (library) | Pure logic: packet encoding and reply matching, config parsing and validation, the run sequence against protocols. No IOKit, no process launching |
| `monitor-switch-mac` (executable) | IOKit HID transport, the `m1ddc` runner, file lock, result and log writing, argument parsing |
| `MonitorSwitchMacCoreTests` | Hardware-free tests with fakes |

Commands:

| Invocation | Contract |
| --- | --- |
| No arguments | The button action in §7 |
| `--dry-run` | Preflight and plan only; sends nothing, switches nothing |
| `followers` | Read-only: devices found, feature support, current channel, paired slots and host names. Prints to the terminal |
| `displays` | Read-only: what `m1ddc display list` reports |
| `enroll --display ID --keyboard-channel N --mouse-channel N` | Checks everything read-only, captures the host names for those channels, writes the config. `--replace` to overwrite |
| `follow [--device keyboard\|mouse]` | Supervised use: sends devices only, leaves the monitor alone |
| `probe-trigger` | Appends one JSON line (timestamp, process ID, version). Touches no device. For the button test |

Per-user files, all under `~/Library/Application Support/MonitorSwitch/`: `config.json`, `last-result.json`, `operation.lock`, `logs/`.

macOS ties a privacy grant such as Input Monitoring to the binary's identity. Install the helper at one stable path and sign it, at least ad hoc (`codesign -s -`), so the grant survives. Expect to re-approve after a rebuild, and record it when that happens. If Options+ can only launch applications, wrap the binary in a minimal application bundle; step 8 decides this.

Device identity follows design §5: vendor and product ID, the HID++ collection, and a hash of whatever stable per-device identifier IOKit exposes, captured at enrollment. The product name is not identity. If IOKit exposes no stable identifier, enroll on vendor and product ID alone, require exactly one present, and report it.

Monitor control goes through `m1ddc`, run by absolute path (expected `/opt/homebrew/bin/m1ddc`), with arguments passed as an array, never through a shell. The Mac has two displays, so the config stores the Samsung's identifier from `m1ddc display list` and every command names it explicitly. Never rely on "first" or on list order. Confirm the exact `m1ddc` syntax with its own help before coding against it.

Exit codes, mirroring the PC where the meaning matches:

| Exit | Meaning |
| --- | --- |
| 0 | Monitor command accepted and both devices left or were already on the PC channel |
| 2 | Busy or within the cooldown |
| 10 | Invalid configuration or command |
| 11 | Enrolled display missing or ambiguous |
| 17 | FollowIncomplete: monitor command accepted, but the devices did not all move |
| 19 | Monitor command failed; nothing was sent to the devices |
| 20 | Internal error |

## 6. HID++ protocol reference

Every request below, including the channel change, has now been exercised against both devices from Windows on 16 November 2026. This does not validate IOKit transport or Mac-to-PC switching. The Windows handoff records the first failed attempt and the later successful tests.

Transport:

- Vendor collection: usage page 0xFF43, usage 0x0202.
- Long reports only: 20 bytes, first byte is the report ID 0x11.
- Byte 1 is the device index: 0xFF for a directly connected device.
- Byte 2 is the feature index. Byte 3 is `(function << 4) | softwareId`. Parameters start at byte 4.
- Use one fixed non-zero software ID. The table below uses 0xB.
- A reply repeats bytes 0 to 3 of the request. Ignore anything else; the device also sends unrelated notifications.
- An error reply is `11 FF FF <feature index> <function|softwareId> <error code>`.
- Feature indexes differ per device and per firmware. Resolve them on every run; never store them.

| Purpose | Request | Reply |
| --- | --- | --- |
| Find a feature's index | `11 FF 00 0B <id high> <id low>` | Byte 4 is the index; 0 means not supported. Byte 6 is the version |
| Change host 0x1814: read state | `11 FF <index> 0B` | Byte 4 is the slot count, byte 5 the current host, zero-based |
| Change host 0x1814: **switch** | `11 FF <index> 1B <host>` (zero-based, so channel minus one) | None. The device disconnects |
| Hosts info 0x1815: summary | `11 FF <index> 0B` | Byte 4 bit 0 set means names are readable. Byte 6 is the slot count |
| Hosts info 0x1815: one slot | `11 FF <index> 1B <host>` | Byte 5 non-zero means paired. Byte 8 is the name length |
| Hosts info 0x1815: name | `11 FF <index> 3B <host> <offset>` | Name bytes start at byte 6, up to 14 per reply; repeat with a higher offset |

On Windows the write is 20 bytes including the report ID. On macOS, check how IOKit expects the report ID to be passed and prove it with a read-only request before anything else.

Bound every read with a timeout (500 ms; queries may be retried once). The channel change is never retried.

Also carry over the Windows safeguards: reject equal resolved change-host/hosts-info indexes, validate host/offset echoes, retain change-host rejection frames even while awaiting a different query, and keep silence distinct from explicit disconnection. The successful Windows build starts departure observation with a 250 ms passive receive interval inside the two-second budget. Its effect on the earlier failure is unproven; validate it on the Mac rather than assuming timing alone fixes switching.

## 7. The button action

1. Take the lock without waiting. If it is held, exit 2.
2. If the last run finished less than 3 seconds ago, exit 2.
3. Load and validate the config. Check the enrolled display is present, exactly once.
4. Preflight both devices. For each: exactly one matching device present; it reports the change-host feature; the PC channel is paired; the host name it reports for that channel equals the enrolled name. A device already on the PC channel is skipped.
5. If any preflight fails, stop: switch nothing, send nothing, exit 17.
6. Run the monitor command once. If it fails, exit 19 and send nothing.
7. Send the keyboard, then the mouse, one command each.
8. For up to 2 seconds, watch for each device to stop answering. Record `Left`, `StillHere` or `Unknown`.
9. Write `last-result.json` and a log line. Exit 0 if every device is `Left` or was skipped, otherwise 17.

Preflight comes before the monitor command here, unlike on the PC, because the Mac may not be able to confirm the monitor change by reading it back.

If the monitor did not really change, the devices still reach the PC, and one press of the button there brings the monitor home. That is by design.

## 8. Steps, in order

Do not skip ahead. Each step that fails is a finding to report, not something to work around.

| Step | What | Done when |
| --- | --- | --- |
| 1 | Record the macOS version and the installed `m1ddc` version and help text on the Mac; the toolchain versions come from the PC and the CI log. `swift build` and `swift test` pass on the PC and in CI | Recorded in `mac/ACCEPTANCE.md` |
| 2 | **First risk.** With the keyboard and mouse switched to the Mac by their own Easy-Switch controls, implement read-only discovery and the `followers` command | It prints both devices' current channel and paired slots, without `sudo`. Every permission prompt is recorded |
| 3 | Packet layer, config and run sequence in the core library, with hardware-free tests | Tests in §9 pass |
| 4 | `displays` and `enroll`. The owner picks the Samsung and the PC channels from the read-only output | Config written; `--dry-run` reports a correct plan |
| 5 | **Gate M2, supervised.** `follow --device keyboard`: the keyboard should start typing on the PC. Bring it back with its Easy-Switch key. Then the same for the mouse | Both arrive on the PC, both observed `Left` |
| 6 | **Gate M1, supervised.** The monitor command from the helper, ten times | Ten switches to the PC, owner-confirmed |
| 7 | The full button action from the terminal | Monitor and both devices arrive at the PC |
| 8 | **Gate M3.** Bind `probe-trigger` to the round button in Options+ for Mac. Record which action type works and whether it needs an application bundle. Ten presses, one long hold | Ten log lines for ten presses, one for the hold |
| 9 | Bind the real helper. Check it still has its permissions when Options+ launches it | Works from the button |
| 10 | With the PC half ready: ten full round trips; a press on the PC while the Mac is asleep; a press on the Mac while the PC is asleep or has Bluetooth off; after a reboot and after restarting Options+ | Gates R1 and S1 in the design, and each extra case recorded |

Before any supervised step, tell the owner what is about to happen and how to recover: the K860's Easy-Switch keys, the button under the LIFT, and the monitor's own input button.

## 9. Tests

Hardware-free, with fakes for the HID transport and the monitor runner:

- Packet encoding for every request in §6; reply matching; error replies; unrelated notifications ignored; timeouts.
- Each preflight failure, on either device, results in no monitor command and no send.
- Monitor command failure results in no send.
- At most one monitor command and one send per device, under every failure.
- A device already on the PC channel is skipped without a send.
- Lock held and cooldown both exit 2 without touching anything.
- Config: every invalid field is rejected; placeholders are rejected; enrollment keeps a backup.
- `--dry-run` and `followers` never send a channel change.

## 10. Evidence and hand-back

Record measured results in `mac/ACCEPTANCE.md`: date, macOS and toolchain versions, each gate's outcome, timings, and the owner's own words for what they saw. No private data.

Report these back, because the PC half and the design depend on them:

- The permissions the helper needed, and whether they survive being launched by Options+.
- How Options+ for Mac launches the helper.
- Whether the monitor's input can be read back from the Mac.
- How long a device takes to arrive after the command.
- Anything in the design that turned out to be wrong.

Code and evidence are committed from the PC, on this feature branch. Nothing is committed or built on the Mac.
