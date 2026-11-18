# Windows setup and calibration

**Current state: the Windows v1.2 development build passed both individual follower gates and one owner-confirmed combined handoff. v1.2 was installed to `%LOCALAPPDATA%\MonitorSwitch\bin` on 18 November 2026 with both followers active, and two button-launched PC→Mac handoffs passed. The return is manual (Easy-Switch, then one press on the PC) until the Mac helper exists. Full round-trip/lifecycle acceptance remains pending; the v1.1 package and monitor-only config are kept in a separate local backup. On a new setup, do not bind a mouse button to the main executable until the supervised switch, fresh-process gate and probe matrix pass.**

All examples run from the repository root in PowerShell 7+. MonitorSwitch is a WinExe, so collect exit codes with `Start-Process -Wait -PassThru`.

```powershell
$exe = (Resolve-Path .\artifacts\win-x64\app\MonitorSwitch.exe).Path
function Invoke-MonitorSwitch { (Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru).ExitCode }
```

## 1. Build and package

```powershell
[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture   # X64 on this PC
.\scripts\Publish.ps1 -Runtime win-x64
```

Copy the whole folder when testing; an apphost alone is not the package.

## 2. Read-only discovery and explicit enrollment

```powershell
Invoke-MonitorSwitch discover --json --output "$env:TEMP\ms-discover.json"
Get-Content "$env:TEMP\ms-discover.json"
```

Check there is exactly one `SAM1017` candidate with `problem: null`. Enroll by copying its exact `deviceInterfacePath` and `edidIdentityHash` (quote the path; it contains `&`):

```powershell
Invoke-MonitorSwitch enroll --device-path '"<deviceInterfacePath>"' --edid-hash <edidIdentityHash>
Get-Content "$env:LOCALAPPDATA\MonitorSwitch\last-result.json"
```

Re-enrollment needs `--replace`, refuses while a pending operation exists, and backs up the old config to `config.previous.json`. Never copy `config.example.json` as enrollment.

Confirm read-only behavior before any write:

```powershell
Invoke-MonitorSwitch status --output "$env:TEMP\ms-status.json"
Invoke-MonitorSwitch toggle --dry-run      # plans only; see last-result.json
```

## 3. Supervised physical switch (owner present)

Recovery path: the monitor's own input button/OSD. Note the current image and input first. Labels are cosmetic; record which physical source (PC or laptop) each value shows.

```powershell
Invoke-MonitorSwitch set --input 6   # expect laptop image; exit 0 = target read back
Get-Content "$env:LOCALAPPDATA\MonitorSwitch\last-result.json"
Invoke-MonitorSwitch set --input 5   # expect PC image
```

Record exit code, `before/target/observed`, `write.apiAccepted`, elapsed time, and what the owner actually sees. API acceptance is not visual success.

## 4. Fresh-process inactive-source gate

With input 6 (laptop) selected by step 3 and that process exited, every handle has been released. A new launch must rediscover the monitor and restore the PC:

```powershell
Get-Process MonitorSwitch -ErrorAction SilentlyContinue   # must be empty
Invoke-MonitorSwitch set --input 6
Get-Process MonitorSwitch -ErrorAction SilentlyContinue   # must be empty
Invoke-MonitorSwitch toggle                               # new process: expect PC image, exit 0
```

If discovery fails while the laptop input is shown (exit 11), the PC's display path disappeared: record it and follow design §10. Do not add a resident handle keeper.

## 5. Harmless probe and button selection

```powershell
$probeExe = (Resolve-Path .\artifacts\win-x64\probe\MonitorSwitch.TriggerProbe.exe).Path
(Start-Process -FilePath $probeExe -Wait -PassThru).ExitCode
Get-Content "$env:LOCALAPPDATA\MonitorSwitch\logs\trigger-probe-$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')).jsonl" -Tail 10
```

Exit 0 means an entry was flushed, 20 means local logging failed, 10 means arguments were passed. Logs rotate at 1 MB and are kept seven days.

1. Recheck mouse pairing, Options+/Deskflow versions and roles, and app-specific profiles.
2. Show the actual LIFT button diagram and existing assignment. Propose Forward; confirm the owner's choice before changing it. Save a screenshot/plain-text record and any supported export outside Git.
3. Through supported Options+ UI, assign the probe executable's absolute path in All Applications (Open Application/Open File, else Smart Action → Application Open). Do not silently create/sign into an account or modify private databases.
4. Run ten separated presses in every design §8 state, desktop/browser/editor checks, rapid presses and a long hold. Count log lines; verify no duplicates, repeats while held, Back/Forward forwarding or focus change.

