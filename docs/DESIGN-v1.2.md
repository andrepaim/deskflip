# Keyboard and mouse follow the monitor

Design addendum · 16 November 2026 · Version 1.2 · **Approved by the owner on 16 November 2026. Windows source implemented and installed (18 November 2026); individual follower gates and button-launched PC→Mac handoffs passed. Mac gates and full round-trip acceptance remain pending.**

This document extends [design v1.1](DESIGN-v1.1.md). Everything in v1.1 still applies unless a section here says otherwise. Read v1.1 first.

## 1. Goal and decision

One press of the LIFT round button moves the monitor, the ERGO K860 and the LIFT to the other computer, in both directions.

Today the button only switches the monitor; the owner changes keyboard and mouse separately with their Easy-Switch controls.

Decision: after a confirmed monitor switch, the helper tells each device to change its Easy-Switch channel using Logitech's HID++ "change host" feature (0x1814), the same command the physical Easy-Switch buttons trigger. The devices really move to the other computer, so input stays native on both machines and nothing depends on the network.

The consequence is that the design becomes two-sided. Once the mouse is on the Mac, the PC no longer receives the button, so the Mac needs its own small helper bound to the same button in Options+ for Mac.

Not chosen, and why:

| Alternative | Reason |
| --- | --- |
| Deskflow forwarding plus a Smart Action | Input over the network, degraded mouse and keyboard behavior on the Mac, and the owner does not use Deskflow |
| Logitech Flow | Edge-triggered, not button-triggered, and does not switch the monitor |
| A resident watcher that reacts to devices arriving or leaving | v1.1 rules out resident processes |
| Existing GitHub tools | None covers Windows plus macOS plus Bluetooth-direct devices plus a button trigger; all are small and untested on these devices |

## 2. Evidence so far (16 November 2026)

Measured on the Windows PC by a read-only HID++ probe (only "get" requests were sent):

| Item | Finding |
| --- | --- |
| Connection | LIFT (product B031) and ERGO K860 (product B359) are paired to the PC over Bluetooth LE directly; no Bolt or Unifying receiver |
| HID++ access | Vendor collection, usage page 0xFF43, usage 0x0202, 20-byte reports. Opened read/write in shared mode while Options+ was running |
| LIFT | Change host (0x1814) present at feature index 0x0A; hosts info (0x1815) at 0x0B; three host slots, all paired |
| ERGO K860 | Change host present at feature index 0x08; hosts info at 0x09; three host slots, all paired |
| Channels | Both devices are on the same channel for the PC. The Mac is on a different channel on each device, so targets are per device |
| Earlier run | The same read-only check, without host names, also passed on 13 November 2026 with the same feature indexes |

Reported by the owner:

| Item | Finding |
| --- | --- |
| Mac | MacBook Pro M5, connected to the monitor by its built-in HDMI port; Options+ installed; other software can be installed |
| Mac DDC | `m1ddc set input 5` on the Mac switched the monitor to the PC ("It worked on mac") |
| Logitech Flow | Off (13 November 2026). It must stay off; it moves the same devices and could fight the helper |

Subsequent Windows implementation evidence: both individual channel-change gates and one combined monitor/keyboard/mouse handoff passed with owner-confirmed arrival. The first keyboard attempt failed and remains recorded in [acceptance](ACCEPTANCE.md). See the [Windows handoff for Mac development](../mac/WINDOWS-HANDOFF.md) for protocol safeguards, diagnostic changes and unresolved limits.

Not yet measured, and therefore not assumed:

- Sending the actual change-host command (function 1) from the Mac to the PC.
- Whether a one-shot process on the Mac can open the HID++ collection, and which permissions it needs.
- Whether Options+ for Mac launches a helper exactly once per press.
- Whether the Mac can read the monitor's current input back over DDC.
- What happens when the Mac is asleep at the moment of the press.

Feature indexes are firmware-specific. They are evidence here, never configuration: the helper resolves them at run time.

## 3. Behavior

"Home input" is the input that shows the computer the helper runs on. "Away input" is the other one. On the PC, home is 5 and away is 6.

