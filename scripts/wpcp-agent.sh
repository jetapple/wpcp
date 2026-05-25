#!/bin/sh

# WPCP OpenWRT-compatible WireGuard coordination agent.
# - WireGuard is the source of truth for connectivity state.
# - MQTT is used only for control and endpoint observation.

set -u

APP_NAME="wpcp-agent"

WG_INTERFACE=""
MQTT_BROKER=""
MQTT_PORT="1883"
MQTT_USERNAME=""
MQTT_PASSWORD=""
MQTT_TLS="0"
MQTT_CAFILE=""
MQTT_CERT=""
MQTT_KEY=""
TOPIC_PREFIX="wg"
STATE_INTERVAL="15"
ENDPOINT_TIMEOUT="180"
FAILED_TIMEOUT="30"
KEEPALIVE_ACTIVE="25"
EXPLICIT_ENDPOINT=""
QOS_CONTROL="1"
QOS_OBSERVATION="0"
CACHE_FILE=""
CACHE_LOCK_DIR=""
LOG_LEVEL="info"
DETECTOR_PEER_IDS=""
CONFIG_FILE=""
CONFIG_DATA='{}'
CONFIG_READY="0"
AUTO_ACTIVATION="0"

LOCAL_PUBLIC_KEY=""
LOCAL_PEER_ID=""

PID_CONTROL=""
PID_SYNC=""
RUNNING="1"

# Function: usage
# Purpose: Print command-line usage and option descriptions.
# Inputs: None.
# Outputs: Writes help text to stdout.
usage() {
    cat <<EOF
Usage: $APP_NAME --interface IFACE --broker HOST [options]

Required:
  -i, --interface IFACE        WireGuard interface name (for example: wg0)
  -b, --broker HOST            MQTT broker host/IP

Optional:
  -e, --endpoint ADDR          Explicit local public endpoint (host:port or [v6]:port; use none to disable)
  -d, --detector PEER_IDS      Peers to assist with endpoint detection, separated by ',' (optional)
  -c, --config PATH            WireGuard config JSON file (default: disabled)
  -a, --auto 0|1               Auto-manage config peers (default: $AUTO_ACTIVATION)
  -p, --port PORT              MQTT port (default: 1883)
      --username USER          MQTT username
      --password PASS          MQTT password
      --tls 0|1                Enable MQTT TLS (default: $MQTT_TLS)
      --cafile PATH            TLS CA file
      --cert PATH              TLS client cert file
      --key PATH               TLS client key file
      --topic-prefix PREFIX    MQTT topic prefix (default: $TOPIC_PREFIX)
      --state-interval SEC     State reconcile interval (default: $STATE_INTERVAL)
      --endpoint-timeout SEC   Handshake freshness timeout (default: $ENDPOINT_TIMEOUT)
      --failed-timeout SEC     ACTIVATING -> FAILED timeout (default: $FAILED_TIMEOUT)
      --keepalive-active SEC   Active persistent-keepalive (default: $KEEPALIVE_ACTIVE)
      --qos-control 0|1        QoS for activate/deactivate (default: $QOS_CONTROL)
      --qos-observation 0|1    QoS for observation publish (default: $QOS_OBSERVATION)
      --cache-file PATH        Cache file (default: $CACHE_FILE)
      --log-level LEVEL        debug|info|warn|error (default: $LOG_LEVEL)
  -h, --help                   Show help
EOF
}

# Function: log_level_num
# Purpose: Convert a log level string to a comparable numeric value.
# Inputs: $1 = level string (debug/info/warn/error).
# Outputs: Echoes numeric level to stdout.
log_level_num() {
    local level="$1"
    case "$level" in
        debug) echo 10 ;;
        info)  echo 20 ;;
        warn)  echo 30 ;;
        error) echo 40 ;;
        *)     echo 20 ;;
    esac
}

# Function: log
# Purpose: Print timestamped log lines filtered by current log level.
# Inputs: $1 = message level, $2..$n = message text.
# Outputs: Writes formatted log line to stdout when level is enabled.
log() {
    local level="$1"
    shift
    local cur_n="$(log_level_num "$LOG_LEVEL")"
    local msg_n="$(log_level_num "$level")"
    if [ "$msg_n" -ge "$cur_n" ]; then
        if [ "${WPCP_LOG_NO_TS:-0}" = "1" ]; then
            printf '[%s] [%s] %s\n' "$WG_INTERFACE" "$level" "$*"
        else
            local now_ts="$(date -u '+%Y-%m-%d %H:%M:%S')"
            printf '%s [%s] [%s] %s\n' "$now_ts" "$WG_INTERFACE" "$level" "$*"
        fi
    fi
}

# Function: die
# Purpose: Log an error and terminate the process.
# Inputs: $1..$n = error message text.
# Outputs: Writes error log and exits with status 1.
die() {
    local message="$*"
    log error "$message"
    exit 1
}

# Function: require_cmd
# Purpose: Ensure a required external command exists in PATH.
# Inputs: $1 = command name.
# Outputs: No stdout on success; exits on missing command.
require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

# Function: validate_args
# Purpose: Validate CLI options and derive default cache paths.
# Inputs: Global config variables populated by parse_args.
# Outputs: Updates CACHE_FILE/CACHE_LOCK_DIR; exits on invalid args.
validate_args() {
    [ -n "$WG_INTERFACE" ] || die "--interface is required"
    [ -n "$MQTT_BROKER" ] || die "--broker is required"

    case "$MQTT_TLS" in
        0|1) ;;
        *) die "--tls must be 0 or 1" ;;
    esac

    case "$QOS_CONTROL" in
        0|1) ;;
        *) die "--qos-control must be 0 or 1" ;;
    esac

    case "$QOS_OBSERVATION" in
        0|1) ;;
        *) die "--qos-observation must be 0 or 1" ;;
    esac

    case "$STATE_INTERVAL" in
        ''|*[!0-9]*) die "--state-interval must be integer" ;;
        *) ;;
    esac

    case "$ENDPOINT_TIMEOUT" in
        ''|*[!0-9]*) die "--endpoint-timeout must be integer" ;;
        *) ;;
    esac

    case "$FAILED_TIMEOUT" in
        ''|*[!0-9]*) die "--failed-timeout must be integer" ;;
        *) ;;
    esac

    case "$KEEPALIVE_ACTIVE" in
        ''|*[!0-9]*) die "--keepalive-active must be integer" ;;
        *) ;;
    esac

    case "$AUTO_ACTIVATION" in
        0|1) ;;
        *) die "--auto must be 0 or 1" ;;
    esac

    if [ "$AUTO_ACTIVATION" = "1" ] && [ -z "$CONFIG_FILE" ]; then
        die "--auto requires --config"
    fi

    if [ -n "$EXPLICIT_ENDPOINT" ] && [ "$EXPLICIT_ENDPOINT" != "none" ]; then
        endpoint_family="$(detect_endpoint_family "$EXPLICIT_ENDPOINT")"
        if [ "$endpoint_family" != "ipv4" ] && [ "$endpoint_family" != "ipv6" ]; then
            die "--endpoint must be host:port, [v6]:port, or none"
        fi
    fi

    if [ "$MQTT_TLS" = "1" ] && [ -n "$MQTT_CAFILE" ]; then
        [ -r "$MQTT_CAFILE" ] || die "cannot read --cafile: $MQTT_CAFILE"
    fi
    if [ "$MQTT_TLS" = "1" ] && [ -n "$MQTT_CERT" ]; then
        [ -r "$MQTT_CERT" ] || die "cannot read --cert: $MQTT_CERT"
    fi
    if [ "$MQTT_TLS" = "1" ] && [ -n "$MQTT_KEY" ]; then
        [ -r "$MQTT_KEY" ] || die "cannot read --key: $MQTT_KEY"
    fi

    if [ -z "$CACHE_FILE" ]; then
        CACHE_FILE="/tmp/wpcp-${WG_INTERFACE}-cache.json"
    fi
    CACHE_LOCK_DIR="${CACHE_FILE}.lock"
}

