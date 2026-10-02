# Beszel Agent Magisk Module

Runs [beszel-agent](https://github.com/henrygd/beszel) as a Magisk **late_start** service on Android (ARM / ARM64).

## Requirements

- Magisk **v20.4+** (recommended: current Magisk)
- Device ABI: `arm64-v8a` / `aarch64` **or** `armeabi-v7a` / 32-bit ARM
- A reachable Beszel Hub and agent credentials (`KEY`, `TOKEN`, `HUB_URL`)

## Install

1. Flash `beszel-agent-magisk-vX.Y.Z.zip` in Magisk Manager (Modules → Install from storage).
2. Edit the config — **this path survives module updates**:

   ```text
   /data/adb/beszel-agent/beszel-agent.env
   ```

   ```env
   KEY=ssh-ed25519 AAAA...
   TOKEN=your-token
   HUB_URL=http://your-hub:8090
   # optional
   FILESYSTEM=/data
   ```

   `/data/adb/modules/beszel-agent/.env` is a symlink to that file, so editing
   either path works. Prefer the canonical path: it lives outside
   `/data/adb/modules`, which Magisk **wipes on every module update** (see
   Troubleshooting).
3. Reboot. The agent starts after `sys.boot_completed`.

### Where files live

| Path | Lifetime |
|------|----------|
| `/data/adb/beszel-agent/beszel-agent.env` | config — survives updates |
| `/data/adb/beszel-agent/data` | agent state / keypair (fingerprint) — survives updates |
| `/data/adb/beszel-agent/beszel-agent.log` | logs |
| `/data/adb/beszel-agent/supervise.pid` | supervisor pid |
| `/data/adb/modules/beszel-agent/` | replaced on every install/update; `.env` and `data` are symlinks to the above |

An existing config or keypair inside the module directory (older versions) is
migrated automatically on the next install.

## Architecture selection

Handled in `customize.sh` at install time using Magisk’s `$ARCH`:

| Magisk `$ARCH` | Typical ABIs                         | Binary used            |
|----------------|--------------------------------------|------------------------|
| `arm64`        | `arm64-v8a`, `aarch64`               | `beszel-agent-arm64`   |
| `arm`          | `armeabi-v7a`, `armv7l`, `armv8l` 32-bit | `beszel-agent-arm` |

The selected binary is renamed to `bin/beszel-agent`; the other is removed to save space.

## Runtime

`service.sh` (late_start):

Magisk runs `service` stage with **`fork_dont_care`** (non-blocking).  
`service.sh` therefore:

1. Waits for `sys.boot_completed`
2. Loads `KEY` / `TOKEN` / `HUB_URL` (and optional `FILESYSTEM`) from `.env`
3. Spawns a **background supervisor** and exits immediately
4. Supervisor runs the agent and restarts it on death with exponential backoff:

   ```text
   1s → 2s → 4s → 8s → … → 300s (cap)
   ```

   If a run stayed up ≥ 60s, the next backoff resets to **1s**.

   ```sh
   FILESYSTEM="/data" ./beszel-agent -k "$KEY" -t "$TOKEN" --url "$HUB_URL"
   ```

Equivalent intent to systemd `Restart=always` with exponential `RestartSec`.  
Only handles **process exit**, not hung-but-alive agents.

Agent state (fingerprint) is stored under `DATA_DIR` (default
`/data/adb/beszel-agent/data`). Android has no usable `/var/lib/beszel-agent`;
without `DATA_DIR` the agent cannot persist identity and the Hub may reject with
`fingerprint mismatch` after re-registration.

Logs: `/data/adb/beszel-agent/beszel-agent.log`  
Supervisor pid: `/data/adb/beszel-agent/supervise.pid`

## Project layout

```text
module/
  module.prop
  customize.sh          # arch detect + binary install + config/state migration
  service.sh            # late_start launcher
  .env.example          # template (no secrets)
  bin/
    beszel-agent-arm
    beszel-agent-arm64
  META-INF/com/google/android/
    update-binary
    updater-script
```

## Build zips

```sh
# public release (no credentials)
./build.sh

# or on Windows PowerShell
./build.ps1
```

Outputs under `dist/`:

- `beszel-agent-magisk-vX.Y.Z.zip` — publishable (uses `.env.example` only)
- `beszel-agent-magisk-vX.Y.Z-personal.zip` — includes your local `module/.env` (gitignored)

Config precedence at install time:

1. `.env` inside the zip → applied (previous config backed up to
   `/data/adb/beszel-agent/beszel-agent.env.bak`) — personal builds
2. existing `/data/adb/beszel-agent/beszel-agent.env` → preserved
3. `.env` of the currently installed module → migrated
4. `.env.example` → fresh template

## Manual test (root adb)

Read-only arch check:

```sh
adb shell getprop ro.product.cpu.abi
adb shell uname -m
```

After install, without rebooting you can dry-run the binary (will connect to your hub):

```sh
adb shell su -c '/data/adb/modules/beszel-agent/bin/beszel-agent -h'
```

## Troubleshooting

**Magisk installed into `/data/adb/modules_update/`, not `/data/adb/modules/`.**
That is normal. A module install is *staged*: `customize.sh` runs against
`/data/adb/modules_update/<id>`, and on the reboot that applies it Magisk does

```cpp
// native/src/core/module.rs — upgrade_modules()
module.remove_all()?;                     // wipes /data/adb/modules/<id>
e.rename_to(&root, module_name)?;         // moves the pending install in
```

`/data/adb/modules/<id>` before the first reboot only holds the `update` marker
and `module.prop`, which `install_module()` copies there for the app. So
editing `.env` in `/data/adb/modules/beszel-agent/` before the first reboot, or
anywhere inside the module directory afterwards, is always lost on the next
update — that is why config and state live in `/data/adb/beszel-agent/`.

**Module folder looks empty / half-populated after a reboot** (e.g. only `data`,
no `module.prop`, and Magisk shows a module row with a blank version/author).
Check for a staged install that was never completed:

```sh
su -c 'ls -la /data/adb/modules/beszel-agent /data/adb/modules_update 2>/dev/null'
```

If `/data/adb/modules_update/beszel-agent` is stale, remove it
(`su -c 'rm -rf /data/adb/modules_update/beszel-agent'`), then flash the module
again — a stale staged directory is re-applied on every boot.

**Agent restarts in a loop** — read the log:

```sh
su -c 'cat /data/adb/beszel-agent/beszel-agent.log'
```

**Hub reports `fingerprint mismatch`** — `DATA_DIR` was lost, so the agent
generated a new keypair. Delete the system in the Hub and add it again with the
key shown in the log (`grep -i "public key" /data/adb/beszel-agent/beszel-agent.log`).

## License

This Magisk module packaging is released under the **BSD 3-Clause License** (see [LICENSE](LICENSE)).

Upstream `beszel-agent` binaries are from [henrygd/beszel](https://github.com/henrygd/beszel) and remain under that project’s license.
