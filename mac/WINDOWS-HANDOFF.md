# Windows findings for the Mac helper

16 November 2026. Read this alongside `../docs/MAC-HELPER-PLAN.md`, design v1.2 and `../AGENTS.md` before implementing the Swift helper. These are Windows findings, not macOS acceptance. No Swift package or Mac helper has been built in this checkout.

## Current evidence

The Windows v1.2 source is implemented and its latest root restore/build/test passed with zero warnings/errors and **232 hardware-free tests passing**. Read-only discovery, follower enrollment and dry-run have been exercised on the actual devices with Options+ running. Full evidence, including the failed first attempt, is in `../docs/ACCEPTANCE.md`.

| Supervised Windows test | Result |
| --- | --- |
| Keyboard-only, first attempt | Transport accepted the one send, but observation was Unknown / exit 17. Owner: "No, still here on PC." |
| Physical keyboard controls | Owner confirmed Easy-Switch works both ways, establishing pairing and physical recovery |
| Keyboard-only, after observation changes | Left / exit 0; owner confirmed typing on the Mac. Helper elapsed time: 734 ms |
| Mouse-only | Left / exit 0; owner confirmed pointer/return check. Helper elapsed time: 344 ms |
| Combined monitor, keyboard, mouse | Monitor readback changed from 5 to 6, both devices Left, exit 0. Owner: "All worked" for image, typing and pointer. Helper elapsed time: 3095 ms |

These timings cover each helper operation, not measured destination connection latency. Only one successful combined handoff has been tested; this is not ten round trips or a reliability guarantee. No software switch was automatically retried or rolled back.

Update, 18 November 2026: v1.2 is installed on Windows with both followers active, and the bound button has completed two PC→Mac handoffs (monitor confirmed, both devices Left, owner-confirmed). The PC side is ready for round trips. Until the Mac helper exists, the return is Easy-Switch on both devices plus one press on the PC. The v1.1 package and original config remain in a local backup outside Git.

## Carry these details into the Swift implementation

1. **Use the fixed protocol, with runtime feature resolution.** Both devices expose change-host 0x1814 version 1 and hosts-info 0x1815. The tested surface uses collection FF43/0202, 20-byte reports, report ID 0x11, direct-device index 0xFF, and software ID 0xB. Resolve feature indexes every session, even though Windows observations were stable. Confirm IOKit report-ID/buffer conventions through read-only queries first; Windows interop is not portable proof.
2. **Protect root-query reply handling.** Reject equal change-host and hosts-info feature indexes. A stale duplicate root reply could otherwise make hosts-info function 1 target change-host function 1, accidentally changing a channel during preflight. Match report ID, device index, feature index and full function/software-ID byte; for host records and name pages, also match the echoed host and offset. Ignore unrelated notifications.
3. **Listen for change-host errors, not a success acknowledgement.** Successful switching has no normal acknowledgement. A rejection can still arrive as an error frame matching the change-host request. Keep recognizing that frame while waiting for later state-query replies; do not discard it as unrelated. Transport acceptance does not mean the device accepted or executed the command.
4. **Include a short passive observation interval.** The successful Windows build begins departure observation with up to 250 ms of receiving only, before issuing a state query. That interval is part of the existing two-second observation budget per device, not extra time. The first failed keyboard run polled immediately. Later success followed this and the diagnostic changes, but no controlled comparison established causation. Preserve this as an evidence-informed starting point to validate on the Mac, not a proven universal timing requirement.
5. **Keep uncertain outcomes explicit.** Windows reports Left only on an explicit native disconnect; silence alone remains Unknown. Define the corresponding IOKit removal/disconnection evidence. Left is evidence at the source, not proof of typing/pointer arrival at the destination. A device rejection must prevent success, even if a later disconnect is observed. Retain one-send guards even when writes time out or throw.
6. **Keep useful, private-safe diagnostics.** Record resolved feature indexes/version, state-reply counts, timeout/I/O-failure counts, numeric native/query errors and any matching change-host error. Separate NotSent, transport Accepted, Unverified and device Rejected. Do not log raw reports, device paths or host names. No follower diagnostics become recovery authority.
7. **Bound queries and await cancellation cleanup.** The actual devices sometimes needed the permitted single retry of a 500 ms read-only query. This must never become a retry of change-host. Keep the operation lock and native buffers alive until pending I/O is quiescent; a timeout alone does not authorize another live writer. Exercise cancellation and cleanup with fakes before supervised native testing.
8. **Preflight all devices, then send keyboard before mouse.** Exact identity, paired destination and enrolled host-name equality are required for each follower. AlreadyThere skips its send. The Mac still preflights before the monitor command; do not copy the Windows ordering of monitor confirmation before follower preflight. Mac monitor failure sends no device commands.

## Reference code and regression tests

Use these as behavior references, not a new shared runtime dependency:

- `../src/MonitorSwitch.Core/Hidpp.cs`: packet factories, matching, feature/host queries, one-send session guard and bounded observation.
- `../src/MonitorSwitch.Core/Followers.cs`: all-device preflight, ordering, outcomes and diagnostic metadata.
- `../src/MonitorSwitch.Core/FollowerCommands.cs`: enrollment and explicit single-device tests.
- `../tests/MonitorSwitch.Tests/HidppTests.cs`: packet/error/notification fixtures, ambiguous-index refusal, host-name pagination, immediate/late rejection handling, passive-window timing and timeout bounds.
- `../tests/MonitorSwitch.Tests/FollowerTests.cs`: zero sends on any preflight failure, order, uncertain writes, AlreadyThere and report/state separation.
- `../tests/MonitorSwitch.Tests/FollowerConfigAndCommandsTests.cs`: strict optional config, invalid fields, backup preservation and read-only commands.

In particular, port the regressions for a delayed change-host error interleaved with a state reply, a foreign software-ID error that must be ignored, a late duplicate root reply yielding equal indexes, and a write that throws after it might have taken effect. All tests remain hardware-free.

## Rediscover machine-specific configuration on the Mac

Product IDs are K860 B359 and LIFT B031 (vendor 046D). Target slots must still be enrolled per device. The devices' Mac channels differ; never infer one from the other. Host names, channel assignments, Windows path hashes, Bluetooth addresses and local reports are deliberately absent from this handoff.

Read the current PC destination names/slots with the Mac `followers` command and have the owner confirm them. Capture an appropriate Mac identity; never reuse a Windows device-path hash as IOKit identity. Display selection likewise comes from fresh `m1ddc display list` output, with explicit unique targeting. VCP remains 0x60 with fixed device values 5/6; the Mac helper writes only 5.

## Next Mac gates

Follow the existing plan in order: record macOS/Swift/m1ddc versions, establish non-elevated read-only IOKit access, record any owner-granted privacy permission, validate the pure core, enroll, and dry-run. Then supervise keyboard-only and mouse-only sends to the PC with physical recovery, test the explicitly selected monitor, and test the combined Mac action. Finally establish Options+ probe behavior and stable-path permissions before binding the real helper.

Windows success does not prove Mac HID permissions, IOKit report handling, native cancellation, monitor readback or Options+ launching. Those remain M1/M2/M3 work. Ten full button round trips and asleep-host/reboot/reconnect behavior remain open across both halves. Keep Mac implementation and its new evidence under `mac/`; do not modify the Windows installed helper from the Mac session.