# Function: parse_args
# Purpose: Parse command-line options into global configuration variables.
# Inputs: Positional CLI arguments ($@).
# Outputs: Sets global config variables; may call usage and exit.
parse_args() {
    while [ "$#" -gt 0 ]; do
        local opt="$1"
        local val="${2:-}"
        case "$opt" in
            -i|--interface)
                WG_INTERFACE="$val"
                shift 2
                ;;
            -b|--broker)
                MQTT_BROKER="$val"
                shift 2
                ;;
            -p|--port)
                MQTT_PORT="$val"
                shift 2
                ;;
            --username)
                MQTT_USERNAME="$val"
                shift 2
                ;;
            --password)
                MQTT_PASSWORD="$val"
                shift 2
                ;;
            --tls)
                MQTT_TLS="$val"
                shift 2
                ;;
            --cafile)
                MQTT_CAFILE="$val"
                shift 2
                ;;
            --cert)
                MQTT_CERT="$val"
                shift 2
                ;;
            --key)
                MQTT_KEY="$val"
                shift 2
                ;;
            --topic-prefix)
                TOPIC_PREFIX="$val"
                shift 2
                ;;
            --state-interval)
                STATE_INTERVAL="$val"
                shift 2
                ;;
            --endpoint-timeout)
                ENDPOINT_TIMEOUT="$val"
                shift 2
                ;;
            --failed-timeout)
                FAILED_TIMEOUT="$val"
                shift 2
                ;;
            --keepalive-active)
                KEEPALIVE_ACTIVE="$val"
                shift 2
                ;;
            -e|--endpoint)
                EXPLICIT_ENDPOINT="$val"
                shift 2
                ;;
            --qos-control)
                QOS_CONTROL="$val"
                shift 2
                ;;
            --qos-observation)
                QOS_OBSERVATION="$val"
                shift 2
                ;;
            --cache-file)
                CACHE_FILE="$val"
                shift 2
                ;;
            --log-level)
                LOG_LEVEL="$val"
                shift 2
                ;;
            -a|--auto)
                AUTO_ACTIVATION="$val"
                shift 2
                ;;
            -d|--detector)
                DETECTOR_PEER_IDS="$val"
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="$val"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $opt"
                ;;
        esac
    done
}

# Function: setup_dependencies
# Purpose: Verify all required runtime tools are available.
# Inputs: None.
# Outputs: No stdout on success; exits if a dependency is missing.
setup_dependencies() {
    require_cmd wg
    require_cmd jq
    require_cmd mosquitto_pub
    require_cmd mosquitto_sub
    require_cmd sha256sum
    require_cmd base32

    if ! command -v openssl >/dev/null 2>&1 && ! command -v xxd >/dev/null 2>&1; then
        die "need either openssl or xxd for peer_id hash->base32 conversion"
    fi
}

# Function: calc_peer_id
# Purpose: Derive deterministic peer_id from a WireGuard public key.
# Inputs: $1 = peer public key.
# Outputs: Echoes computed peer_id to stdout.
calc_peer_id() {
    local pubkey="$1"

    if command -v openssl >/dev/null 2>&1; then
        printf '%s' "$pubkey" \
            | openssl dgst -sha256 -binary 2>/dev/null \
            | dd bs=1 count=16 2>/dev/null \
            | base32 2>/dev/null \
            | tr -d '=\n' \
            | tr 'A-Z' 'a-z'
        return 0
    fi

    local hash32="$(printf '%s' "$pubkey" | sha256sum | awk '{print $1}' | cut -c1-32)"
    printf '%s' "$hash32" \
        | xxd -r -p 2>/dev/null \
        | base32 2>/dev/null \
        | tr -d '=\n' \
        | tr 'A-Z' 'a-z'
}

# Function: cache_lock
# Purpose: Acquire an exclusive lock for cache file updates.
# Inputs: Uses global CACHE_LOCK_DIR.
# Outputs: Blocks until lock directory is created.
cache_lock() {
    while ! mkdir "$CACHE_LOCK_DIR" 2>/dev/null; do
        sleep 1
    done
}

# Function: cache_unlock
# Purpose: Release the cache file lock.
# Inputs: Uses global CACHE_LOCK_DIR.
# Outputs: Removes lock directory; ignores errors.
cache_unlock() {
    rmdir "$CACHE_LOCK_DIR" 2>/dev/null || true
}

# Function: cache_init
# Purpose: Initialize cache file with default JSON structure when absent.
# Inputs: Uses global CACHE_FILE and lock settings.
# Outputs: Creates cache file if needed.
cache_init() {
    cache_lock
    if [ ! -f "$CACHE_FILE" ]; then
        printf '{"peers":{}}\n' > "$CACHE_FILE"
    fi
    cache_unlock
}

# Function: cache_update_with_jq
# Purpose: Atomically update cache JSON by applying a jq filter.
# Inputs: $1 = jq filter, remaining args = jq arguments.
# Outputs: Returns 0 on success, 1 on jq/apply failure.
cache_update_with_jq() {
    local jq_filter="$1"
    shift

    local tmp_file="${CACHE_FILE}.tmp"

    cache_lock
    if ! jq "$jq_filter" "$@" "$CACHE_FILE" > "$tmp_file" 2>/dev/null; then
        cache_unlock
        rm -f "$tmp_file"
        return 1
    fi
    mv "$tmp_file" "$CACHE_FILE"
    cache_unlock
    return 0
}

# Function: cache_get_str
# Purpose: Read a string field from a peer record in cache.
# Inputs: $1 = peer_id, $2 = field name.
# Outputs: Echoes string value or empty string.
cache_get_str() {
    local pid="$1"
    local key="$2"
    jq -r --arg pid "$pid" --arg key "$key" '.peers[$pid][$key] // ""' "$CACHE_FILE" 2>/dev/null
}

