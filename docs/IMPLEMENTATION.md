# Implementation milestones

Checked items exist in this repository; unchecked items remain work, not implicit acceptance.

## Foundation

- [x] Write the complete revised v1.1 design before scaffolding.
- [x] Initialize standalone Git repository on branch `main`.
- [x] Create .NET 10 projects, references, WinExe boundaries and deterministic build settings.
- [x] Add strict command parsing, fixed device profile and pure operation contracts.
- [x] Add hardware-free command/profile tests and fake-session fixture.
- [x] Add harmless probe entry points independent of monitor/config/state access.
- [x] Add sample config, build/publish scripts, CI and setup/rollback/acceptance documentation.

## Read-only implementation

- [x] Strict config deserialization/validation, including unknown/duplicate fields and bounds (`Core/Config.cs`).
- [x] Structured command reports, output-path protection and last-result coordination (`Runtime/Reporting.cs`).
- [x] DisplayConfig/GDI/EDID mapping, exact unique native locator and handle ownership (`Windows/`).
- [x] Read-only discover/status/diagnose and explicit enrollment/re-enrollment (`Core/MaintenanceCommands.cs`).
- [x] Complete EDID validation and documented SHA-256 serialization (`Core/Edid.cs`: all blocks, checksums, lowercase hex).
- [x] Probe rotation, seven-day retention, and concurrency/failure tests.

## Switching implementation

- [x] Nonblocking operation lock covering all sessions sharing the state directory (file lock; design §7).
- [x] Atomic authoritative state store and interruption tests.
- [x] Boot-aware cooldown (Windows `BootId` + `GetTickCount64`), pending reconciliation, injected clock/delay and result reporting.
- [x] Pure orchestrator/fake-backend suite covering every v1.1 failure branch.
- [x] Reviewed native interop with runtime layout checks, backend input guards and single-owner disposal.
- [x] Exactly one native write, bounded readback and same-identity re-enumeration.
- [x] Optional non-focus-stealing error feedback (`MessageBeep`) and bounded local diagnostic logs.
- [ ] Retain matching release symbols separately and verify final packaging/signing status; development publish currently omits symbols and is unsigned.

## Windows and physical acceptance

- [x] Revalidate actual host architecture and monitor identity (Windows 11 Pro x64, RTX 3060, one SAM1017).
- [x] Read-only published-binary diagnostics on enrolled monitor.
- [ ] Revalidate Options+/Deskflow versions, mouse pairing and cable/GPU path.
- [x] Supervised native switch with owner-confirmed images and physical recovery (input 5 = PC, 6 = laptop).
- [x] Fresh-process inactive-source rediscovery and restore gate.
- [x] Show selected button and prior assignment; preserve rollback evidence (round button by the wheel; prior: Task View).
- [x] Probe matrix across image states and long-hold behavior (owner does not use Deskflow).
- [x] Real helper lifecycle tests while verifying/blocked; no foreground action or queue.
- [x] Ten round trips, busy/debounce presses and manual-OSD follow-up (sleep/resume, reconnect and laptop-asleep checks still open).
- [ ] Approved per-user installation and exact rollback demonstration.

Native code is exercised only in supervised Windows sessions; automated tests use fakes. A blocked native DDC call cannot be cancelled: the process keeps the lock until it returns or is terminated, and the next launch reconciles.

## Windows v1.2 followers

- [x] Optional schema-1 `follow` config, strict validation, preservation during monitor re-enrollment, backup on follower enrollment/removal.
- [x] `followers`, `enroll-follower`, `follow`, `toggle --no-follow`, and read-only follower dry-run planning.
- [x] Pure fixed-surface HID++ packets/session, reply/error matching, host-name pagination, 500 ms query budgets and one query retry.
- [x] Shared Windows HID handles, collection/report-length checks, exact product and path-hash identity, asynchronous I/O with cancellation.
- [x] All-device preflight, keyboard-first/mouse-last sends, one attempt per device, bounded departure observations, disposal on failures.
- [x] Follow after durable monitor confirmation while holding the same operation lock; follower results only in derived reports.
- [x] Hardware-free protocol/config/command/orchestration tests; see acceptance for measured build/test results.
- [x] Supervised read-only inventory, follower enrollment and dry-run (16 November 2026; original package/config backed up, target identities verified, both follower preflights Ready, zero monitor/channel changes, config/state hashes unchanged).
- [x] Supervised P1 keyboard channel-change gate: second attempt observed Left, owner confirmed typing on the Mac; physical Easy-Switch recovery confirmed separately. First failed attempt remains in acceptance.
- [x] Supervised P2 mouse channel-change gate: Left / Followed, exit 0, 344 ms; owner confirmed the pointer/physical-return check worked.
- [x] One supervised combined Windows-to-Mac handoff: monitor readback 6, both followers Left, exit 0, 3095 ms; owner confirmed image, typing and pointer all worked.
- [ ] Windows installation, full button round trips with the Mac helper, sleep/reconnect tests.

The path hash is SHA-256 of the UTF-8 Windows device-interface path after `ToUpperInvariant()`, in lowercase hex. Product IDs are canonical uppercase hex. Names use 1–64 ASCII letters, digits, hyphens or underscores; names and device identities must be unique. The native locator accepts only Logitech 046D, usage page FF43 / usage 0202, and 20-byte input/output report collections. Ambiguity always refuses.

`HidppSession` resolves feature indexes per session and refuses identical change-host/hosts-info indexes. This guards against a late duplicate root reply turning a read of host information (function 1) into a channel change (also function 1, on a different feature). Host and offset echoes are also matched for paged replies.

`commandSent` records that the single send was attempted; `sendResult` distinguishes API acceptance from uncertainty. Neither means arrival. Departure polling sends only state queries and distinguishes explicit native disconnection (`Left`) from silence/errors (`Unknown`). Each device gets at most two seconds of observation scheduling. Windows cancellation depends on driver cooperation: the operation lock remains held until outstanding I/O completes; the helper never detaches a live writer. Timing and driver behavior remain native acceptance items.

After the first keyboard test failed, departure observation gained a 250 ms passive receive interval within its existing two-second budget. Matching error replies to the change-host command are retained both there and while reading subsequent state-query replies; they change `sendResult` to `Rejected` and cannot count as success. Derived diagnostics retain numeric native/HID++ errors, feature indexes/version, the last read channel and query counters, without raw reports, paths or host names. This improves failure evidence; it is not proof that the switching failure is fixed.

Interop references checked during implementation: [Microsoft HID report writes](https://learn.microsoft.com/en-us/windows-hardware/drivers/hid/sending-hid-reports), [HIDP_CAPS layouts and report lengths](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/hidpi/ns-hidpi-_hidp_caps), [I/O cancellation limits](https://learn.microsoft.com/en-us/windows/win32/fileio/canceling-pending-i-o-operations), and [host-info reply layouts](https://openlogi.org/hidpp/features/x1815-hosts-info). These references do not establish hardware acceptance.