| Where the button is pressed | Monitor state | Result |
| --- | --- | --- |
| PC | Home (5) | Monitor to 6, then keyboard and mouse to the Mac |
| PC | Away (6), devices still on the PC | Monitor to 5, devices stay. This recovers from a stranded state |
| Mac | Any | Monitor to 5, then keyboard and mouse to the PC |

Rules:

- **Monitor first.** The devices move only after the monitor switch is Confirmed. Any other monitor outcome moves nothing.
- **Follow only on the button path.** `toggle` follows. `set --input` never moves devices, so supervised monitor tests and recovery keep the keyboard and mouse where they are. `toggle --no-follow` gives the v1.1 behavior.
- **Follow only toward the away computer.** A switch to the home input never sends a device anywhere.
- **Preflight all, then send all.** Every enrolled follower must pass every check in §5 before any device is sent. This avoids ending up with the mouse on one computer and the keyboard on the other.
- **One send per device.** Each follower receives at most one change-host command per operation. It is never retried and never rolled back.
- **No follow configured means v1.1 behavior**, unchanged.

Physical Easy-Switch buttons and the monitor's own input button keep working and are the recovery path. The helper does not try to follow changes made with them.

## 4. Sequence on the PC

Steps 1 to 10 of v1.1 §7 run unchanged, including the authoritative completion in `state.json`. Then, still holding the operation lock:

11. If the command is `toggle` without `--no-follow`, the outcome is Confirmed, the new input is the away input, and followers are enrolled: run the preflight for every follower.
12. If every preflight passes, send one change-host command to each follower: keyboard first, mouse last.
13. For each follower, watch for up to 2 seconds for it to stop answering on this computer. Record `Left`, `StillHere` or `Unknown`.
14. Emit the derived reports, including one result per follower, then release everything.

Follower results are never recovery authority. The device itself is the authority: its current channel can always be read back. Nothing about followers is written to `state.json`, and a crash during steps 11 to 13 leaves no pending operation.

`Left` means the device stopped answering here. It does not prove the device reached the Mac.

## 5. Follower identity and guards

A follower is matched by Logitech vendor ID (046D), its enrolled product ID, the HID++ vendor collection (usage page 0xFF43, usage 0x0202), and a SHA-256 hash of its device interface path captured at enrollment. The product string is empty over Bluetooth LE, so the name is not identity, and enumeration order never is. The hash keeps a second device of the same model from being mistaken for the enrolled one without putting a Bluetooth address in the config.

Preflight, per follower. Any failure means no device is sent:

1. Exactly one device matching the enrolled identity, including the path hash, is present. Zero or several refuses.
2. The device answers a root query and reports the change-host feature.
3. The device's current channel is read. If it is already on the away channel, that follower is skipped as `AlreadyThere`.
4. The away channel is reported as paired.
5. The host name the device reports for the away channel equals the name captured at enrollment. This catches a re-pairing that moved the Mac to another channel.

HID++ surface, fixed and exhaustive:

| Feature | Function | Use |
| --- | --- | --- |
| Root 0x0000 | 0 getFeature | Resolve feature indexes |
| Change host 0x1814 | 0 getHostInfo | Read slot count and current channel |
| Change host 0x1814 | 1 setCurrentHost | The one write, with the zero-based host index |
| Hosts info 0x1815 | 0, 1, 3 | Read paired state and host name |

No other feature, function or report is ever sent. There is no generic HID++ or raw-bytes option, in the same spirit as the fixed VCP 0x60 profile.

Transport: long reports only (ID 0x11, 20 bytes), device index 0xFF, a fixed non-zero software ID. Replies are matched on feature index and function. Every read has a bounded timeout (500 ms, one retry for queries). A successful change-host command gets no reply.

Handles are opened in shared mode so Options+ keeps working, and closed on every path.

## 6. Commands and configuration