# Function: cache_get_num
# Purpose: Read a numeric field from a peer record in cache.
# Inputs: $1 = peer_id, $2 = field name.
# Outputs: Echoes numeric value or 0.
cache_get_num() {
    local pid="$1"
    local key="$2"
    jq -r --arg pid "$pid" --arg key "$key" '.peers[$pid][$key] // 0' "$CACHE_FILE" 2>/dev/null
}

# Function: config_reload
# Purpose: Reload peer policy config from disk into memory.
# Inputs: Uses CONFIG_FILE and WG_INTERFACE globals.
# Outputs: Updates CONFIG_DATA/CONFIG_READY; returns 0 on successful load.
config_reload() {
    [ -n "$CONFIG_FILE" ] || return 1

    if [ ! -r "$CONFIG_FILE" ]; then
        log warn "cannot read config file: $CONFIG_FILE"
        return 1
    fi

    local parsed
    parsed="$(jq -c . "$CONFIG_FILE" 2>/dev/null)" || {
        log warn "invalid JSON in config file: $CONFIG_FILE"
        return 1
    }

    CONFIG_DATA="$parsed"
    CONFIG_READY="1"
    return 0
}

# Function: config_enforced
# Purpose: Tell whether config-based peer policy is currently enforceable.
# Inputs: Uses CONFIG_FILE and CONFIG_READY globals.
# Outputs: Returns 0 if policy enforcement is active.
config_enforced() {
    [ -n "$CONFIG_FILE" ] && [ "$CONFIG_READY" = "1" ]
}

# Function: config_has_peer
# Purpose: Check whether a peer_id exists in current interface config.
# Inputs: $1 = peer_id.
# Outputs: Returns 0 if present in config.
config_has_peer() {
    local pid="$1"
    printf '%s' "$CONFIG_DATA" | jq -e --arg iface "$WG_INTERFACE" --arg pid "$pid" '.[$iface][$pid] != null' >/dev/null 2>&1
}

# Function: config_get_peer_public_key
# Purpose: Read configured public_key for peer_id.
# Inputs: $1 = peer_id.
# Outputs: Echoes configured public_key or empty string.
config_get_peer_public_key() {
    local pid="$1"
    printf '%s' "$CONFIG_DATA" | jq -r --arg iface "$WG_INTERFACE" --arg pid "$pid" '.[$iface][$pid].public_key // ""' 2>/dev/null
}

# Function: config_get_peer_allowed_ips
# Purpose: Read configured allowed_ips as a wg-compatible comma list.
# Inputs: $1 = peer_id.
# Outputs: Echoes comma-separated allowed_ips or empty string.
config_get_peer_allowed_ips() {
    local pid="$1"
    printf '%s' "$CONFIG_DATA" | jq -r --arg iface "$WG_INTERFACE" --arg pid "$pid" '
        .[$iface][$pid].allowed_ips // empty
        | if type == "array" then
            map(select(type == "string" and length > 0)) | join(",")
          elif type == "string" then
            .
          else
            ""
          end
    ' 2>/dev/null
}

# Function: config_get_peers
# Purpose: Enumerate peer IDs defined in the current interface config.
# Inputs: None.
# Outputs: Prints one peer_id per line.
config_get_peers() {
    printf '%s' "$CONFIG_DATA" | jq -r --arg iface "$WG_INTERFACE" '(.[$iface] // {}) | keys[]' 2>/dev/null | sort
}

# Function: enforce_config_allowlist
# Purpose: Remove runtime WG peers missing from the configured interface allowlist.
# Inputs: Uses WG interface state and config globals.
# Outputs: Removes disallowed peers and updates cache state.
enforce_config_allowlist() {
    config_enforced || return 0

    wg show "$WG_INTERFACE" peers | while IFS= read -r peer_pubkey; do
        [ -n "$peer_pubkey" ] || continue

        local peer_id="$(calc_peer_id "$peer_pubkey")"
        if is_detector_peer_id "$peer_id"; then
            continue
        fi

        if ! config_has_peer "$peer_id"; then
            log warn "config enforcement: removing peer_id=$peer_id not present in $CONFIG_FILE"
            if ! deactivate_peer "$peer_id" "$peer_pubkey" "config-request"; then
                log warn "config enforcement: failed removing peer_id=$peer_id"
            fi
        fi
    done
}

# Function: detect_endpoint_family
# Purpose: Classify endpoint string as ipv4/ipv6/none/unknown.
# Inputs: $1 = endpoint string from wg or observation.
# Outputs: Echoes endpoint family label.
detect_endpoint_family() {
    local endpoint="$1"

    if [ -z "$endpoint" ] || [ "$endpoint" = "(none)" ]; then
        echo "none"
        return
    fi

    case "$endpoint" in
        \[*\]:*)
            echo "ipv6"
            return
            ;;
    esac

    case "$endpoint" in
        *.*.*.*:*)
            echo "ipv4"
            return
            ;;
    esac

    local colon_count="$(printf '%s' "$endpoint" | tr -cd ':' | wc -c | awk '{print $1}')"
    if [ "$colon_count" -ge 2 ]; then
        echo "ipv6"
        return
    fi

    echo "unknown"
}

# Function: split_detector_peer_ids
# Purpose: Split detector peer IDs by ',', trim whitespace, and ignore empty items.
# Inputs: $1 = comma-separated detector peer IDs.
# Outputs: Prints one normalized peer_id per line.
split_detector_peer_ids() {
    local detector_raw="$1"

    [ -n "$detector_raw" ] || return 0

    printf '%s\n' "$detector_raw" | tr ',' '\n' | while IFS= read -r detector_peer_id; do
        detector_peer_id="$(printf '%s' "$detector_peer_id" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$detector_peer_id" ] || continue
        printf '%s\n' "$detector_peer_id"
    done
}

# Function: is_detector_peer_id
# Purpose: Check whether a peer_id is listed in detector peers.
# Inputs: $1 = peer_id.
# Outputs: Returns 0 if peer_id is configured as detector.
is_detector_peer_id() {
    local pid="$1"

    [ -n "$pid" ] || return 1
    [ -n "$DETECTOR_PEER_IDS" ] || return 1

    split_detector_peer_ids "$DETECTOR_PEER_IDS" | grep -Fxq "$pid"
}

# Function: cache_ensure_peer
# Purpose: Ensure a peer object exists and refresh base metadata.
# Inputs: $1 = peer_id, $2 = public key.
# Outputs: Returns cache_update_with_jq status.
cache_ensure_peer() {
    local pid="$1"
    local pubkey="$2"
    local now_epoch="$(date -u +%s)"

    cache_update_with_jq \
        --arg pid "$pid" \
        --arg pubkey "$pubkey" \
        --argjson now "$now_epoch" \
        '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, updated_at:$now})'
}

    # Function: cache_set_endpoint
    # Purpose: Save peer endpoint and observation metadata into cache.
    # Inputs: $1 = peer_id, $2 = public key, $3 = endpoint, $4 = observed_by, $5 = interface, $6 = latest_handshake, $7 = observed_at.
    # Outputs: Returns cache_update_with_jq status.
