# Rollback

The scaffold does not install or bind anything. Creating/building it does not require resetting the mouse, monitor, display settings or Deskflow.

If the development probe was run manually, it created only `%LOCALAPPDATA%\Deskflip\logs\trigger-probe-*.jsonl` and parent directories. After confirming the probe has exited, optionally remove that file. Do not remove an existing app directory if it contains other work or evidence you want to retain.

For a later approved setup:

1. In Options+, select the LIFT and restore only the button assignment recorded before setup, including any affected app profile.
2. Remove only the dedicated Deskflip Smart Action if one was created. Do not reset all mouse settings or unrelated Smart Actions.
3. Confirm no `Deskflip.exe` or `Deskflip.TriggerProbe.exe` instance is running. A hung native writer must be handled deliberately; its outcome remains uncertain until reconciled/read manually.
4. If video is on the wrong input, use the physical monitor control or a manually requested explicit set only when identity/current state is understood. No blind rollback command.
5. Keep diagnostic logs if desired. Remove only the app-owned installed package/config/state/logs after inspecting `%LOCALAPPDATA%\Deskflip`.
6. Leave both HDMI cables, GPU settings and Deskflow unchanged. Confirm the prior mouse function works.

This repository and its ignored `artifacts` directory can be removed separately when no build or app process uses them. No remote repository or startup registration is created by the scaffold.

## Disable v1.2 following while keeping monitor switching

Use the v1.2 helper's `enroll-follower --name NAME --remove` for each enrolled follower. This changes config only; no device channel or monitor input is changed. Removal refuses while a monitor operation is pending. Resolve that operation deliberately before changing enrollment; never delete uncertain state.

Removing the last follower omits the optional `follow` field, restoring v1.1 config compatibility. An old v1.1 binary rejects config that still contains that field. Keep the separately saved original package/config until the approved update is accepted: `config.previous.json` retains only the immediately previous config. `toggle --no-follow` temporarily bypasses followers in the v1.2 executable; physical Easy-Switch controls recover devices that have already left. There is no automatic device rollback.
