# Project instructions

- Read `docs/DESIGN-v1.1.md` and `docs/DESIGN-v1.2.md` before implementation, and `docs/MAC-HELPER-PLAN.md` before any Mac work. User authorization determines scope; scaffolding is not authorization for physical switching or button setup.
- Keep the device profile fixed to VCP 0x60 and values 5/6. Do not use standard HDMI 17/18 substitutes.
- Never use primary/first monitor or enumeration order as persistent identity. Refuse ambiguous targeting.
- No hardware writes in automated tests or CI. Test native behavior only in explicitly supervised integration sessions, on Windows or on the Mac.
- No Options+ private-database edits, Deskflow changes, hooks, services, network listeners, drivers, elevation, security-setting changes, or publication.
- Keep unsupported scaffold behavior explicit. Do not replace exit 21 with success before implementing and validating the command.
- Preserve pending operations when state is uncertain. Exactly one native monitor write per operation, plus at most one HID++ change-host command per enrolled follower; never retry or auto-rollback either.
- Keep HID++ to the fixed surface in design v1.2 §5. No arbitrary or raw reports. Send a follower channel change only in a supervised session with the owner present.
- Update the acceptance ledger with measured evidence and clear pending items. Never infer visual success from API acceptance.
- Run restore/build/test from the root. Build and test the Mac helper from `mac/` with `swift build` and `swift test`, and keep Mac work inside `mac/`.
- On the Mac, only the owner grants privacy permissions such as Input Monitoring, through System Settings. Never script them and never use `sudo`.
- Keep artifacts, machine config, state, serials, host names and local evidence out of Git.