cache_set_endpoint() {
    local pid="$1"
    local pubkey="$2"
    local endpoint="$3"
    local observed_by="$4"
    local obs_iface="$5"
    local latest_hs="$6"
    local observed_at="$7"

    local family="$(detect_endpoint_family "$endpoint")"
    local now_epoch="$(date -u +%s)"

    if [ "$family" = "ipv4" ]; then
        cache_update_with_jq \
            --arg pid "$pid" \
            --arg pubkey "$pubkey" \
            --arg endpoint "$endpoint" \
            --arg observed_by "$observed_by" \
            --arg obs_iface "$obs_iface" \
            --argjson latest_hs "$latest_hs" \
            --argjson observed_at "$observed_at" \
            --argjson now "$now_epoch" \
            '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, latest_handshake:$latest_hs, updated_at:$now} | .endpoint = (.endpoint // {}) | .endpoint.ipv4 = {endpoint:$endpoint, observed_by:$observed_by, observed_at:$observed_at, interface:$obs_iface, latest_handshake:$latest_hs})'
        return
    fi

    if [ "$family" = "ipv6" ]; then
        cache_update_with_jq \
            --arg pid "$pid" \
            --arg pubkey "$pubkey" \
            --arg endpoint "$endpoint" \
            --arg observed_by "$observed_by" \
            --arg obs_iface "$obs_iface" \
            --argjson latest_hs "$latest_hs" \
            --argjson observed_at "$observed_at" \
            --argjson now "$now_epoch" \
            '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, latest_handshake:$latest_hs, updated_at:$now} | .endpoint = (.endpoint // {}) | .endpoint.ipv6 = {endpoint:$endpoint, observed_by:$observed_by, observed_at:$observed_at, interface:$obs_iface, latest_handshake:$latest_hs})'
        return
    fi

    cache_update_with_jq \
        --arg pid "$pid" \
        --arg pubkey "$pubkey" \
        --argjson latest_hs "$latest_hs" \
        --argjson now "$now_epoch" \
        '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, latest_handshake:$latest_hs, updated_at:$now})'
}

# Function: cache_set_activation_started
# Purpose: Record activation start timestamp for a peer.
# Inputs: $1 = peer_id.
# Outputs: Returns cache_update_with_jq status.
cache_set_activation_started() {
    local pid="$1"
    local now_epoch="$(date -u +%s)"
    cache_update_with_jq --arg pid "$pid" --argjson now "$now_epoch" '.peers[$pid] = ((.peers[$pid] // {}) + {activation_started_at:$now})'
}

# Function: cache_clear_activation_started
# Purpose: Remove activation start timestamp from a peer record.
# Inputs: $1 = peer_id.
# Outputs: Returns cache_update_with_jq status.
cache_clear_activation_started() {
    local pid="$1"
    cache_update_with_jq --arg pid "$pid" '.peers[$pid] = ((.peers[$pid] // {}) | del(.activation_started_at))'
}

# Function: cache_set_state
# Purpose: Persist current FSM state and state update time for a peer.
# Inputs: $1 = peer_id, $2 = state string.
# Outputs: Returns cache_update_with_jq status.
cache_set_state() {
    local pid="$1"
    local state="$2"
    local now_epoch="$(date -u +%s)"
    cache_update_with_jq --arg pid "$pid" --arg state "$state" --argjson now "$now_epoch" '.peers[$pid] = ((.peers[$pid] // {}) + {state:$state, state_updated_at:$now})'
}

# Function: cache_get_endpoint_v4
# Purpose: Get cached IPv4 endpoint for a peer.
# Inputs: $1 = peer_id.
# Outputs: Echoes endpoint string or empty.
cache_get_endpoint_v4() {
    local pid="$1"
    jq -r --arg pid "$pid" '.peers[$pid].endpoint.ipv4.endpoint // ""' "$CACHE_FILE" 2>/dev/null
}

# Function: cache_get_endpoint_v6
# Purpose: Get cached IPv6 endpoint for a peer.
# Inputs: $1 = peer_id.
# Outputs: Echoes endpoint string or empty.
cache_get_endpoint_v6() {
    local pid="$1"
    jq -r --arg pid "$pid" '.peers[$pid].endpoint.ipv6.endpoint // ""' "$CACHE_FILE" 2>/dev/null
}

# Function: cache_get_endpoint_observed_at
# Purpose: Get cached endpoint observed_at value for a specific family.
# Inputs: $1 = peer_id, $2 = family (ipv4/ipv6).
# Outputs: Echoes observed_at epoch seconds or 0.
cache_get_endpoint_observed_at() {
    local pid="$1"
    local family="$2"
    jq -r --arg pid "$pid" --arg family "$family" '.peers[$pid].endpoint[$family].observed_at // 0' "$CACHE_FILE" 2>/dev/null
}

# Function: cache_get_state
# Purpose: Get cached peer state string.
# Inputs: $1 = peer_id.
# Outputs: Echoes state string or empty.
cache_get_state() {
    local pid="$1"
    cache_get_str "$pid" "state"
}

# Function: cache_get_latest_handshake
# Purpose: Get cached latest_handshake value.
# Inputs: $1 = peer_id.
# Outputs: Echoes latest_handshake or 0.
cache_get_latest_handshake() {
    local pid="$1"
    cache_get_num "$pid" "latest_handshake"
}

# Function: peer_has_fresh_endpoint
# Purpose: Check whether a peer has an endpoint and a fresh handshake signal.
# Inputs: $1 = peer_id.
# Outputs: Returns 0 if cached endpoint data is usable for activation.
peer_has_fresh_endpoint() {
    local pid="$1"
    local latest_hs="$(cache_get_latest_handshake "$pid")"
    local now_epoch="$(date -u +%s)"

    if [ "$latest_hs" -le 0 ]; then
        return 1
    fi

    local endpoint="$(select_activation_endpoint "$pid" "auto")"
    [ -n "$endpoint" ] && [ "$endpoint" != "(none)" ] || return 1

    local family="$(detect_endpoint_family "$endpoint")"
    case "$family" in
        ipv4|ipv6) ;;
        *) return 1 ;;
    esac

    local observed_at="$(cache_get_endpoint_observed_at "$pid" "$family")"
    if [ "$observed_at" -le 0 ]; then
        return 1
    fi

    [ $((now_epoch - observed_at)) -lt "$ENDPOINT_TIMEOUT" ]
}

