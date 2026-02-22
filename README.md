# openclaw-watchdog

Config Guardian + Health Monitor for OpenClaw Gateway.

Standalone watchdog that runs **outside** OpenClaw — detects gateway failures, diagnoses config corruption, archives broken configs with numbered versions for forensic review, restores from last-known-good backups, and alerts via Telegram.

## The Problem

OpenClaw's `openclaw.json` config can get corrupted by bad patches (e.g., plugin configs, model changes). When this happens:

1. Gateway won't start
2. The agent is completely dead — can't self-diagnose
3. Manual intervention required every time
4. No record of what broke

## The Solution

A lightweight bash watchdog that:

- **Monitors** gateway health every 60s via HTTP ping
- **Detects** config corruption (JSON parse errors, missing files)
- **Archives** broken configs as numbered versions (`broken-0001.json` + `.meta`) for forensic review
- **Restores** from last-known-good backup automatically
- **Restarts** the gateway after restoration
- **Alerts** via Telegram bot API (completely independent of OpenClaw)
- **Snapshots** the config after every successful health check

## Archive Structure

```
~/.openclaw/watchdog/
├── last-known-good.json          # Auto-snapshotted on every healthy check
├── watchdog.log                  # Activity log
├── .consecutive_failures         # Failure counter
└── broken/
    ├── broken-0001.json          # First broken config
    ├── broken-0001.meta          # Metadata (timestamp, error, reason)
    ├── broken-0002.json          # Second broken config
    ├── broken-0002.meta
    └── ...                       # Up to 50 archived (configurable)
```

Each `.meta` file contains:
```
timestamp: 2026-02-22T06:15:00-06:00
hostname: mirapc
reason: invalid-json: Unexpected token } in JSON at position 1234
validation: INVALID: Unexpected token } in JSON at position 1234
gateway_url: http://localhost:18789
openclaw_json: /home/mira/.openclaw/openclaw.json
restored_from: /home/mira/.openclaw/watchdog/last-known-good.json
```

## Installation

```bash
# 1. Copy watchdog.sh somewhere persistent
cp watchdog.sh /path/to/openclaw-watchdog/

# 2. Create config
cat > ~/.openclaw/watchdog.conf << 'EOF'
GATEWAY_URL="http://localhost:18789"
OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
TELEGRAM_BOT_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"
CHECK_INTERVAL=60
CONSECUTIVE_FAILURES_BEFORE_ALERT=2
MAX_BROKEN_ARCHIVES=50
EOF

# 3. Install systemd service
cp openclaw-watchdog.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now openclaw-watchdog.service
```

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
```

## Configuration

All settings via `~/.openclaw/watchdog.conf` or environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `GATEWAY_URL` | `http://localhost:18789` | Gateway health endpoint base URL |
| `OPENCLAW_JSON` | `~/.openclaw/openclaw.json` | Path to config file |
| `TELEGRAM_BOT_TOKEN` | *(none)* | Bot token for alerts |
| `TELEGRAM_CHAT_ID` | *(none)* | Chat ID for alerts |
| `CHECK_INTERVAL` | `60` | Seconds between checks (loop mode) |
| `CONSECUTIVE_FAILURES_BEFORE_ALERT` | `2` | Anti-flap: failures before alerting |
| `MAX_BROKEN_ARCHIVES` | `50` | Max broken configs to keep |
| `RESTART_CMD` | `systemctl --user restart...` | Command to restart gateway |

## Requirements

- bash 4+
- curl
- node or python3 (for JSON validation)
- systemd (optional, for service mode)

## Multi-Instance

Works for multiple OpenClaw instances — each gets its own `watchdog.conf` pointing to its gateway port and config path. Deploy on every machine running OpenClaw.

## License

MIT
