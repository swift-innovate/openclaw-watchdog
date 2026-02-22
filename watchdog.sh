#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# openclaw-watchdog — Config Guardian + Health Monitor
# 
# Standalone health checker for OpenClaw gateway. Runs outside OpenClaw so it
# can detect and fix problems even when the gateway is completely down.
#
# Features:
#   - Pings gateway health endpoint every cycle
#   - On failure: validates openclaw.json, archives broken configs with
#     numbered versions for forensic review, restores last known good
#   - Alerts via Telegram bot API (no OpenClaw dependency)
#   - Snapshots "last known good" config after every successful check
#   - Configurable via environment or config file
#
# Usage:
#   ./watchdog.sh                    # Run once (for systemd timer)
#   ./watchdog.sh --loop             # Run continuously (for systemd service)
#   ./watchdog.sh --check            # Dry run — report status, don't fix
#   ./watchdog.sh --history          # Show broken config archive
#
# Config: ~/.openclaw/watchdog.conf (or WATCHDOG_CONF env var)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

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
RESTART_CMD="${RESTART_CMD:-systemctl --user restart openclaw-gateway.service 2>/dev/null || openclaw gateway restart 2>/dev/null}"
CONSECUTIVE_FAILURES_BEFORE_ALERT="${CONSECUTIVE_FAILURES_BEFORE_ALERT:-2}"
LOG_FILE="${LOG_FILE:-$HOME/.openclaw/watchdog/watchdog.log}"
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
        --help|-h)
            echo "Usage: watchdog.sh [--loop|--check|--history|--help]"
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

    # Try node first (more detailed), fall back to python
    if command -v node &>/dev/null; then
        local result
        result=$(node -e "
            try {
                const fs = require('fs');
                JSON.parse(fs.readFileSync('$file', 'utf-8'));
                console.log('VALID');
            } catch(e) {
                console.log('INVALID: ' + e.message);
            }
        " 2>/dev/null)
        echo "$result"
        [[ "$result" == "VALID" ]]
    elif command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    json.load(open('$file'))
    print('VALID')
except Exception as e:
    print(f'INVALID: {e}')
    sys.exit(1)
" 2>/dev/null
    else
        # Last resort — just check it's non-empty and starts with {
        if [[ -s "$file" ]] && head -c1 "$file" | grep -q '{'; then
            echo "VALID (basic check only)"
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

    local archive_name="broken-$(printf '%04d' "$next_num").json"
    local archive_path="$BROKEN_DIR/$archive_name"
    local meta_path="$BROKEN_DIR/broken-$(printf '%04d' "$next_num").meta"

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
        cp "$OPENCLAW_JSON" "$LAST_GOOD"
    fi
}

# ─── Restore from last known good ────────────────────────────────────────────

restore_config() {
    if [[ ! -f "$LAST_GOOD" ]]; then
        log "ERROR: No last-known-good backup to restore from!"
        return 1
    fi

    # Validate the backup itself
    local backup_status
    backup_status=$(validate_json "$LAST_GOOD")
    if [[ "$backup_status" != "VALID" ]]; then
        log "ERROR: Last-known-good backup is also invalid! ($backup_status)"
        return 1
    fi

    cp "$LAST_GOOD" "$OPENCLAW_JSON"
    log "Restored openclaw.json from last-known-good backup"
    return 0
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
    echo "═══ Broken Config Archive ═══"
    echo "Location: $BROKEN_DIR"
    echo ""
    if ls "$BROKEN_DIR"/broken-*.meta 1>/dev/null 2>&1; then
        for meta in "$BROKEN_DIR"/broken-*.meta; do
            local_name=$(basename "${meta%.meta}.json")
            echo "── $local_name ──"
            cat "$meta"
            echo ""
        done
    else
        echo "No broken configs archived yet."
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
                send_alert "✅ Restored from last-known-good and gateway is back up."
            else
                send_alert "❌ Restore failed or gateway still won't start. Manual intervention needed.

Config path: <code>${OPENCLAW_JSON}</code>
Broken archive: <code>${BROKEN_DIR}/${archive}</code>"
            fi
        fi

    elif [[ "$json_status" == "MISSING" ]]; then
        # Config file is missing entirely
        log "openclaw.json is MISSING!"
        if (( failures >= CONSECUTIVE_FAILURES_BEFORE_ALERT )); then
            send_alert "🚨 <code>openclaw.json</code> is MISSING!

Attempting restore from last-known-good backup..."

            if restore_config && restart_gateway; then
                set_failure_count 0
                send_alert "✅ Restored missing config from backup. Gateway is back up."
            else
                send_alert "❌ Could not restore config. Manual intervention needed."
            fi
        fi

    else
        # Config is corrupt/invalid JSON
        log "openclaw.json is CORRUPT: $json_status"

        local archive
        archive=$(archive_broken_config "$OPENCLAW_JSON" "invalid-json: $json_status")

        if (( failures >= CONSECUTIVE_FAILURES_BEFORE_ALERT )); then
            send_alert "🚨 <code>openclaw.json</code> is corrupt!

<b>Error:</b> ${json_status}
<b>Archived as:</b> <code>${archive}</code>

Attempting restore from last-known-good backup..."
        fi

        if restore_config && restart_gateway; then
            set_failure_count 0
            if (( failures >= CONSECUTIVE_FAILURES_BEFORE_ALERT )); then
                send_alert "✅ Restored from backup and gateway is back up.

Review the broken config at:
<code>${BROKEN_DIR}/${archive}</code>"
            fi
        else
            if (( failures >= CONSECUTIVE_FAILURES_BEFORE_ALERT )); then
                send_alert "❌ Restore failed or gateway still won't start. Manual intervention needed.

Broken config archived at: <code>${BROKEN_DIR}/${archive}</code>
Last-known-good: <code>${LAST_GOOD}</code>"
            fi
        fi
    fi

    return 1
}

# ─── Entry point ──────────────────────────────────────────────────────────────

if $LOOP_MODE; then
    log "Watchdog starting in loop mode (interval: ${CHECK_INTERVAL}s)"
    while true; do
        run_check || true
        sleep "$CHECK_INTERVAL"
    done
else
    run_check
fi