# Function: auto_activate_configured_peers
# Purpose: Automatically keep config-defined peers in sync with wg state.
# Inputs: Uses AUTO_ACTIVATION, CONFIG_DATA, WG_INTERFACE, cache, and wg runtime state.
# Outputs: Activates missing peers with fresh endpoints; deactivates peers in wg with bad state.
auto_activate_configured_peers() {
    [ "$AUTO_ACTIVATION" = "1" ] || return 0
    config_enforced || return 0

    config_get_peers | while IFS= read -r peer_id; do
        [ -n "$peer_id" ] || continue

        if is_detector_peer_id "$peer_id"; then
            continue
        fi

        local peer_pubkey="$(config_get_peer_public_key "$peer_id")"
        if [ -z "$peer_pubkey" ]; then
            log warn "auto management: config peer_id=$peer_id missing public_key, skipping"
            continue
        fi

        if wg show "$WG_INTERFACE" peers | grep -Fxq "$peer_pubkey"; then
            local peer_state="$(cache_get_state "$peer_id")"
            if [ "$peer_state" = "CONNECTED" ] || [ "$peer_state" = "ACTIVATING" ]; then
                log debug "auto management: keep peer_id=$peer_id state=$peer_state"
                continue
            fi

            log info "auto management: deactivating peer_id=$peer_id state=${peer_state:-unknown}"
            deactivate_peer "$peer_id" "$peer_pubkey" "auto-config" || true
        else
            if peer_has_fresh_endpoint "$peer_id"; then
                log info "auto management: activating peer_id=$peer_id"
                activate_peer "$peer_id" "$peer_pubkey" "auto-config" || true
            else
                log debug "auto management: skip activate peer_id=$peer_id no fresh endpoint"
            fi
        fi
    done
}

# Function: mqtt_pub
# Purpose: Publish one MQTT message with configured auth/TLS options.
# Inputs: $1 = topic, $2 = payload, $3 = qos.
# Outputs: Forwards mosquitto_pub exit status.
mqtt_pub() {
    local topic="$1"
    local payload="$2"
    local qos="$3"

    set -- mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -q "$qos" -t "$topic" -m "$payload"
    if [ -n "$MQTT_USERNAME" ]; then
        set -- "$@" -u "$MQTT_USERNAME"
    fi
    if [ -n "$MQTT_PASSWORD" ]; then
        set -- "$@" -P "$MQTT_PASSWORD"
    fi

    if [ "$MQTT_TLS" = "1" ]; then
        if [ -n "$MQTT_CAFILE" ]; then
            set -- "$@" --cafile "$MQTT_CAFILE"
        fi
        if [ -n "$MQTT_CERT" ]; then
            set -- "$@" --cert "$MQTT_CERT"
        fi
        if [ -n "$MQTT_KEY" ]; then
            set -- "$@" --key "$MQTT_KEY"
        fi
    fi

    "$@"
}

# Function: mqtt_subscribe_stream
# Purpose: Open MQTT subscription stream for control and observation topics.
# Inputs: $1 = control topic, $2 = observation topic wildcard.
# Outputs: Streams mosquitto_sub lines to stdout.
mqtt_subscribe_stream() {
    local control_topic="$1"
    local obs_topic="$2"

    set -- mosquitto_sub -h "$MQTT_BROKER" -p "$MQTT_PORT" -v -q 1 -t "$control_topic" -t "$obs_topic"
    if [ -n "$MQTT_USERNAME" ]; then
        set -- "$@" -u "$MQTT_USERNAME"
    fi
    if [ -n "$MQTT_PASSWORD" ]; then
        set -- "$@" -P "$MQTT_PASSWORD"
    fi

    if [ "$MQTT_TLS" = "1" ]; then
        if [ -n "$MQTT_CAFILE" ]; then
            set -- "$@" --cafile "$MQTT_CAFILE"
        fi
        if [ -n "$MQTT_CERT" ]; then
            set -- "$@" --cert "$MQTT_CERT"
        fi
        if [ -n "$MQTT_KEY" ]; then
            set -- "$@" --key "$MQTT_KEY"
        fi
    fi

    "$@"
}

# Function: publish_control
# Purpose: Publish activate/deactivate control message for a target peer.
# Inputs: $1 = target peer_id, $2 = message type, $3 = reason, $4 = target public key, $5 = family (optional for activate).
# Outputs: Sends MQTT message; logs warning on failure.
publish_control() {
    local target_peer_id="$1"
    local msg_type="$2"
    local reason="$3"
    local target_pubkey="$4"
    local family="${5:-}"

    local topic="$TOPIC_PREFIX/peer/$target_peer_id/control"
    if [ "$msg_type" = "activate" ] && { [ "$family" = "ipv4" ] || [ "$family" = "ipv6" ]; }; then
        local payload="$(jq -cn --arg t "$msg_type" --arg pid "$LOCAL_PEER_ID" --arg pk "$LOCAL_PUBLIC_KEY" --arg r "$reason" --arg tpk "$target_pubkey" --arg f "$family" '{type:$t,peer_id:$pid,public_key:$pk,reason:$r,target_public_key:$tpk,family:$f}')"
    else
        local payload="$(jq -cn --arg t "$msg_type" --arg pid "$LOCAL_PEER_ID" --arg pk "$LOCAL_PUBLIC_KEY" --arg r "$reason" --arg tpk "$target_pubkey" '{type:$t,peer_id:$pid,public_key:$pk,reason:$r,target_public_key:$tpk}')"
    fi
    mqtt_pub "$topic" "$payload" "$QOS_CONTROL" >/dev/null 2>&1 || log warn "failed to publish $msg_type to $topic"
}

# Function: publish_observation_for_peer
# Purpose: Publish endpoint/handshake observation payload for one peer.
# Inputs: $1 = peer public key, $2 = peer_id, $3 = endpoint, $4 = latest_handshake, $5 = observed_at.
# Outputs: Sends MQTT message; logs warning on failure.
publish_observation_for_peer() {
    local peer_pubkey="$1"
    local peer_id="$2"
    local endpoint="$3"
    local latest_hs="$4"
    local observed_at="$5"

    local payload="$(jq -cn \
        --arg t "observation" \
        --arg pid "$peer_id" \
        --arg pk "$peer_pubkey" \
        --arg endpoint "$endpoint" \
        --arg observed_by "$LOCAL_PEER_ID" \
        --arg iface "$WG_INTERFACE" \
        --argjson latest "$latest_hs" \
        --argjson observed_at "$observed_at" \
        '{type:$t,peer_id:$pid,public_key:$pk,endpoint:$endpoint,latest_handshake:$latest,observed_at:$observed_at,observed_by:$observed_by,interface:$iface}')"

    local topic="$TOPIC_PREFIX/peer/$peer_id/observation"
    mqtt_pub "$topic" "$payload" "$QOS_OBSERVATION" >/dev/null 2>&1 || log warn "failed to publish observation for peer_id=$peer_id"
}

