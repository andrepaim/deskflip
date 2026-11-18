# Acceptance evidence

## Scope and provenance

The 11 November 2026 hardware findings in [design §2](DESIGN-v1.1.md#2-prior-environment-evidence-and-revalidation) were supplied in the proposal. The scaffold checks below ran on a Linux development host; every later section ran on the target Windows PC.

## Scaffold checks — 12 November 2026

Actual local build/test evidence is recorded below after verification. These checks establish scaffold consistency only; they do not satisfy hardware acceptance.

| Check | Evidence |
| --- | --- |
| Design written first | `docs/DESIGN-v1.1.md` created before Git initialization and scaffold files |
| Git | Standalone repository, branch `main`; initially created without a remote |
| SDK | Temporary Linux SDK 10.0.404 under `/tmp/monitor-switch-dotnet-sdk` |
| Restore | `dotnet restore MonitorSwitch.slnx` succeeded for all six projects |
| Release build | `dotnet build MonitorSwitch.slnx -c Release --no-restore` passed; 0 warnings, 0 errors |
| Tests | `dotnet test MonitorSwitch.slnx -c Release --no-build` passed: 29 passed, 0 failed, 0 skipped |
| Windows packaging | Main app and probe cross-published with `-r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false` into separate ignored artifact folders |
| Executable format | Both apphosts inspected as PE32+ GUI executables, Windows x86-64 |
| PowerShell scripts / hosted CI | Provided; PowerShell scripts have not been executed here because PowerShell is unavailable on this host. Hosted CI results must be checked separately. |

Development package hashes (not installed or run on Windows):

| File | SHA-256 |
| --- | --- |
| `artifacts/win-x64/app/MonitorSwitch.exe` | `a66ce8ca6ecace56d67679081eac3dac1349837933877f45352d0f3db79e6e3b` |
| `artifacts/win-x64/probe/MonitorSwitch.TriggerProbe.exe` | `84a52e738ca5d2842717ac4d9a5c459bd604c86f02f5c38f2ffb296a4f3bf65f` |

SHA-256 manifests for every file in each folder are stored alongside the ignored packages. These are folder deployments; an apphost alone is not the complete package. The main package is intentionally nonfunctional for monitor commands. Native discovery, command report writing, full probe retention, and Windows runtime behavior remain pending.

## Implementation and read-only hardware checks — 12 November 2026

Run on the target Windows PC by the implementing agent. No monitor writes, button assignments or Deskflow changes were made.

| Check | Evidence |
| --- | --- |
| Host | Windows 11 Pro 10.0.26300, x64; NVIDIA GeForce RTX 3060; .NET SDK 10.0.404 |
| Build/tests | `scripts\Build.ps1`: 0 warnings, 0 errors; 129 passed, 0 failed |
| Package | `artifacts\win-x64\app\MonitorSwitch.exe` SHA-256 `390f862419cb3c103e4fef9b0e8852f0bea440d0a92a3d90c41d89a613beedd9` (development, unsigned) |
| Probe package | `artifacts\win-x64\probe\MonitorSwitch.TriggerProbe.exe` SHA-256 `11f51f1b2d27ffa90ad6ef645c099e6f0c40c4d1dc3f0bf8a680efc9a77c472b` |
| `discover` | Exit 0. One active target: SAM / SAM1017 "LU28R55" on `\\.\DISPLAY1`; EDID valid; 1 physical monitor; 1 target on source; VCP 0x60 read 5 |
| `enroll` | Exit 0. Enrolled the discovered path and EDID hash `e950ed17…a1c42` (full values in local config only) |
| `status` | Exit 0. Current input 5 ("Input 5"); no state, no pending |
| `diagnose` | Exit 0 in ~2.0 s. Capabilities (advisory) include `60(01 03)`, `mccs_ver(2.0)`, matching the prior report |
| `toggle --dry-run` | Exit 0 in ~0.44 s launch-to-exit (109 ms internal). Planned 5 → 6; no write; no `state.json` created |

## Supervised native switch and fresh-process gate — 12 November 2026

Same host and package hash as above. Owner present and watching the monitor; physical input button available for recovery.

| Step | Native evidence | Owner-confirmed image |
| --- | --- | --- |
| `set --input 6` (process A) | Exit 0, Confirmed: read 5, one `SetVCPFeature` accepted, readback 6; 1062 ms internal, 1.3 s wall | Laptop image |
| Process A exited | Zero MonitorSwitch processes alive; all physical handles released | Laptop image held ~10 s |
| `set --input 5` (new process B, laptop input selected) | Exit 0, Confirmed: fresh discovery found the enrolled identity, read 6, one write accepted, readback 5; 1094 ms internal, 1.2 s wall | PC image restored, no manual intervention |
| Final state | `state.json` pending null, last outcome Confirmed | — |

Calibration: on this cable/GPU configuration, **input 5 = PC** and **input 6 = laptop**. The PC's display path stayed active while the laptop input was shown, so fresh-process rediscovery works. Owner's words: "It worked perfectly."

## Full application acceptance

| Item | Status | Evidence needed |
| --- | --- | --- |
| Configuration/state/orchestrator/native backend | Implemented; fake-backend suite passes | Hardware evidence below |
| Actual Windows architecture/devices | Revalidated (above). Logi Options+ 1.93.755983, Logi Plugin Service 6.1.5.22697, Deskflow 1.27.0.0, all running | Mouse pairing and cable/GPU route still to record |
| Read-only published diagnostics | Passed (above) | — |
| Supervised native PC→laptop→PC | **Passed** 12 Nov 2026 | See section above |
| Fresh-process inactive-source gate | **Passed** 12 Nov 2026 | See section above |
| Prior LIFT assignment and selected button | Owner chose the small round button next to the scroll wheel (not Forward), assigned in All Applications. Prior assignment: Windows Task View ("Exibição de tarefas"); restore this on rollback | Any app-specific overrides |
| Probe matrix | Binding works (12 Nov 2026): owner bound the probe through Options+ UI; 3 launches logged at 15:43:35–15:43:38 UTC, separate PIDs, none left running. Press count not recorded, so exactly-once is not yet shown. **Batch A passed** (monitor PC, Deskflow focus PC): 10 counted presses → 10 log lines, 10 distinct PIDs, gaps 1.49–1.82 s, no Task View, no window or focus change, nothing left running. **Batch C passed** (monitor showing laptop via physical button): 10 presses → 10 log lines, 10 distinct PIDs, gaps 1.32–1.49 s, nothing left running | **Passed** for the owner's setup. Owner does not use Deskflow (installed and running, left unchanged); the MacBook uses its own touchpad, so Deskflow focus states B and D do not apply |
| Long hold and rapid presses | **Passed** 12 Nov 2026: ~3 s hold → exactly 1 launch, no repeat; 5 fast clicks → 5 launches 0.27–0.36 s apart, distinct PIDs, no Task View, no delayed queue, nothing left running | — |
| Real helper verification/busy lifecycle | **Passed** 12 Nov 2026: 2 presses during a running switch → `Busy` (exit 2, 0 ms), 1 press 0.5 s after completion → `Debounced` (exit 2); each in-flight switch still Confirmed, nothing queued. After a manual OSD change to the laptop, the next press read 6 and selected 5 (follows actual input) | No foreground activation, launch queue or broken later presses |
| Desktop/browser/editor profiles | Not run | Actual override behavior |
| Ten complete round trips | **Passed** 12 Nov 2026: 1 round trip from the repo build, then 15:53–15:57 UTC from the button (installed copy): 18 Confirmed toggles, all readbacks match target, typically 1078–1109 ms (one 2141 ms with an extra verification read), no pending left, no process left running. Owner: "All worked great!" | Readbacks/images, no orphan or unrelated-target writes |
| Physical OSD / reconnect / sleep/resume | Not run | Actual-state handling, identity safety and recovery |
| Laptop asleep / app missing / Options+ stopped | Not run | Clear limits and safe recovery |
| Installation and rollback | Installed 12 Nov 2026 to `%LOCALAPPDATA%\MonitorSwitch\bin`: 194/194 files match the tested manifest, app exe `390f8624…edd9`; installed `status` exit 0, read 5. Rebind to installed path and rollback demonstration pending | Package path/hash, restored assignment, unchanged Deskflow |

Use operation IDs and binary hashes to connect future evidence. Do not commit full device paths, EDID/serial dumps, unrelated window data or private screenshots. Native acceptance and a user's visual confirmation are separate evidence.

## Windows v1.2 implementation — 16 November 2026

Scope: Windows source, deterministic tests and documentation on `feature/keyboard-mouse-follow`. No native device commands were executed in this implementation session. The installed v1.1 package, machine config, button assignment and Mac files were not changed.

| Check | Measured result |
| --- | --- |
| Restore from repository root | `dotnet restore MonitorSwitch.slnx` succeeded; all projects up to date |
| Release build from root | `dotnet build MonitorSwitch.slnx -c Release --no-restore`: 0 warnings, 0 errors |
| Hardware-free tests from root | `dotnet test MonitorSwitch.slnx -c Release --no-build`: 226 passed, 0 failed, 0 skipped |
| Covered behavior | Fixed HID++ packets, feature resolution and ambiguous-index refusal, unrelated/error replies, timeout/retry budgets, host-name pagination, strict optional config, enrollment backup/removal, exact targeting with fakes, all-device preflight, keyboard/mouse ordering, one attempted change per device, uncertainty reporting, dry-run/no-follow, durable monitor completion before follow, unchanged recovery state |
| Native Windows HID backend | Implemented and compiled; fresh shared handles, fixed collection/report lengths and product/path-hash matching. Not exercised against hardware in this session |
| Read-only validation alongside Options+ | Inventory, enrollment and dry-run passed in the subsequent supervised sessions below |
| P1: K860 PC→Mac | Passed on the second supervised attempt: Left / Followed, exit 0, 734 ms; owner confirmed typing reached the Mac ("Yes, now it worked!!"). Owner also confirmed physical Easy-Switch works both ways during diagnosis. First failed attempt remains recorded below |
| P2: LIFT PC→Mac | Passed: supervised single attempt returned Left / Followed, exit 0, 344 ms; owner confirmed "worked as well" in response to the pointer/physical-return check |
| Combined Windows monitor + followers | Passed once: Confirmed, input 5→6, both followers Left, exit 0, 3095 ms; owner confirmed Mac image, typing and pointer: "All worked" |
| Native timing/cancellation | Pending: 500 ms query cancellation behavior, two-second departure observations, driver errors on Bluetooth disconnection, process/handle cleanup |
| Installation / round trips / asleep host | Pending: approved Windows update, Mac M2/M3 gates, R1 ten full button round trips and S1 asleep-host recovery |

`Left` is local disconnection evidence, not proof of arrival. Timeouts and uncertain native errors produce `Unknown`; an accepted write alone is not successful physical acceptance. The 13/16 November read-only probe findings remain prior design evidence and are not validation of this new native backend.

## Windows v1.2 supervised read-only inventory — 16 November 2026

The owner requested validation step 1. Ran `followers --output PATH` from the Release build at 14:15:40 UTC. The process exited normally with code 0 (`FollowersDiscovered`). Its report was saved outside the repository in the user's temporary directory.

| Check | Measured result |
| --- | --- |
| Device inventory | One K860 (B359) and one LIFT (B031), with distinct path hashes; neither reported a problem |
| Tested Core DLL SHA-256 | `baf4247c9ca25fb507e52d87c47a39bce1c64fe344e9318c3c947216731cb648` |
| Tested Windows DLL SHA-256 | `103d01fd34bc5e8bb63cca08b3b8cc250d42088f4b38e1a9659a18d11c932b9a` |
| Fixed HID++ queries | Both returned current channel, three host slots, paired state and readable host names for every slot |
| Pairing interpretation | Both current slots name the PC; the same previously identified Mac host appears on a different target channel for each device. Exact channels, host names and identity hashes remain local |
| Existing enrollment | Neither device is enrolled as a follower yet |
| Options+ coexistence | Options+ agent, app broker and updater processes were running when checked immediately after inventory |
| Side effects | No monitor switch, channel-change command, enrollment, installation or button-assignment change performed |

This validates the new backend's discovery, shared-handle access and read-only replies on these devices. It does not validate change-host sends, departure detection, arrival on the Mac, timeout cancellation or full button operation. Remaining: preserve original config/package, enroll the owner-selected target slots, dry-run, supervised P1/P2, and installation/full acceptance with the Mac half.

## Windows v1.2 backup and follower enrollment — 16 November 2026

The owner authorized backing up the original installation/config and enrolling the two identified Mac target slots. Before backup, no helper was running, no follower section existed, and monitor state had no pending operation. Took the shared operation lock while copying the original config and full installed package to a separate per-user backup directory outside the repository. Verified all 194 package files and the config against their source SHA-256 hashes; the manifest and backup location remain local.

The new Release build returned `FollowerEnrolled`, exit 0, for the keyboard at 14:17:59 UTC and the mouse at 14:18:06 UTC. No replacement override was needed. Verified both saved product IDs, device path hashes, target channels and host names against the earlier inventory. Exact machine configuration remains outside Git.

Post-enrollment verification: original monitor settings unchanged, `state.json` hash unchanged, and all installed package file hashes unchanged. Enrollment only queried the devices; no channel-change command or monitor switch was issued. No button assignment or Mac file was changed.

The installed v1.1 binary remains in place and will reject the new optional `follow` section. Its button action must not be used as a v1.2 test. Next: dry-run with the new executable, then supervised single-device P1/P2, followed by the approved update and full acceptance. The separate original backup remains available; the normal `config.previous.json` now contains the intermediate keyboard-only enrollment.

## Windows v1.2 supervised dry-run — 16 November 2026

At the owner's request, ran `toggle --dry-run` with the new Release executable at 14:19:26 UTC. It exited 0 with outcome `DryRun`, read monitor input 5, and planned input 6. Both keyboard and mouse passed preflight (`Ready`) and were reported as `WouldSend`, with `commandSent: false` and `sendResult: NotSent`. The monitor write field was null. Internal elapsed time was 1094 ms.

Config and monitor-state SHA-256 hashes were identical before and after the command. A copy of the derived result remains in the local temporary directory, outside Git. No actual switch or channel change occurred. Next acceptance gates are supervised keyboard-only P1 and mouse-only P2, including owner-confirmed arrival and Easy-Switch recovery.

## Windows v1.2 supervised keyboard-only attempt — 16 November 2026

The owner authorized the keyboard-only physical test after being told the destination and physical Easy-Switch recovery. Ran `follow --device keyboard` once with the new Release executable. At 14:20:07 UTC the helper reported `FollowIncomplete`, exit 17, with keyboard preflight `Ready`, `commandSent: true`, `sendResult: Accepted`, and departure observation `Unknown`. Internal elapsed time was 3078 ms. No retry or automatic rollback was performed.

The command did not access the monitor or send a mouse channel change. Config and monitor-state SHA-256 hashes remained unchanged. The complete result is retained locally outside Git. API acceptance does not establish arrival: owner-confirmed typing on the Mac and physical recovery are still pending. P1 remains open, and the uncertain departure observation needs investigation before full acceptance.

## Keyboard failure diagnosis — 16 November 2026

The owner's result was: "No, still here on PC." A subsequent read-only inventory found both enrolled devices still reporting the PC channel, with no device problems. The owner then confirmed "Physical switch works both ways" when asked to test the keyboard's physical Easy-Switch controls to the Mac and back. This establishes physical pairing/recovery, but the software channel-change gate did not pass. No second software channel change or mouse test was run.

Code inspection found an observability defect: a rejection of the change-host command was ignored by the subsequent state-query reply matcher, and native I/O error codes were discarded. This could conceal the reason for a failed switch; it does not establish what happened during the first attempt, whose replies cannot be recovered. The command's function and zero-based channel encoding agree with the [Solaar change-host implementation](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings_templates.py).

The development build now captures matching change-host error replies during a 250 ms passive observation window and subsequent state queries, preserves numeric native/query errors, records feature indexes/version and state/timeout counters, and reports `Rejected` separately from transport `Accepted`. The total observation scheduling budget remains two seconds per device; there is still one change-host attempt and no retry or rollback. Diagnostics contain no raw reports, device paths or host names and never enter authoritative state.

Root restore/build/test passed after the change: 0 warnings, 0 errors; **232 tests passed, 0 failed, 0 skipped**. New tests exercise immediate/late command rejections, unrelated replies, the passive interval/deadline, retained numeric native errors, and rejection overriding transport acceptance. A read-only inventory with this build passed for both devices: the change-host feature version was 1 on both; indexes matched the earlier design evidence. Each session recorded one query timeout recovered by the permitted query retry, with no native I/O or device query errors. Exact current channels and local reports remain outside Git.

Root cause of the failed software switch remains unproven. Next is a separately supervised single keyboard test with these diagnostics. P2 and full switching remain on hold; the installed package and enrolled config were not changed during diagnosis.

## Keyboard-only test with improved diagnostics — 16 November 2026

The owner explicitly authorized a new supervised keyboard-only attempt. At 14:35:32 UTC, `follow --device keyboard` returned `Followed`, exit 0, in 734 ms internally. Preflight was `Ready`; exactly one change-host command was attempted and accepted by the transport. This time the helper observed native disconnection (`Left`). No change-host rejection or query error was reported. There was one query timeout recovered during preflight by the permitted read-query retry; no switch command was retried.

Config and monitor-state SHA-256 hashes were unchanged. The command did not switch the monitor or send a mouse channel change. Full local evidence remains outside Git. The keyboard's arrival on the Mac and return via its physical Easy-Switch control still require the owner's confirmation for this attempt; `Left` alone does not complete P1. The added passive receive interval may be relevant to the different result, but this run does not establish the first failure's cause.

Owner follow-up to the typing check: "Yes, now it worked!!" This confirms arrival on the Mac for the second attempt. Together with the earlier explicit confirmation that physical Easy-Switch works both ways, P1 passes. It does not establish repeated reliability or the cause of the first failure. P2 (mouse), full button round trips and lifecycle checks remain open.

## Windows v1.2 supervised mouse-only attempt — 16 November 2026

The owner authorized one mouse-only physical test after being told the destination and underside Easy-Switch recovery. At 14:38:27 UTC, `follow --device mouse` returned `Followed`, exit 0, in 344 ms internally. Preflight was `Ready`, the single attempted change-host command was accepted by the transport, and native disconnection was observed (`Left`). Diagnostics recorded zero timeouts, zero native I/O failures, and no query or change-host rejection.

Config and monitor-state SHA-256 hashes remained unchanged. The command did not switch the monitor or send a keyboard channel change. No retry or automatic rollback was performed. Full evidence remains local outside Git. Owner-confirmed pointer movement on the Mac and physical return remain pending; API acceptance and `Left` alone do not complete P2.

Owner follow-up to the pointer/physical-return check: "worked as well". P2 passes. Both individual Windows follower gates now have owner-confirmed successful attempts. Combined monitor-plus-follow operation, installation, Mac helper gates, ten full button round trips and lifecycle/sleep behavior remain unvalidated; the first failed keyboard attempt remains part of the evidence.

## Windows v1.2 supervised combined toggle — 16 November 2026

The owner explicitly authorized one combined monitor/keyboard/mouse test after the two individual follower gates passed. At 14:39:44 UTC the new Release executable's `toggle` returned `Confirmed`, exit 0, in 3095 ms internally. It read input 5, attempted one accepted monitor write to input 6, and read back input 6. Both followers passed preflight, received one accepted change-host attempt each in keyboard-then-mouse order, and were observed as `Left`. No native I/O error or HID++ rejection was reported. Diagnostic timeout counts were two for the keyboard and one for the mouse; these include query/passive-read timeouts and are not retries of channel-change commands.

Verified that config was unchanged, authoritative state durably recorded the monitor confirmation with no pending operation, and follower results were absent from authoritative state. Full derived evidence remains local outside Git. No retry or automatic rollback was performed. Owner confirmation of the Mac image, typing and pointer movement is pending; API/readback/departure observations alone do not establish the combined physical outcome. This is one Windows-to-Mac operation, not a full button round trip or installation acceptance.

Owner follow-up to the combined image/typing/pointer check: "All worked". The single supervised Windows-to-Mac combined handoff passes. Remaining acceptance: approved Windows installation and button launch, Mac return-helper gates, ten full button round trips, and lifecycle/asleep-host cases. The earlier failed keyboard attempt remains recorded; one successful combined handoff is not a repeated-reliability claim.

## Installed v1.1 troubleshooting and config restoration — 16 November 2026

The owner reported that the existing installed monitor-only setup was not working and requested log inspection and guided testing. The installed executable still matched the original v1.1 SHA-256 `390f862419cb3c103e4fef9b0e8852f0bea440d0a92a3d90c41d89a613beedd9`. Options+ processes were running, no helper process was stuck, and monitor state had no pending operation.

Root cause reproduced with the installed helper's read-only `diagnose`: config was invalid because the schema-1 `follow` property could not be mapped to the old `AppConfig` type. Follower enrollment during v1.2 testing had changed the shared per-user config while the bound installed binary remained v1.1. Its config failure occurs before result reporting and feedback are initialized, explaining the silent failed button launches and unchanged last-result/log. Prior monitor toggles were Confirmed before enrollment. An isolated earlier UnexpectedInput read of 15 was followed by successful toggles; it is separate from the reproduced config failure and the fixed 5/6 profile was preserved.

Preserved both follower config generations in a separate verified local backup outside Git. Under the operation lock, checked there was no pending operation and that removing only `follow` made the active config equivalent to the original pre-feature config. Atomically restored that original config, with exact SHA-256 verification. Both enrolled followers remain recoverable in the separate backup. No installed executable, Options+ assignment, device channel or monitor input was changed by the repair; authoritative monitor state was preserved.

After restoration, the installed v1.1 `status` returned exit 0 with input 5, matching enrollment and no target/state errors. Its `toggle --dry-run` returned exit 0 and planned 5→6 with no monitor write (125 ms internally). State and executable hashes were unchanged. The owner has been asked to test the existing button once to the Mac and once back to the PC after waiting at least three seconds; physical confirmation is pending.

Owner-confirmed button recovery: "Both image changes worked." Logs corroborate two installed-helper toggles at 16:18:36 and 16:18:39 UTC: 5→6 and 6→5, each Confirmed with matching readback and exit 0, taking 1156 ms and 1140 ms internally. Final state has no pending operation, last observed input 5, and no helper process remains running. The original monitor-only button setup is restored and validated; no v1.2 installation or follower activation occurred.