## 6. Bind the real switch

Only after the probe gate passes, replace the probe with the absolute path of `MonitorSwitch.exe` (no arguments). Repeat lifecycle checks while it verifies or is busy, then ten complete round trips. Record native and visual results separately in [acceptance](ACCEPTANCE.md).

Install only the tested complete package to the approved stable per-user directory (`%LOCALAPPDATA%\MonitorSwitch\bin`). Update only with no operation active, keeping one prior package/config.

## Recovery

The physical monitor input button always works. Never perform blind automatic rollback. If a native call hangs, the process keeps the lock; terminating it leaves a pending record that the next launch reconciles read-only (exit 16 or 15) without switching. Press again after a reconciliation to switch.

## Screenshots to capture during actual setup

- LIFT button diagram and previous assignment.
- Selected supported Options+ action and absolute executable path.
- Relevant All Applications/app-specific override settings.
- Supported backup/export and restore controls, if present.

## Windows v1.2 keyboard and mouse followers

These are future supervised setup steps, not evidence that this build has controlled either device. Leave Logitech Flow off and Deskflow unchanged. Recovery is the K860's Easy-Switch keys, the LIFT's underside Easy-Switch button, and the monitor's own input button. Before every physical test, explain which device will leave and have the owner ready to recover it.

1. Build/test from the root. Select the newly built executable explicitly; do not accidentally test an older package in `artifacts` or the installed v1.1 copy. Keep a separate backup of the installed package and original config before any enrollment changes.
2. In a supervised read-only session, run `followers --output PATH` with both devices physically connected to the PC. Check product IDs B359 (keyboard) and B031 (mouse), current channels, paired slots, host names, and support while Options+ remains running. An exit-0 inventory can contain individual device problems; inspect the report. Reports contain private host names/path hashes and belong outside Git and outside the app's protected data directory.
3. The owner identifies the Mac slot separately for each device from that report. Do not copy illustrative channel numbers. Enroll each selected channel with the commands below, using the real values in place of `N`. Enrollment only queries devices, captures the path hash and target host name, and backs up config. It refuses ambiguous identities or an unresolved monitor operation.
4. Run `toggle --dry-run` while the monitor shows input 5. It should plan input 6 and show both followers as `WouldSend`, with zero channel changes. `toggle --no-follow --dry-run` plans only the monitor.
5. Gate P1: supervised `follow --device keyboard`; the owner confirms typing on the Mac, then returns it with Easy-Switch. Gate P2: supervised `follow --device mouse`; confirm pointer movement on the Mac and recover it with the underside button. Record actual arrival separately from `Left`, `StillHere` or `Unknown` in the result. Each run sends at most one change-host command to the selected device. Never automatically repeat a failed or uncertain run.
6. After P1/P2 and Mac M2/M3 pass, arrange the approved installation/button setup and run the full round-trip, asleep-host, reconnect and lifecycle matrix. A Windows-only one-press return is not possible after the mouse leaves the PC; the Mac half or physical Easy-Switch recovery is required.

Command forms (use the `Invoke-MonitorSwitch` wrapper above with `$exe` pointing to the build being tested):

```text
followers --output PATH
enroll-follower --name keyboard --product-id B359 --channel N
enroll-follower --name mouse --product-id B031 --channel N
toggle --dry-run
follow --device keyboard
follow --device mouse
```

**Shared-config compatibility:** development and installed binaries use the same per-user config. The old v1.1 binary rejects the new `follow` field. Do not use its button action while testing enrolled followers. Before returning to v1.1, remove all followers using the new helper (after resolving any pending monitor operation), or perform the approved update to v1.2. Removing the last follower omits `follow` entirely. `config.previous.json` holds only one previous generation, so it is not a substitute for the separate original backup.

`enroll-follower --name NAME --replace --product-id PID --channel N` explicitly replaces an enrollment; `enroll-follower --name NAME --remove` removes it. Names use 1–64 ASCII letters, digits, hyphens or underscores. Config schema remains 1, and new enrollment defaults to away input 6 on Windows. Host names are checked exactly against fresh device replies; re-pairing requires explicit re-enrollment.

Exit 17 means following was incomplete or dry-run preflight refused. On an actual toggle the monitor has already been durably confirmed before preflight begins, so it may show the Mac even when no follower was sent. A later PC-side toggle brings the monitor home and leaves the devices on the PC. `set --input 5|6` always changes only video. Standalone `follow` also preserves pending monitor state and refuses to run until it is resolved; it never edits `state.json` or retries a previous follower operation.