# Function: verify_peer_binding
# Purpose: Verify peer_id matches the hash of the provided public key.
# Inputs: $1 = peer_id, $2 = public key.
# Outputs: Returns success when binding is valid.
verify_peer_binding() {
    local peer_id="$1"
    local pubkey="$2"

    local calc_id="$(calc_peer_id "$pubkey")"
    [ "$calc_id" = "$peer_id" ]
}

# Function: select_activation_endpoint
# Purpose: Pick best endpoint for activation, preferring IPv6 dual-stack path.
# Inputs: $1 = remote peer_id, $2 = family preference (ipv4/ipv6/auto).
# Outputs: Echoes selected endpoint or empty string.
select_activation_endpoint() {
    local remote_peer_id="$1"
    local family="${2:-auto}"

    local local_v6="$(cache_get_endpoint_v6 "$LOCAL_PEER_ID")"
    local remote_v6="$(cache_get_endpoint_v6 "$remote_peer_id")"
    local remote_v4="$(cache_get_endpoint_v4 "$remote_peer_id")"

    if [ "$family" = "ipv6" ]; then
        echo "$remote_v6"
        return
    fi

    if [ "$family" = "ipv4" ]; then
        echo "$remote_v4"
        return
    fi

    if [ -n "$local_v6" ] && [ -n "$remote_v6" ]; then
        echo "$remote_v6"
        return
    fi

    if [ -n "$remote_v4" ]; then
        echo "$remote_v4"
        return
    fi

    if [ -n "$remote_v6" ]; then
        echo "$remote_v6"
        return
    fi

    echo ""
}

# Function: activate_peer
# Purpose: Configure wg peer endpoint/keepalive and emit activate control.
# Inputs: $1 = remote peer_id, $2 = remote public key, $3 = reason, $4 = family preference (optional).
# Outputs: Returns 0 on success, 1 on activation failure.
activate_peer() {
    local remote_peer_id="$1"
    local remote_pubkey="$2"
    local reason="$3"
    local family="${4:-auto}"
    log debug "activating peer_id=$remote_peer_id reason=$reason family=$family"

    local allowed_ips=""
    if config_enforced && ! is_detector_peer_id "$remote_peer_id"; then
        if ! config_has_peer "$remote_peer_id"; then
            log warn "activate blocked by config: peer_id=$remote_peer_id not present in $CONFIG_FILE"
            return 1
        fi

        local config_pubkey="$(config_get_peer_public_key "$remote_peer_id")"
        if [ -z "$config_pubkey" ] || [ "$config_pubkey" != "$remote_pubkey" ]; then
            log warn "activate blocked by config: peer_id/public_key mismatch peer_id=$remote_peer_id"
            return 1
        fi

        allowed_ips="$(config_get_peer_allowed_ips "$remote_peer_id")"
        log debug "config enforcement: allowing peer_id=$remote_peer_id with allowed_ips='$allowed_ips'"
    fi

    local endpoint="$(select_activation_endpoint "$remote_peer_id" "$family")"

    if [ -n "$endpoint" ]; then
        if [ -n "$allowed_ips" ]; then
            if ! wg set "$WG_INTERFACE" peer "$remote_pubkey" endpoint "$endpoint" persistent-keepalive "$KEEPALIVE_ACTIVE" allowed-ips "$allowed_ips"; then
                log warn "wg set activate failed peer_id=$remote_peer_id endpoint=$endpoint allowed_ips=$allowed_ips"
                return 1
            fi
        elif ! wg set "$WG_INTERFACE" peer "$remote_pubkey" endpoint "$endpoint" persistent-keepalive "$KEEPALIVE_ACTIVE"; then
            log warn "wg set activate failed peer_id=$remote_peer_id endpoint=$endpoint"
            return 1
        fi
    else
        log debug "activate peer_id=$remote_peer_id: no endpoint in cache, adding peer without endpoint"
        if [ -n "$allowed_ips" ]; then
            if ! wg set "$WG_INTERFACE" peer "$remote_pubkey" allowed-ips "$allowed_ips"; then
                log warn "wg set activate failed peer_id=$remote_peer_id allowed_ips=$allowed_ips"
                return 1
            fi
        elif ! wg set "$WG_INTERFACE" peer "$remote_pubkey"; then
            log warn "wg set activate failed peer_id=$remote_peer_id (no endpoint)"
            return 1
        fi
    fi

    cache_set_activation_started "$remote_peer_id" || true
    cache_set_state "$remote_peer_id" "ACTIVATING" || true
    if [ "$reason" != "peer-request" ]; then
        publish_control "$remote_peer_id" "activate" "peer-request" "$remote_pubkey" "$(detect_endpoint_family "$endpoint")"
    fi

    log info "activate peer_id=$remote_peer_id endpoint=${endpoint:-none} reason=$reason family=$family"
    return 0
}

# Function: deactivate_peer
# Purpose: Remove wg peer config and emit deactivate control.
# Inputs: $1 = remote peer_id, $2 = remote public key, $3 = reason.
# Outputs: Returns 0 on success, 1 on deactivation failure.
deactivate_peer() {
    local remote_peer_id="$1"
    local remote_pubkey="$2"
    local reason="$3"
    log debug "deactivating peer_id=$remote_peer_id reason=$reason"

    if ! wg set "$WG_INTERFACE" peer "$remote_pubkey" remove; then
        log warn "wg set deactivate failed peer_id=$remote_peer_id"
        return 1
    fi

    cache_clear_activation_started "$remote_peer_id" || true
    cache_set_state "$remote_peer_id" "INACTIVE" || true
    if [ "$reason" != "peer-request" ]; then
        publish_control "$remote_peer_id" "deactivate" "peer-request" "$remote_pubkey"
    fi

    log info "deactivate peer_id=$remote_peer_id reason=$reason"
    return 0
}

# Function: handle_observation_message
# Purpose: Validate and ingest observation payload into local cache.
# Inputs: $1 = raw JSON payload string.
# Outputs: Updates cache; returns 0 for handled/ignored payload.
handle_observation_message() {
    local payload="$1"

    local peer_id="$(printf '%s' "$payload" | jq -r '.peer_id // empty')"
    local peer_pubkey="$(printf '%s' "$payload" | jq -r '.public_key // empty')"
    local endpoint="$(printf '%s' "$payload" | jq -r '.endpoint // empty')"
    local latest_hs="$(printf '%s' "$payload" | jq -r '.latest_handshake // 0')"
    local observed_at="$(printf '%s' "$payload" | jq -r '.observed_at // 0')"
    local observed_by="$(printf '%s' "$payload" | jq -r '.observed_by // empty')"
    local obs_iface="$(printf '%s' "$payload" | jq -r '.interface // empty')"

    [ -n "$peer_id" ] || return 0
    [ -n "$peer_pubkey" ] || return 0

    if ! verify_peer_binding "$peer_id" "$peer_pubkey"; then
        log warn "discard observation: peer_id/public_key mismatch peer_id=$peer_id"
        return 0
    fi

    cache_ensure_peer "$peer_id" "$peer_pubkey" || true
    cache_set_endpoint "$peer_id" "$peer_pubkey" "$endpoint" "$observed_by" "$obs_iface" "$latest_hs" "$observed_at" || true
}

