#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# openclaw-watchdog v1.0.0
# Config Guardian + Health Monitor for OpenClaw Gateway
#
# Standalone health checker that runs OUTSIDE OpenClaw so it can detect and
# fix problems even when the gateway is completely down.
#
# Features:
#   - Pings gateway health endpoint every cycle
#   - On failure: validates openclaw.json, archives broken configs with
#     numbered versions for forensic review, restores last known good
#   - Optional alerts via Telegram bot API (no OpenClaw dependency)
#   - Snapshots "last known good" config after every successful check
#   - Configurable via environment, config file, or CLI flags
#
# Usage:
#   ./watchdog.sh                    # Run once (for systemd timer / cron)
#   ./watchdog.sh --loop             # Run continuously (for systemd service)
#   ./watchdog.sh --check            # Dry run — report status, don't fix
#   ./watchdog.sh --history          # Show broken config archive
#   ./watchdog.sh --version          # Show version
#
# Config: ~/.openclaw/watchdog.conf (or WATCHDOG_CONF env var)
#
# Repository: https://github.com/swift-innovate/openclaw-watchdog
# License: MIT
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

VERSION="1.1.0"

# ─── Defaults ─────────────────────────────────────────────────────────────────

GATEWAY_URL="${GATEWAY_URL:-http://localhost:18789}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/api/health}"
OPENCLAW_JSON="${OPENCLAW_JSON:-$HOME/.openclaw/openclaw.json}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/.openclaw/watchdog}"
BROKEN_DIR="${BROKEN_DIR:-$HOME/.openclaw/watchdog/broken}"
LAST_GOOD="${LAST_GOOD:-$HOME/.openclaw/watchdog/last-known-good.json}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
MAX_BROKEN_ARCHIVES="${MAX_BROKEN_ARCHIVES:-50}"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-1048576}"  # 1MB log rotation threshold
RESTART_CMD="${RESTART_CMD:-systemctl --user restart openclaw-gateway.service 2>/dev/null || openclaw gateway restart 2>/dev/null}"
CONSECUTIVE_FAILURES_BEFORE_ALERT="${CONSECUTIVE_FAILURES_BEFORE_ALERT:-2}"
LOG_FILE="${LOG_FILE:-$HOME/.openclaw/watchdog/watchdog.log}"
RECOVERY_LOG="${RECOVERY_LOG:-$HOME/.openclaw/watchdog/last-recovery.md}"
AGENT_MEMORY="${AGENT_MEMORY:-}"  # Optional: path to agent's MEMORY.md to append recovery notes
DRY_RUN=false
LOOP_MODE=false
SHOW_HISTORY=false

# ─── Load config file ────────────────────────────────────────────────────────

CONF_FILE="${WATCHDOG_CONF:-$HOME/.openclaw/watchdog.conf}"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# ─── Parse args ───────────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --check)    DRY_RUN=true ;;
        --loop)     LOOP_MODE=true ;;
        --history)  SHOW_HISTORY=true ;;
        --version|-v)
            echo "openclaw-watchdog v${VERSION}"
            exit 0 ;;
        --help|-h)
            cat <<'HELP'
openclaw-watchdog — Config Guardian + Health Monitor for OpenClaw

Usage:
  watchdog.sh [OPTIONS]

Options:
  --loop        Run continuously (for systemd service)
  --check       Dry run — report status, don't fix anything
  --history     Show broken config archive with metadata
  --version     Show version
  --help        Show this help

Configuration:
  Place a config file at ~/.openclaw/watchdog.conf or set WATCHDOG_CONF
  to a custom path. All settings can also be set via environment variables.

  See README.md for full configuration reference.
HELP
            exit 0 ;;
    esac
done

# ─── Setup ────────────────────────────────────────────────────────────────────

mkdir -p "$BACKUP_DIR" "$BROKEN_DIR"
FAILURE_COUNT_FILE="$BACKUP_DIR/.consecutive_failures"

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if (( size > MAX_LOG_BYTES )); then
            mv "$LOG_FILE" "${LOG_FILE}.1"
            log "Log rotated (previous log at ${LOG_FILE}.1)"
        fi
    fi
}