| Invocation | Contract |
| --- | --- |
| No arguments / `toggle` | As v1.1, plus follow when enrolled |
| `toggle --no-follow` | Exactly the v1.1 toggle |
| `toggle --dry-run` | Also reports the follow plan from read-only preflight; sends nothing |
| `followers --output PATH` | Read-only: each enrolled or discoverable follower, feature support, current channel, paired slots and host names |
| `enroll-follower --name NAME --product-id PID --channel N [--replace]` | Requires exactly one present device and a paired channel N; captures the device path hash and the host name; writes config with a backup. Sends nothing to the device beyond queries |
| `enroll-follower --name NAME --remove` | Removes that follower |
| `follow [--device NAME]` | Supervised use: runs steps 11 to 13 only, without touching the monitor |

Config gains one optional section. `schemaVersion` stays 1, so the installed enrollment keeps working; a config without `follow` behaves exactly as v1.1.

```json
"follow": {
  "awayInput": 6,
  "devices": [
    { "name": "keyboard", "productId": "B359", "devicePathHash": "<captured during enrollment>", "awayChannel": 2, "awayHostName": "<captured during enrollment>" },
    { "name": "mouse", "productId": "B031", "devicePathHash": "<captured during enrollment>", "awayChannel": 3, "awayHostName": "<captured during enrollment>" }
  ]
}
```

The channel numbers above are illustrative. Validation: `awayInput` is 5 or 6; one to four devices; unique names; product ID is four hex digits; path hash is 64 lowercase hex characters; channel is 1 to 3; host name is non-empty and not a placeholder. Unknown fields are still rejected.

Host names appear only in the config and in explicitly requested reports, never in ordinary logs, and never in Git.

Results and exit codes:

| Exit | Outcome |
| --- | --- |
| 0 | Monitor Confirmed and every follower `Left` or `AlreadyThere`; or follow not applicable |
| 17 | FollowIncomplete: monitor Confirmed, but preflight refused, a device was unreachable, or a device was sent and is `StillHere` or `Unknown` |

All v1.1 exit codes keep their meaning. Exit 17 beeps like any other failure. The JSONL line and `last-result.json` gain a `followers` array: name, preflight result, whether a command was sent, and the observation.

## 7. The Mac helper

A separate one-shot tool, bound to the same LIFT button in Options+ for Mac through its supported UI. It has one job: bring everything to the PC.

1. Take a nonblocking lock; ignore a press within a short cooldown of the last run.
2. Run the same preflight as §5 for both devices. If it fails, stop and change nothing.
3. Switch the monitor to input 5 through `m1ddc`, invoked by absolute path. If that command fails, stop and move nothing.
4. Send each device to its PC channel.
5. Write a local result file and exit.

It needs no toggle logic: the button can only reach the Mac when the mouse is on the Mac.

The Mac cannot be assumed to read the monitor's input back, so step 3 is "command accepted", not Confirmed. If the monitor did not actually change, the devices still arrive at the PC, and one press there brings the monitor home (second row of the table in §3).

The owner chose a small native Swift tool in this repository under `mac/`, built on the Mac. It follows the same fixed HID++ surface and guards. The step-by-step build plan is in [the Mac helper plan](MAC-HELPER-PLAN.md). Third-party tools such as `mxswitch` or `hidapitester` may be used to investigate a failing gate, not as the installed solution.

On the Mac the preflight runs before the monitor command, because the monitor change may not be confirmable there.

Mac rules mirror the PC's: no resident process, no network listener, no elevation unless gate M2 proves it unavoidable (which would need a revised design), and Options+ changes only through its supported UI.

## 8. Feasibility gates

Each gate is supervised, with the owner present, and recorded in the acceptance ledger. Recovery for every gate is the device's own Easy-Switch control.

| Gate | Test | Pass |
| --- | --- | --- |
| P1 | PC sends the K860 to the Mac channel with `follow --device keyboard` | Typing reaches the Mac; the Easy-Switch key brings it back |
| P2 | Same for the LIFT | Pointer moves on the Mac; the underside button brings it back |
| M1 | Mac switches the monitor to input 5 | Passed by owner report, 16 November 2026; repeat ten times from the helper |
| M2 | A one-shot process on the Mac sends both devices to the PC | Both arrive; the permissions needed are recorded |
| M3 | Options+ for Mac launches a harmless probe from the button | Exactly one launch per press, none while held |
| R1 | Ten full round trips from the button | Correct image and working keyboard and mouse on each side, every time |
| S1 | Press on the PC while the Mac is asleep | Behavior recorded; documented recovery works |