# Function: handle_control_message
# Purpose: Validate incoming control payload and trigger peer action.
# Inputs: $1 = raw JSON payload string.
# Outputs: Performs activate/deactivate side effects; returns 0 for handled/ignored payload.
handle_control_message() {
    local payload="$1"

    if [ -n "$CONFIG_FILE" ]; then
        if config_reload; then
            log debug "reloaded config file (control path): $CONFIG_FILE"
        elif [ "$CONFIG_READY" != "1" ]; then
            log warn "control path: config not ready yet: $CONFIG_FILE; policy checks skipped for this message"
        else
            log warn "control path: using last valid config snapshot from $CONFIG_FILE"
        fi
    fi

    local msg_type="$(printf '%s' "$payload" | jq -r '.type // empty')"
    local source_peer_id="$(printf '%s' "$payload" | jq -r '.peer_id // empty')"
    local source_pubkey="$(printf '%s' "$payload" | jq -r '.public_key // empty')"
    local target_pubkey="$(printf '%s' "$payload" | jq -r '.target_public_key // empty')"
    local reason="$(printf '%s' "$payload" | jq -r '.reason // "remote-request"')"
    local family="$(printf '%s' "$payload" | jq -r '.family // "auto"')"

    case "$family" in
        ipv4|ipv6) ;;
        *) family="auto" ;;
    esac

    log debug "received control type=$msg_type from peer_id=$source_peer_id reason=$reason family=$family"

    [ -n "$msg_type" ] || return 0
    [ -n "$source_peer_id" ] || return 0
    [ -n "$source_pubkey" ] || return 0
    [ -n "$target_pubkey" ] || {
        log warn "discard control: missing target_public_key from peer_id=$source_peer_id"
        return 0
    }

    if ! verify_peer_binding "$source_peer_id" "$source_pubkey"; then
        log warn "discard control: peer_id/public_key mismatch peer_id=$source_peer_id"
        return 0
    fi

    if ! verify_peer_binding "$LOCAL_PEER_ID" "$target_pubkey"; then
        log warn "discard control: target_public_key does not match local peer_id local_peer_id=$LOCAL_PEER_ID"
        return 0
    fi

    if [ "$target_pubkey" != "$LOCAL_PUBLIC_KEY" ]; then
        log warn "discard control: target_public_key mismatch local public key local_peer_id=$LOCAL_PEER_ID"
        return 0
    fi

    if config_enforced && ! is_detector_peer_id "$source_peer_id"; then
        if ! config_has_peer "$source_peer_id"; then
            log warn "discard control: peer_id=$source_peer_id not present in $CONFIG_FILE"
            return 0
        fi

        local config_pubkey="$(config_get_peer_public_key "$source_peer_id")"
        if [ -z "$config_pubkey" ] || [ "$config_pubkey" != "$source_pubkey" ]; then
            log warn "discard control: config public_key mismatch peer_id=$source_peer_id"
            return 0
        fi
    fi

    cache_ensure_peer "$source_peer_id" "$source_pubkey" || true

    case "$msg_type" in
        activate)
            activate_peer "$source_peer_id" "$source_pubkey" "$reason" "$family"
            ;;
        deactivate)
            deactivate_peer "$source_peer_id" "$source_pubkey" "$reason"
            ;;
        *)
            log debug "ignore unknown control type=$msg_type"
            ;;
    esac
}

# Function: control_and_observation_subscriber_loop
# Purpose: Continuously consume MQTT control/observation streams and dispatch handlers.
# Inputs: Uses global topic prefix and local peer_id.
# Outputs: Long-running loop; retries on subscription disconnect.
control_and_observation_subscriber_loop() {
    local control_topic="$TOPIC_PREFIX/peer/$LOCAL_PEER_ID/control"
    local obs_topic="$TOPIC_PREFIX/peer/+/observation"

    log info "subscribing topics: $control_topic, $obs_topic"

    while true; do
        mqtt_subscribe_stream "$control_topic" "$obs_topic" | while IFS= read -r line; do
            local topic="${line%% *}"
            local payload="${line#* }"

            if [ "$topic" = "$control_topic" ]; then
                handle_control_message "$payload"
            else
                handle_observation_message "$payload"
            fi
        done

        log warn "mosquitto_sub exited, retrying in 3s"
        sleep 3
    done
}

# Function: ensure_local_peer_record
# Purpose: Ensure local peer metadata exists in cache.
# Inputs: Uses LOCAL_PEER_ID and LOCAL_PUBLIC_KEY globals.
# Outputs: Updates cache entry if needed.
ensure_local_peer_record() {
    cache_ensure_peer "$LOCAL_PEER_ID" "$LOCAL_PUBLIC_KEY" || true
}

# Function: reconcile_peer_state
# Purpose: Compute peer state machine from wg runtime data and drive activation.
# Inputs: $1 = peer public key, $2 = endpoint, $3 = latest_handshake, $4 = current handshake age, $5 = persistent_keepalive.
# Outputs: Updates cache state and may trigger activate_peer.
reconcile_peer_state() {
    local peer_pubkey="$1"
    local endpoint="$2"
    local latest_hs="$3"
    local hs_age="$4"
    local keepalive="$5"

    local now_epoch="$(date -u +%s)"
    local peer_id="$(calc_peer_id "$peer_pubkey")"

    local state="IDLE"

    if [ "$latest_hs" -gt 0 ] && [ "$hs_age" -lt "$ENDPOINT_TIMEOUT" ]; then
        state="CONNECTED"
    elif [ "$latest_hs" -gt 0 ] && [ "$hs_age" -ge "$ENDPOINT_TIMEOUT" ]; then
        state="STALE"
    else
        if [ "$endpoint" != "(none)" ] || { [ "$keepalive" != "off" ] && [ "$keepalive" != "0" ]; }; then
            local started="$(cache_get_num "$peer_id" "activation_started_at")"
            if [ "$started" -gt 0 ] && [ $((now_epoch - started)) -gt "$FAILED_TIMEOUT" ]; then
                state="FAILED"
            else
                state="ACTIVATING"
            fi
        else
            state="IDLE"
        fi
    fi

    cache_set_state "$peer_id" "$state" || true

    case "$state" in
        CONNECTED)
            cache_clear_activation_started "$peer_id" || true
            ;;
        IDLE|STALE|FAILED)
            #activate_peer "$peer_id" "$peer_pubkey" "state-$state" || true
            ;;
        *)
            ;;
    esac
}