get_failure_count() {
    if [[ -f "$FAILURE_COUNT_FILE" ]]; then
        cat "$FAILURE_COUNT_FILE"
    else
        echo "0"
    fi
}

set_failure_count() {
    echo "$1" > "$FAILURE_COUNT_FILE"
}

# ─── Telegram alert (no OpenClaw dependency) ──────────────────────────────────

send_alert() {
    local message="$1"
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log "ALERT (no telegram configured): $message"
        return
    fi

    local hostname
    hostname="$(hostname)"
    local full_msg="🚨 <b>OpenClaw Watchdog — ${hostname}</b>

${message}

<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>"

    curl -s --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${full_msg}" \
        > /dev/null 2>&1 || log "WARNING: Failed to send Telegram alert"
}

# ─── Agent memory notification ────────────────────────────────────────────────
# Writes a recovery note so the agent knows what happened and doesn't retry
# the same broken change. Writes to both a dedicated recovery log and
# optionally appends to the agent's MEMORY.md.

notify_agent() {
    local archive_name="$1"
    local reason="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    local note="## ⚠️ Watchdog Recovery — ${ts}

**The gateway crashed and was automatically recovered by openclaw-watchdog.**

- **Reason:** ${reason}
- **Broken config archived as:** \`${archive_name}\`
- **Archive location:** \`${BROKEN_DIR}/${archive_name}\`
- **Restored from:** \`${LAST_GOOD}\`

**DO NOT retry the same config change that caused this crash.**
Review the broken config archive to understand what went wrong before attempting similar changes.
To inspect: \`./watchdog.sh --history\` or read \`${BROKEN_DIR}/${archive_name%.json}.meta\`

---
"

    # Always write to dedicated recovery log (overwritten each time — latest recovery only)
    echo "$note" > "$RECOVERY_LOG"
    log "Wrote recovery note to $RECOVERY_LOG"

    # Optionally append to agent's MEMORY.md
    if [[ -n "$AGENT_MEMORY" && -f "$AGENT_MEMORY" ]]; then
        echo "" >> "$AGENT_MEMORY"
        echo "$note" >> "$AGENT_MEMORY"
        log "Appended recovery note to $AGENT_MEMORY"
    elif [[ -n "$AGENT_MEMORY" && ! -f "$AGENT_MEMORY" ]]; then
        log "WARNING: AGENT_MEMORY set to $AGENT_MEMORY but file does not exist — skipping"
    fi
}

# ─── Health check ─────────────────────────────────────────────────────────────

check_gateway_health() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        "${GATEWAY_URL}${HEALTH_ENDPOINT}" 2>/dev/null) || http_code="000"

    if [[ "$http_code" =~ ^2 ]]; then
        return 0
    else
        return 1
    fi
}

# ─── JSON validation ──────────────────────────────────────────────────────────

validate_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "MISSING"
        return 1
    fi

    # Use node or python3 for safe JSON validation (file path passed as arg, not interpolated)
    if command -v node &>/dev/null; then
        local result
        result=$(node -e '
            const fs = require("fs");
            try {
                JSON.parse(fs.readFileSync(process.argv[1], "utf-8"));
                console.log("VALID");
            } catch(e) {
                console.log("INVALID: " + e.message);
            }
        ' "$file" 2>/dev/null)
        echo "$result"
        [[ "$result" == "VALID" ]]
    elif command -v python3 &>/dev/null; then
        local result
        result=$(python3 -c '
import json, sys
try:
    json.load(open(sys.argv[1]))
    print("VALID")
except Exception as e:
    print(f"INVALID: {e}")
    sys.exit(1)
' "$file" 2>/dev/null)
        echo "$result"
        [[ "$result" == "VALID" ]]
    else
        # Last resort — basic structural check
        if [[ -s "$file" ]] && head -c1 "$file" | grep -q '{'; then
            echo "VALID (basic check only — install node or python3 for full validation)"
            return 0
        else
            echo "INVALID: empty or not JSON"
            return 1
        fi
    fi
}

# ─── Archive broken config ───────────────────────────────────────────────────

archive_broken_config() {
    local source="$1"
    local reason="${2:-unknown}"

    # Find next archive number
    local next_num=1
    if ls "$BROKEN_DIR"/broken-*.json 1>/dev/null 2>&1; then
        next_num=$(ls "$BROKEN_DIR"/broken-*.json | sed 's/.*broken-\([0-9]*\).*/\1/' | sort -n | tail -1)
        next_num=$((next_num + 1))
    fi

    local padded
    padded=$(printf '%04d' "$next_num")
    local archive_name="broken-${padded}.json"
    local archive_path="$BROKEN_DIR/$archive_name"
    local meta_path="$BROKEN_DIR/broken-${padded}.meta"

    cp "$source" "$archive_path"

    # Write metadata alongside the broken config
    cat > "$meta_path" <<EOF
timestamp: $(date -Iseconds)
hostname: $(hostname)
reason: $reason
validation: $(validate_json "$source" 2>/dev/null || echo "failed")
gateway_url: $GATEWAY_URL
openclaw_json: $OPENCLAW_JSON
restored_from: $LAST_GOOD
watchdog_version: $VERSION
EOF

    log "Archived broken config as $archive_name (reason: $reason)"

    # Prune old archives if over limit
    local count
    count=$(ls "$BROKEN_DIR"/broken-*.json 2>/dev/null | wc -l)
    if (( count > MAX_BROKEN_ARCHIVES )); then
        local to_remove=$((count - MAX_BROKEN_ARCHIVES))
        ls "$BROKEN_DIR"/broken-*.json | head -n "$to_remove" | while read -r f; do
            rm -f "$f" "${f%.json}.meta"
        done
        log "Pruned $to_remove old broken config archives"
    fi

    echo "$archive_name"
}

# ─── Snapshot last known good ─────────────────────────────────────────────────

snapshot_good_config() {
    if [[ -f "$OPENCLAW_JSON" ]]; then
        # Only snapshot if the current config is valid JSON
        local status
        status=$(validate_json "$OPENCLAW_JSON" 2>/dev/null) || true
        if [[ "$status" == VALID* ]]; then
            cp "$OPENCLAW_JSON" "$LAST_GOOD"
        else
            log "WARNING: Skipping snapshot — current config is not valid JSON ($status)"
        fi
    fi
}

# ─── Restore from last known good ────────────────────────────────────────────

restore_config() {
    # Try sources in order: last-known-good → openclaw.json.bak
    local sources=("$LAST_GOOD" "${OPENCLAW_JSON}.bak")

    for source in "${sources[@]}"; do
        if [[ ! -f "$source" ]]; then
            log "Restore source not found: $source — trying next"
            continue
        fi

        local backup_status
        backup_status=$(validate_json "$source")
        if [[ "$backup_status" != "VALID" ]]; then
            log "Restore source invalid: $source ($backup_status) — trying next"
            continue
        fi

        cp "$source" "$OPENCLAW_JSON"
        log "Restored openclaw.json from $source"
        return 0
    done

    log "ERROR: All restore sources exhausted — no valid backup found!"
    return 1
}

# ─── Restart gateway ──────────────────────────────────────────────────────────

restart_gateway() {
    log "Attempting gateway restart..."
    eval "$RESTART_CMD" 2>/dev/null || true
    sleep 3
    if check_gateway_health; then
        log "Gateway restarted successfully"
        return 0
    else
        log "Gateway still down after restart"
        return 1
    fi
}

# ─── Show history ─────────────────────────────────────────────────────────────

if $SHOW_HISTORY; then
    echo "═══ OpenClaw Watchdog — Broken Config Archive ═══"
    echo "Location: $BROKEN_DIR"
    echo ""
    if ls "$BROKEN_DIR"/broken-*.meta 1>/dev/null 2>&1; then
        for meta in "$BROKEN_DIR"/broken-*.meta; do
            local_name=$(basename "${meta%.meta}.json")
            echo "── $local_name ──"
            cat "$meta"
            echo ""
        done
        local total
        total=$(ls "$BROKEN_DIR"/broken-*.json 2>/dev/null | wc -l)
        echo "Total: $total archived configs (max: $MAX_BROKEN_ARCHIVES)"
    else
        echo "No broken configs archived yet. That's a good thing."
    fi
    exit 0
fi

# ─── Main check cycle ────────────────────────────────────────────────────────

run_check() {
    # 1. Check gateway health
    if check_gateway_health; then
        # Healthy — reset failure counter, snapshot good config
        local prev_failures
        prev_failures=$(get_failure_count)
        set_failure_count 0

        if (( prev_failures >= CONSECUTIVE_FAILURES_BEFORE_ALERT )); then
            log "Gateway recovered after $prev_failures failures"
            send_alert "✅ Gateway recovered after ${prev_failures} consecutive failures."
        fi

        snapshot_good_config
        return 0
    fi

    # 2. Gateway is down
    local failures
    failures=$(get_failure_count)
    failures=$((failures + 1))
    set_failure_count "$failures"
    log "Gateway health check failed (attempt $failures)"

    if $DRY_RUN; then
        log "[DRY RUN] Would check config and attempt recovery"
        validate_json "$OPENCLAW_JSON"
        return 1
    fi

    # 3. Validate the config file
    local json_status
    json_status=$(validate_json "$OPENCLAW_JSON" 2>/dev/null) || true

    if [[ "$json_status" == "VALID" ]]; then
        # Config is valid JSON — might be a transient issue or bad config values
        log "openclaw.json is valid JSON — attempting restart"

        if restart_gateway; then
            set_failure_count 0
            if (( failures >= CONSECUTIVE_FAILURES_BEFORE_ALERT )); then
                send_alert "⚡ Gateway was down but restarted successfully. Config was valid JSON — likely transient issue."
            fi
            return 0
        fi

        # Still down after restart with valid config — archive and alert
        if (( failures >= CONSECUTIVE_FAILURES_BEFORE_ALERT )); then
            local archive
            archive=$(archive_broken_config "$OPENCLAW_JSON" "valid-json-but-gateway-wont-start")
            send_alert "⚠️ Gateway won't start despite valid JSON config.

Archived current config as <code>${archive}</code> for review.
Attempting restore from last-known-good backup..."

            if restore_config && restart_gateway; then
                set_failure_count 0
                notify_agent "$archive" "Valid JSON but gateway would not start — likely bad config values"
                send_alert "✅ Restored from last-known-good and gateway is back up."
            else
                send_alert "❌ Restore failed or gateway still won't start. Manual intervention needed.

Config path: <code>${OPENCLAW_JSON}</code>
Broken archive: <code>${BROKEN_DIR}/${archive}</code>"
            fi
        fi

    elif [[ "$json_status" == "MISSING" ]]; then
        # Config file is missing entirely — ALWAYS alert immediately
        log "openclaw.json is MISSING!"
        send_alert "🚨 <code>openclaw.json</code> is MISSING!

Attempting restore from last-known-good backup..."

        if restore_config && restart_gateway; then
            set_failure_count 0
            notify_agent "N/A" "Config file was missing entirely — restored from backup"
            send_alert "✅ Restored missing config from backup. Gateway is back up."
        else
            send_alert "❌ Could not restore config. Manual intervention needed."
        fi

    else
        # Config is corrupt/invalid JSON — ALWAYS alert immediately (don't wait for consecutive failures)
        log "openclaw.json is CORRUPT: $json_status"

        local archive
        archive=$(archive_broken_config "$OPENCLAW_JSON" "invalid-json: $json_status")

        send_alert "🚨 <code>openclaw.json</code> is corrupt!

<b>Error:</b> ${json_status}
<b>Archived as:</b> <code>${archive}</code>

Attempting restore from last-known-good backup..."

        if restore_config && restart_gateway; then
            set_failure_count 0
            notify_agent "$archive" "Corrupt JSON: $json_status"
            send_alert "✅ Restored from backup and gateway is back up.

Review the broken config at:
<code>${BROKEN_DIR}/${archive}</code>"
        else
            send_alert "❌ Restore failed or gateway still won't start. Manual intervention needed.

Broken config archived at: <code>${BROKEN_DIR}/${archive}</code>
Last-known-good: <code>${LAST_GOOD}</code>"
        fi
    fi

    return 1
}

# ─── Entry point ──────────────────────────────────────────────────────────────

if $LOOP_MODE; then
    log "Watchdog v${VERSION} starting in loop mode (interval: ${CHECK_INTERVAL}s)"
    while true; do
        rotate_log
        run_check || true
        sleep "$CHECK_INTERVAL"
    done
else
    run_check
fi