If P1 or P2 fails, the feature is not feasible as designed and v1.1 behavior is kept. If M2 or M3 fails, the fallback is PC-to-Mac in one press and Mac-to-PC by Easy-Switch controls plus one press on the PC.

## 9. Failure cases

| Case | Behavior |
| --- | --- |
| Monitor switch not Confirmed | No follow; v1.1 outcome and exit code |
| A follower is missing, ambiguous, silent, unpaired on the away channel, or reports a different host name | No device is sent; exit 17 |
| One device leaves and the other does not | Exit 17; both observations are reported; nothing is retried |
| Mac asleep or off | The monitor may show no signal and the devices may sit on a channel with no host. Recover with the Easy-Switch controls and the monitor's input button. To be characterized in gate S1 |
| Press on the PC while a switch is running | Busy, as v1.1 |
| Deliberate press on the Mac soon after arriving | Handled by the Mac helper's own cooldown |
| HID++ read never returns | Bounded by the read timeout; the follower is reported as unreachable and nothing is sent to it |

## 10. Tests

Automated tests stay hardware-free and use fakes for the follower locator and session:

- Follow happens only after Confirmed, only on `toggle`, only toward the away input.
- No follow on `set`, `--no-follow`, dry-run, NotChanged, OutcomeUnverified, reconciliation, Busy or Debounced.
- Each preflight failure, on either device, results in zero sends to every device.
- At most one send per device under every failure, including a throwing session.
- `AlreadyThere` is skipped without a send; observation outcomes map to the right exit code.
- Follower results never change `state.json`; a crash during follow leaves no pending operation.
- Config: missing `follow` is valid; every invalid field is rejected; enrollment keeps a backup.
- Packet encoding and reply matching, including error frames and unrelated notifications.

## 11. Changes needed to the project rules

The owner approved these edits to `AGENTS.md` on 16 November 2026, and they are applied together with this document:

- "Exactly one native write per operation" becomes: exactly one monitor write, plus at most one change-host command per enrolled follower.
- HID++ is limited to the fixed surface in §5; no arbitrary reports.
- Follower channel changes happen only in supervised sessions.
- Read this document together with v1.1 before implementation, and the Mac helper plan before Mac work.
- On the Mac, only the owner grants privacy permissions, and the Mac helper is built and tested from `mac/`.

## 12. Relation to the 13 November proposal

An earlier proposal, `PLAN-v1.2-handoff.md`, was written on the Windows PC on 13 November 2026 and never committed. It reached the same architecture: two one-shot helpers, change host over HID++, monitor first, a Swift helper on the Mac. This document replaces it. The differences:

| Topic | 13 November proposal | This design |
| --- | --- | --- |
| Trigger | A K860 key, with the LIFT button as fallback | The LIFT round button on both computers, as the owner asked on 16 November |
| Mac channel | Assumed channel 1 on both devices | Per device. The 16 November probe read the host names and found the Mac on a different channel on each device, so the assumed mouse target would have reached a third computer |
| Order | Mouse, then keyboard | Keyboard, then mouse, because the trigger is now the mouse |
| Command | A separate `handoff` command | `toggle` follows; `toggle --no-follow` keeps the old behavior |
| Config | Schema 2 with migration | Schema 1 with an optional section |

## 13. References

- [HID++ 0x1814 change host](https://openlogi.org/hidpp/features/x1814-change-host)
- [Solaar feature dump for the LIFT (B031)](https://github.com/pwr-Solaar/Solaar/blob/master/docs/devices/LIFT%20VERTICAL%20ERGONOMIC%20MOUSE%20B031.txt)
- [logiops HID++ 2.0 notes](https://github.com/PixlOne/logiops/wiki/HIDPP--2.0)
- [m1ddc](https://github.com/waydabber/m1ddc)
- [mxswitch](https://github.com/marcocosta97/mxswitch), a one-shot change-host tool usable for the gates