# Function: peer_sync_loop
# Purpose: Periodically sync peer state from one wg dump, then publish observations.
# Inputs: Uses STATE_INTERVAL and WG interface dump output.
# Outputs: Long-running loop that updates cache, reconciles state, and publishes observation.
peer_sync_loop() {
    while true; do
        if [ -n "$CONFIG_FILE" ]; then
            if config_reload; then
                log debug "reloaded config file: $CONFIG_FILE"
            elif [ "$CONFIG_READY" != "1" ]; then
                log warn "config not ready yet: $CONFIG_FILE; policy checks skipped for this cycle"
            else
                log warn "using last valid config snapshot from $CONFIG_FILE"
            fi
        fi

        ensure_local_peer_record

        now_epoch="$(date -u +%s)"

        wg show "$WG_INTERFACE" dump | tail -n +2 | while IFS="$(printf '\t')" read -r peer_pubkey _psk endpoint _allowed latest_hs _rx _tx keepalive; do
            [ -n "$peer_pubkey" ] || continue

            peer_id="$(calc_peer_id "$peer_pubkey")"

            [ -n "$latest_hs" ] || latest_hs="0"
            [ -n "$keepalive" ] || keepalive="off"

            if [ "$latest_hs" -gt 0 ]; then
                hs_age=$((now_epoch - latest_hs))
            else
                hs_age=0
            fi

            cache_ensure_peer "$peer_id" "$peer_pubkey" || true
            if [ -n "$endpoint" ] && [ "$endpoint" != "(none)" ]; then
                cache_set_endpoint "$peer_id" "$peer_pubkey" "$endpoint" "$LOCAL_PEER_ID" "$WG_INTERFACE" "$latest_hs" "$now_epoch" || true
            fi

            reconcile_peer_state "$peer_pubkey" "$endpoint" "$latest_hs" "$hs_age" "$keepalive"

            if [ "$latest_hs" -gt 0 ] && [ "$hs_age" -lt "$ENDPOINT_TIMEOUT" ]; then
                publish_observation_for_peer "$peer_pubkey" "$peer_id" "$endpoint" "$latest_hs" "$now_epoch"
            fi
        done

        if [ -n "$EXPLICIT_ENDPOINT" ] && [ "$EXPLICIT_ENDPOINT" != "none" ]; then
            publish_observation_for_peer "$LOCAL_PUBLIC_KEY" "$LOCAL_PEER_ID" "$EXPLICIT_ENDPOINT" "0" "$now_epoch"
        fi

        enforce_config_allowlist

        auto_activate_configured_peers

        if [ -n "$DETECTOR_PEER_IDS" ]; then
            split_detector_peer_ids "$DETECTOR_PEER_IDS" | while IFS= read -r detector_peer_id; do
                #log debug "checking detector peer_id=$detector_peer_id"
                detector_pubkey="$(cache_get_str "$detector_peer_id" "public_key")"
                if [ -n "$detector_pubkey" ]; then
                    detector_state="$(cache_get_str "$detector_peer_id" "state")"

                    if [ -z "$detector_state" ] || [ "$detector_state" = "INACTIVE" ]  || ! wg show "$WG_INTERFACE" peers | grep -Fxq "$detector_pubkey"; then
                        log debug "detector check: peer_id=$detector_peer_id state=$detector_state, activating for endpoint detection"
                        activate_peer "$detector_peer_id" "$detector_pubkey" "endpoint-detection" || true
                    elif [ "$detector_state" = "CONNECTED" ] || [ "$detector_state" = "ACTIVATING" ]; then
                        :
                    else
                        log debug "detector check: peer_id=$detector_peer_id state=$detector_state, deactivating"
                        deactivate_peer "$detector_peer_id" "$detector_pubkey" "endpoint-detection" || true
                    fi
                fi
            done
        fi

        sleep "$STATE_INTERVAL"
    done
}

# Function: cleanup
# Purpose: Stop background loops and release cache lock on process exit.
# Inputs: Uses stored background PIDs and lock path globals.
# Outputs: Sends termination signals; performs cleanup side effects.
cleanup() {
    log info "stopping $APP_NAME"

    RUNNING="0"

    if [ -n "$PID_CONTROL" ]; then
        kill "$PID_CONTROL" 2>/dev/null || true
    fi
    if [ -n "$PID_SYNC" ]; then
        kill "$PID_SYNC" 2>/dev/null || true
    fi

    cache_unlock
}

# Function: handle_termination
# Purpose: Handle TERM/INT by stopping children and exiting cleanly.
# Inputs: Signal name as $1.
# Outputs: Performs cleanup and exits 0.
handle_termination() {
    local sig="$1"
    log info "received signal: $sig"
    cleanup
    exit 0
}

# Function: main
# Purpose: Entry point that initializes config, validates environment, and starts worker loops.
# Inputs: CLI arguments ($@).
# Outputs: Starts background workers and waits until process termination.
main() {
    parse_args "$@"
    validate_args
    setup_dependencies

    wg show "$WG_INTERFACE" >/dev/null 2>&1 || die "WireGuard interface not found: $WG_INTERFACE"

    LOCAL_PUBLIC_KEY="$(wg show "$WG_INTERFACE" public-key 2>/dev/null)"
    [ -n "$LOCAL_PUBLIC_KEY" ] || die "failed to read local public key from interface $WG_INTERFACE"

    LOCAL_PEER_ID="$(calc_peer_id "$LOCAL_PUBLIC_KEY")"
    [ -n "$LOCAL_PEER_ID" ] || die "failed to calculate local peer_id"

    cache_init
    ensure_local_peer_record

    if [ -n "$CONFIG_FILE" ]; then
        if config_reload; then
            log debug "initial config load: $CONFIG_FILE"
        else
            log warn "initial config load failed: $CONFIG_FILE; policy checks may be skipped until reload succeeds"
        fi
    fi

    if [ -n "$EXPLICIT_ENDPOINT" ] && [ "$EXPLICIT_ENDPOINT" != "none" ]; then
        cache_set_endpoint "$LOCAL_PEER_ID" "$LOCAL_PUBLIC_KEY" "$EXPLICIT_ENDPOINT" "$LOCAL_PEER_ID" "$WG_INTERFACE" "0" "$(date -u +%s)" || true
    fi

    trap 'handle_termination INT' INT
    trap 'handle_termination TERM' TERM

    control_and_observation_subscriber_loop &
    PID_CONTROL="$!"

    peer_sync_loop &
    PID_SYNC="$!"

    log info "$APP_NAME started iface=$WG_INTERFACE local_peer_id=$LOCAL_PEER_ID cache=$CACHE_FILE"

    while [ "$RUNNING" = "1" ]; do
        kill -0 "$PID_CONTROL" 2>/dev/null || break
        kill -0 "$PID_SYNC" 2>/dev/null || break
        sleep 1
    done

    cleanup
}

main "$@"
