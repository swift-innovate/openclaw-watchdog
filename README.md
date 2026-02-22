# openclaw-watchdog

Config Guardian + Health Monitor for [OpenClaw](https://github.com/openclaw/openclaw) Gateway.

A standalone watchdog that runs **outside** OpenClaw — detects gateway failures, diagnoses config corruption, archives broken configs with numbered versions for forensic review, restores from last-known-good backups, and alerts via Telegram.

## The Problem

OpenClaw's `openclaw.json` config can get corrupted by bad patches, plugin installs, or manual edits. When this happens:

1. The gateway won't start
2. Your agent is completely dead — it can't self-diagnose or self-heal
3. There's no record of what the config looked like when it broke
4. Manual SSH + fix required every time

## The Solution

A single bash script with zero dependencies (beyond `curl` and `node` or `python3`) that:

- **Monitors** gateway health every 60s via HTTP
- **Detects** config corruption (invalid JSON, missing file)
- **Archives** every broken config as a numbered file (`broken-0001.json`) with metadata — forensic trail for debugging
- **Restores** automatically from the last-known-good backup (falls back to `openclaw.json.bak` if needed)
- **Restarts** the gateway after restoration
- **Alerts** via Telegram bot API (completely independent of OpenClaw)
- **Notifies the agent** via MEMORY.md so it knows what happened and doesn't retry the same broken change
- **Snapshots** the config after every successful health check (validates JSON before snapshotting)

## Quick Start

```bash
# 1. Clone
git clone https://github.com/swift-innovate/openclaw-watchdog.git
cd openclaw-watchdog

# 2. Create your config
cp watchdog.example.conf ~/.openclaw/watchdog.conf
# Edit ~/.openclaw/watchdog.conf with your settings

# 3. Test it
./watchdog.sh --check

# 4. Run it
./watchdog.sh --loop
```

## Installation (systemd)

```bash
# Create a systemd user service
cat > ~/.config/systemd/user/openclaw-watchdog.service << EOF
[Unit]
Description=OpenClaw Watchdog — Config Guardian + Health Monitor
After=network.target

[Service]
Type=simple
ExecStart=$(pwd)/watchdog.sh --loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now openclaw-watchdog.service
```

## How It Works

```
Every 60 seconds:
  └─ Ping gateway /api/health
     ├─ 2xx → Healthy
     │        └─ Validate JSON → if valid, snapshot as "last-known-good"
     │
     └─ Down → Validate openclaw.json
              ├─ Valid JSON → Restart gateway
              │               ├─ Back up? → Done ✅
              │               └─ Still down? → Archive config → Restore backup → Restart → Alert
              │
              ├─ Invalid JSON → Archive → Restore (last-known-good → .bak fallback) → Restart → Alert 🚨
              │
              └─ Missing → Restore (last-known-good → .bak fallback) → Restart → Alert 🚨
```

Anti-flap: waits for 2 consecutive failures before alerting on transient issues (configurable). Corrupt or missing configs trigger **immediate** alerts and recovery on first detection.

## Archive Structure

Every broken config gets archived with a numbered filename and metadata:

```
~/.openclaw/watchdog/
├── last-known-good.json          # Auto-snapshotted on every healthy check
├── watchdog.log                  # Activity log (auto-rotated at 1MB)
└── broken/
    ├── broken-0001.json          # The broken config (exact copy)
    ├── broken-0001.meta          # Metadata for forensics
    ├── broken-0002.json
    ├── broken-0002.meta
    └── ...
```

Each `.meta` file records:
```yaml
timestamp: 2026-02-22T06:15:00-06:00
hostname: myserver
reason: invalid-json: Unexpected token } in JSON at position 1234
validation: INVALID: Unexpected token } in JSON at position 1234
gateway_url: http://localhost:18789
openclaw_json: /home/user/.openclaw/openclaw.json
restored_from: /home/user/.openclaw/watchdog/last-known-good.json
watchdog_version: 1.1.0
```

This lets you go back and see exactly what broke, when, and why — instead of losing the evidence when the config gets overwritten.

## Agent Notification (Break the Retry Loop)

When the watchdog recovers from a crash, it can write a note to the agent's `MEMORY.md`:

```markdown
## ⚠️ Watchdog Recovery — 2026-02-22 06:15:00 CST

**The gateway crashed and was automatically recovered by openclaw-watchdog.**

- **Reason:** Corrupt JSON: Unexpected token } at position 1234
- **Broken config archived as:** `broken-0003.json`

**DO NOT retry the same config change that caused this crash.**
```

This prevents the classic loop: agent makes bad patch → gateway dies → watchdog restores → agent wakes up and retries the same patch → dies again.

Configure with `AGENT_MEMORY` in your config:
```bash
AGENT_MEMORY="$HOME/.openclaw/workspace/MEMORY.md"
```

A dedicated recovery log is also always written to `~/.openclaw/watchdog/last-recovery.md` — add a check for this in your agent's heartbeat routine.

## Configuration

Copy `watchdog.example.conf` to `~/.openclaw/watchdog.conf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `GATEWAY_URL` | `http://localhost:18789` | Gateway base URL |
| `HEALTH_ENDPOINT` | `/api/health` | Health check path |
| `OPENCLAW_JSON` | `~/.openclaw/openclaw.json` | Config file to monitor |
| `TELEGRAM_BOT_TOKEN` | *(none)* | Bot token for alerts (optional) |
| `TELEGRAM_CHAT_ID` | *(none)* | Chat ID for alerts (optional) |
| `CHECK_INTERVAL` | `60` | Seconds between checks |
| `CONSECUTIVE_FAILURES_BEFORE_ALERT` | `2` | Anti-flap threshold (transient failures only; corrupt/missing configs always alert immediately) |
| `MAX_BROKEN_ARCHIVES` | `50` | Max broken configs to keep |
| `MAX_LOG_BYTES` | `1048576` | Log rotation threshold (1MB) |
| `RECOVERY_LOG` | `~/.openclaw/watchdog/last-recovery.md` | Recovery note (overwritten each recovery) |
| `AGENT_MEMORY` | *(none)* | Path to agent's MEMORY.md (optional, appended) |
| `RESTART_CMD` | `systemctl --user restart...` | Gateway restart command |

All settings can also be set via environment variables.

## Usage

```bash
# Run once (for cron or manual check)
./watchdog.sh

# Run in loop mode (for systemd service)
./watchdog.sh --loop

# Dry run — report status, don't fix anything
./watchdog.sh --check

# Show broken config archive history
./watchdog.sh --history

# Show version
./watchdog.sh --version
```

## Requirements

- **bash** 4+
- **curl** (for health checks and Telegram alerts)
- **node** or **python3** (for JSON validation — falls back to basic check if neither available)
- **systemd** (optional, for persistent service mode)

## Security Notes

- The config file (`watchdog.conf`) contains your Telegram bot token — keep it readable only by your user (`chmod 600`)
- The `RESTART_CMD` is executed via `eval` — only set this in config files you control
- No network access beyond the gateway health endpoint and Telegram API (when configured)

## License

MIT — see [LICENSE](LICENSE).

## Credits

Built by [Swift Innovative Technologies](https://swiftinnovate.tech) for the [OpenClaw](https://github.com/openclaw/openclaw) community.
