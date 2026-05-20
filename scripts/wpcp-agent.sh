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
    case "$1" in
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
    level="$1"
    shift
    cur_n="$(log_level_num "$LOG_LEVEL")"
    msg_n="$(log_level_num "$level")"
    if [ "$msg_n" -ge "$cur_n" ]; then
        if [ "${WPCP_LOG_NO_TS:-0}" = "1" ]; then
            printf '[%s] [%s] %s\n' "$WG_INTERFACE" "$level" "$*"
        else
            now_ts="$(date '+%Y-%m-%d %H:%M:%S')"
            printf '%s [%s] [%s] %s\n' "$now_ts" "$WG_INTERFACE" "$level" "$*"
        fi
    fi
}

# Function: die
# Purpose: Log an error and terminate the process.
# Inputs: $1..$n = error message text.
# Outputs: Writes error log and exits with status 1.
die() {
    log error "$*"
    exit 1
}

# Function: require_cmd
# Purpose: Ensure a required external command exists in PATH.
# Inputs: $1 = command name.
# Outputs: No stdout on success; exits on missing command.
require_cmd() {
    cmd="$1"
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
        case "$1" in
            -i|--interface)
                WG_INTERFACE="$2"
                shift 2
                ;;
            -b|--broker)
                MQTT_BROKER="$2"
                shift 2
                ;;
            -p|--port)
                MQTT_PORT="$2"
                shift 2
                ;;
            --username)
                MQTT_USERNAME="$2"
                shift 2
                ;;
            --password)
                MQTT_PASSWORD="$2"
                shift 2
                ;;
            --tls)
                MQTT_TLS="$2"
                shift 2
                ;;
            --cafile)
                MQTT_CAFILE="$2"
                shift 2
                ;;
            --cert)
                MQTT_CERT="$2"
                shift 2
                ;;
            --key)
                MQTT_KEY="$2"
                shift 2
                ;;
            --topic-prefix)
                TOPIC_PREFIX="$2"
                shift 2
                ;;
            --state-interval)
                STATE_INTERVAL="$2"
                shift 2
                ;;
            --endpoint-timeout)
                ENDPOINT_TIMEOUT="$2"
                shift 2
                ;;
            --failed-timeout)
                FAILED_TIMEOUT="$2"
                shift 2
                ;;
            --keepalive-active)
                KEEPALIVE_ACTIVE="$2"
                shift 2
                ;;
            -e|--endpoint)
                EXPLICIT_ENDPOINT="$2"
                shift 2
                ;;
            --qos-control)
                QOS_CONTROL="$2"
                shift 2
                ;;
            --qos-observation)
                QOS_OBSERVATION="$2"
                shift 2
                ;;
            --cache-file)
                CACHE_FILE="$2"
                shift 2
                ;;
            --log-level)
                LOG_LEVEL="$2"
                shift 2
                ;;
            -d|--detector)
                DETECTOR_PEER_IDS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
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
    pubkey="$1"

    if command -v openssl >/dev/null 2>&1; then
        printf '%s' "$pubkey" \
            | openssl dgst -sha256 -binary 2>/dev/null \
            | dd bs=1 count=16 2>/dev/null \
            | base32 2>/dev/null \
            | tr -d '=\n' \
            | tr 'A-Z' 'a-z'
        return 0
    fi

    hash32="$(printf '%s' "$pubkey" | sha256sum | awk '{print $1}' | cut -c1-32)"
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
    jq_filter="$1"
    shift

    tmp_file="${CACHE_FILE}.tmp"

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
    pid="$1"
    key="$2"
    jq -r --arg pid "$pid" --arg key "$key" '.peers[$pid][$key] // ""' "$CACHE_FILE" 2>/dev/null
}

# Function: cache_get_num
# Purpose: Read a numeric field from a peer record in cache.
# Inputs: $1 = peer_id, $2 = field name.
# Outputs: Echoes numeric value or 0.
cache_get_num() {
    pid="$1"
    key="$2"
    jq -r --arg pid "$pid" --arg key "$key" '.peers[$pid][$key] // 0' "$CACHE_FILE" 2>/dev/null
}

# Function: detect_endpoint_family
# Purpose: Classify endpoint string as ipv4/ipv6/none/unknown.
# Inputs: $1 = endpoint string from wg or observation.
# Outputs: Echoes endpoint family label.
detect_endpoint_family() {
    endpoint="$1"

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

    colon_count="$(printf '%s' "$endpoint" | tr -cd ':' | wc -c | awk '{print $1}')"
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
    detector_raw="$1"

    [ -n "$detector_raw" ] || return 0

        printf '%s\n' "$detector_raw" | tr ',' '\n' | while IFS= read -r detector_peer_id; do
        detector_peer_id="$(printf '%s' "$detector_peer_id" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$detector_peer_id" ] || continue
        printf '%s\n' "$detector_peer_id"
    done
}

# Function: cache_ensure_peer
# Purpose: Ensure a peer object exists and refresh base metadata.
# Inputs: $1 = peer_id, $2 = public key.
# Outputs: Returns cache_update_with_jq status.
cache_ensure_peer() {
    pid="$1"
    pubkey="$2"
    now_epoch="$(date +%s)"

    cache_update_with_jq \
        --arg pid "$pid" \
        --arg pubkey "$pubkey" \
        --argjson now "$now_epoch" \
        '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, updated_at:$now})'
}

    # Function: cache_set_endpoint
    # Purpose: Save peer endpoint and handshake metadata into cache.
    # Inputs: $1 = peer_id, $2 = public key, $3 = endpoint, $4 = observed_by, $5 = interface, $6 = latest_handshake, $7 = handshake_age.
    # Outputs: Returns cache_update_with_jq status.
cache_set_endpoint() {
    pid="$1"
    pubkey="$2"
    endpoint="$3"
    observed_by="$4"
    obs_iface="$5"
    latest_hs="$6"
    handshake_age="$7"

    family="$(detect_endpoint_family "$endpoint")"
    now_epoch="$(date +%s)"

    if [ "$family" = "ipv4" ]; then
        cache_update_with_jq \
            --arg pid "$pid" \
            --arg pubkey "$pubkey" \
            --arg endpoint "$endpoint" \
            --arg observed_by "$observed_by" \
            --arg obs_iface "$obs_iface" \
            --argjson latest_hs "$latest_hs" \
            --argjson hs_age "$handshake_age" \
            --argjson now "$now_epoch" \
            '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, endpoint_v4:$endpoint, observed_by:$observed_by, interface:$obs_iface, latest_handshake:$latest_hs, handshake_age:$hs_age, updated_at:$now})'
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
            --argjson hs_age "$handshake_age" \
            --argjson now "$now_epoch" \
            '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, endpoint_v6:$endpoint, observed_by:$observed_by, interface:$obs_iface, latest_handshake:$latest_hs, handshake_age:$hs_age, updated_at:$now})'
        return
    fi

    cache_update_with_jq \
        --arg pid "$pid" \
        --arg pubkey "$pubkey" \
        --arg observed_by "$observed_by" \
        --arg obs_iface "$obs_iface" \
        --argjson latest_hs "$latest_hs" \
        --argjson hs_age "$handshake_age" \
        --argjson now "$now_epoch" \
        '.peers[$pid] = ((.peers[$pid] // {}) + {public_key:$pubkey, observed_by:$observed_by, interface:$obs_iface, latest_handshake:$latest_hs, handshake_age:$hs_age, updated_at:$now})'
}

# Function: cache_set_activation_started
# Purpose: Record activation start timestamp for a peer.
# Inputs: $1 = peer_id.
# Outputs: Returns cache_update_with_jq status.
cache_set_activation_started() {
    pid="$1"
    now_epoch="$(date +%s)"
    cache_update_with_jq --arg pid "$pid" --argjson now "$now_epoch" '.peers[$pid] = ((.peers[$pid] // {}) + {activation_started_at:$now})'
}

# Function: cache_clear_activation_started
# Purpose: Remove activation start timestamp from a peer record.
# Inputs: $1 = peer_id.
# Outputs: Returns cache_update_with_jq status.
cache_clear_activation_started() {
    pid="$1"
    cache_update_with_jq --arg pid "$pid" '.peers[$pid] = ((.peers[$pid] // {}) | del(.activation_started_at))'
}

# Function: cache_set_state
# Purpose: Persist current FSM state and state update time for a peer.
# Inputs: $1 = peer_id, $2 = state string.
# Outputs: Returns cache_update_with_jq status.
cache_set_state() {
    pid="$1"
    state="$2"
    now_epoch="$(date +%s)"
    cache_update_with_jq --arg pid "$pid" --arg state "$state" --argjson now "$now_epoch" '.peers[$pid] = ((.peers[$pid] // {}) + {state:$state, state_updated_at:$now})'
}

# Function: cache_get_endpoint_v4
# Purpose: Get cached IPv4 endpoint for a peer.
# Inputs: $1 = peer_id.
# Outputs: Echoes endpoint string or empty.
cache_get_endpoint_v4() {
    pid="$1"
    cache_get_str "$pid" "endpoint_v4"
}

# Function: cache_get_endpoint_v6
# Purpose: Get cached IPv6 endpoint for a peer.
# Inputs: $1 = peer_id.
# Outputs: Echoes endpoint string or empty.
cache_get_endpoint_v6() {
    pid="$1"
    cache_get_str "$pid" "endpoint_v6"
}

# Function: mqtt_pub
# Purpose: Publish one MQTT message with configured auth/TLS options.
# Inputs: $1 = topic, $2 = payload, $3 = qos.
# Outputs: Forwards mosquitto_pub exit status.
mqtt_pub() {
    topic="$1"
    payload="$2"
    qos="$3"

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
    control_topic="$1"
    obs_topic="$2"

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
# Inputs: $1 = target peer_id, $2 = message type.
# Outputs: Sends MQTT message; logs warning on failure.
publish_control() {
    target_peer_id="$1"
    msg_type="$2"

    topic="$TOPIC_PREFIX/peer/$target_peer_id/control"
    payload="$(jq -cn --arg t "$msg_type" --arg pid "$LOCAL_PEER_ID" --arg pk "$LOCAL_PUBLIC_KEY" '{type:$t,peer_id:$pid,public_key:$pk}')"
    mqtt_pub "$topic" "$payload" "$QOS_CONTROL" >/dev/null 2>&1 || log warn "failed to publish $msg_type to $topic"
}

# Function: publish_observation_for_peer
# Purpose: Publish endpoint/handshake observation payload for one peer.
# Inputs: $1 = peer public key, $2 = peer_id, $3 = endpoint, $4 = latest_handshake, $5 = handshake_age.
# Outputs: Sends MQTT message; logs warning on failure.
publish_observation_for_peer() {
    peer_pubkey="$1"
    peer_id="$2"
    endpoint="$3"
    latest_hs="$4"
    handshake_age="$5"

    family="$(detect_endpoint_family "$endpoint")"
    cached_v4="$(cache_get_endpoint_v4 "$peer_id")"
    cached_v6="$(cache_get_endpoint_v6 "$peer_id")"

    payload="$(jq -cn \
        --arg t "observation" \
        --arg pid "$peer_id" \
        --arg pk "$peer_pubkey" \
        --arg endpoint "$endpoint" \
        --arg family "$family" \
        --arg endpoint_v4 "$cached_v4" \
        --arg endpoint_v6 "$cached_v6" \
        --arg observed_by "$LOCAL_PEER_ID" \
        --arg iface "$WG_INTERFACE" \
        --argjson latest "$latest_hs" \
        --argjson hs_age "$handshake_age" \
        '{type:$t,peer_id:$pid,public_key:$pk,endpoint:$endpoint,endpoint_family:$family,endpoint_v4:$endpoint_v4,endpoint_v6:$endpoint_v6,latest_handshake:$latest,handshake_age:$hs_age,observed_by:$observed_by,interface:$iface}')"

    topic="$TOPIC_PREFIX/peer/$peer_id/observation"
    mqtt_pub "$topic" "$payload" "$QOS_OBSERVATION" >/dev/null 2>&1 || log warn "failed to publish observation for peer_id=$peer_id"
}

# Function: verify_peer_binding
# Purpose: Verify peer_id matches the hash of the provided public key.
# Inputs: $1 = peer_id, $2 = public key.
# Outputs: Returns success when binding is valid.
verify_peer_binding() {
    peer_id="$1"
    pubkey="$2"

    calc_id="$(calc_peer_id "$pubkey")"
    [ "$calc_id" = "$peer_id" ]
}

# Function: select_activation_endpoint
# Purpose: Pick best endpoint for activation, preferring IPv6 dual-stack path.
# Inputs: $1 = remote peer_id.
# Outputs: Echoes selected endpoint or empty string.
select_activation_endpoint() {
    remote_peer_id="$1"

    local_v6="$(cache_get_endpoint_v6 "$LOCAL_PEER_ID")"
    remote_v6="$(cache_get_endpoint_v6 "$remote_peer_id")"
    remote_v4="$(cache_get_endpoint_v4 "$remote_peer_id")"

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
# Inputs: $1 = remote peer_id, $2 = remote public key, $3 = reason.
# Outputs: Returns 0 on success, 1 on activation failure.
activate_peer() {
    remote_peer_id="$1"
    remote_pubkey="$2"
    reason="$3"

    endpoint="$(select_activation_endpoint "$remote_peer_id")"

    if [ -n "$endpoint" ]; then
        if ! wg set "$WG_INTERFACE" peer "$remote_pubkey" endpoint "$endpoint" persistent-keepalive "$KEEPALIVE_ACTIVE"; then
            log warn "wg set activate failed peer_id=$remote_peer_id endpoint=$endpoint"
            return 1
        fi
    else
        log debug "activate peer_id=$remote_peer_id: no endpoint in cache, adding peer without endpoint"
        if ! wg set "$WG_INTERFACE" peer "$remote_pubkey"; then
            log warn "wg set activate failed peer_id=$remote_peer_id (no endpoint)"
            return 1
        fi
    fi

    cache_set_activation_started "$remote_peer_id" || true
    cache_set_state "$remote_peer_id" "ACTIVATING" || true
    if [ "$reason" != "remote-request" ]; then
        publish_control "$remote_peer_id" "activate"
    fi

    log info "activate peer_id=$remote_peer_id endpoint=${endpoint:-none} reason=$reason"
    return 0
}

# Function: deactivate_peer
# Purpose: Remove wg peer config and emit deactivate control.
# Inputs: $1 = remote peer_id, $2 = remote public key, $3 = reason.
# Outputs: Returns 0 on success, 1 on deactivation failure.
deactivate_peer() {
    remote_peer_id="$1"
    remote_pubkey="$2"
    reason="$3"

    if ! wg set "$WG_INTERFACE" peer "$remote_pubkey" remove; then
        log warn "wg set deactivate failed peer_id=$remote_peer_id"
        return 1
    fi

    cache_clear_activation_started "$remote_peer_id" || true
    cache_set_state "$remote_peer_id" "INACTIVE" || true
    if [ "$reason" != "remote-request" ]; then
        publish_control "$remote_peer_id" "deactivate"
    fi

    log info "deactivate peer_id=$remote_peer_id reason=$reason"
    return 0
}

# Function: handle_observation_message
# Purpose: Validate and ingest observation payload into local cache.
# Inputs: $1 = raw JSON payload string.
# Outputs: Updates cache; returns 0 for handled/ignored payload.
handle_observation_message() {
    payload="$1"

    peer_id="$(printf '%s' "$payload" | jq -r '.peer_id // empty')"
    peer_pubkey="$(printf '%s' "$payload" | jq -r '.public_key // empty')"
    endpoint="$(printf '%s' "$payload" | jq -r '.endpoint // empty')"
    endpoint_v4="$(printf '%s' "$payload" | jq -r '.endpoint_v4 // empty')"
    endpoint_v6="$(printf '%s' "$payload" | jq -r '.endpoint_v6 // empty')"
    latest_hs="$(printf '%s' "$payload" | jq -r '.latest_handshake // 0')"
    hs_age="$(printf '%s' "$payload" | jq -r '.handshake_age // 0')"
    observed_by="$(printf '%s' "$payload" | jq -r '.observed_by // empty')"
    obs_iface="$(printf '%s' "$payload" | jq -r '.interface // empty')"

    [ -n "$peer_id" ] || return 0
    [ -n "$peer_pubkey" ] || return 0

    if ! verify_peer_binding "$peer_id" "$peer_pubkey"; then
        log warn "discard observation: peer_id/public_key mismatch peer_id=$peer_id"
        return 0
    fi

    cache_ensure_peer "$peer_id" "$peer_pubkey" || true

    if [ -n "$endpoint_v4" ]; then
        cache_set_endpoint "$peer_id" "$peer_pubkey" "$endpoint_v4" "$observed_by" "$obs_iface" "$latest_hs" "$hs_age" || true
    fi
    if [ -n "$endpoint_v6" ]; then
        cache_set_endpoint "$peer_id" "$peer_pubkey" "$endpoint_v6" "$observed_by" "$obs_iface" "$latest_hs" "$hs_age" || true
    fi

    if [ -n "$endpoint" ]; then
        fam="$(detect_endpoint_family "$endpoint")"
        if [ "$fam" = "ipv4" ] || [ "$fam" = "ipv6" ]; then
            cache_set_endpoint "$peer_id" "$peer_pubkey" "$endpoint" "$observed_by" "$obs_iface" "$latest_hs" "$hs_age" || true
        fi
    fi
}

# Function: handle_control_message
# Purpose: Validate incoming control payload and trigger peer action.
# Inputs: $1 = raw JSON payload string.
# Outputs: Performs activate/deactivate side effects; returns 0 for handled/ignored payload.
handle_control_message() {
    payload="$1"

    msg_type="$(printf '%s' "$payload" | jq -r '.type // empty')"
    source_peer_id="$(printf '%s' "$payload" | jq -r '.peer_id // empty')"
    source_pubkey="$(printf '%s' "$payload" | jq -r '.public_key // empty')"

    [ -n "$msg_type" ] || return 0
    [ -n "$source_peer_id" ] || return 0
    [ -n "$source_pubkey" ] || return 0

    if ! verify_peer_binding "$source_peer_id" "$source_pubkey"; then
        log warn "discard control: peer_id/public_key mismatch peer_id=$source_peer_id"
        return 0
    fi

    cache_ensure_peer "$source_peer_id" "$source_pubkey" || true

    case "$msg_type" in
        activate)
            activate_peer "$source_peer_id" "$source_pubkey" "remote-request"
            ;;
        deactivate)
            deactivate_peer "$source_peer_id" "$source_pubkey" "remote-request"
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
    control_topic="$TOPIC_PREFIX/peer/$LOCAL_PEER_ID/control"
    obs_topic="$TOPIC_PREFIX/peer/+/observation"

    log info "subscribing topics: $control_topic, $obs_topic"

    while true; do
        mqtt_subscribe_stream "$control_topic" "$obs_topic" | while IFS= read -r line; do
            topic="${line%% *}"
            payload="${line#* }"

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
# Inputs: $1 = peer public key, $2 = endpoint, $3 = latest_handshake, $4 = handshake_age, $5 = persistent_keepalive.
# Outputs: Updates cache state and may trigger activate_peer.
reconcile_peer_state() {
    peer_pubkey="$1"
    endpoint="$2"
    latest_hs="$3"
    hs_age="$4"
    keepalive="$5"

    now_epoch="$(date +%s)"
    peer_id="$(calc_peer_id "$peer_pubkey")"

    state="IDLE"

    if [ "$latest_hs" -gt 0 ] && [ "$hs_age" -lt "$ENDPOINT_TIMEOUT" ]; then
        state="CONNECTED"
    elif [ "$latest_hs" -gt 0 ] && [ "$hs_age" -ge "$ENDPOINT_TIMEOUT" ]; then
        state="STALE"
    else
        if [ "$endpoint" != "(none)" ] || { [ "$keepalive" != "off" ] && [ "$keepalive" != "0" ]; }; then
            started="$(cache_get_num "$peer_id" "activation_started_at")"
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
        ensure_local_peer_record

        now_epoch="$(date +%s)"

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
                cache_set_endpoint "$peer_id" "$peer_pubkey" "$endpoint" "$LOCAL_PEER_ID" "$WG_INTERFACE" "$latest_hs" "$hs_age" || true
            fi

            reconcile_peer_state "$peer_pubkey" "$endpoint" "$latest_hs" "$hs_age" "$keepalive"

            if [ "$latest_hs" -gt 0 ] && [ "$hs_age" -lt "$ENDPOINT_TIMEOUT" ]; then
                publish_observation_for_peer "$peer_pubkey" "$peer_id" "$endpoint" "$latest_hs" "$hs_age"
            fi
        done

        if [ -n "$EXPLICIT_ENDPOINT" ] && [ "$EXPLICIT_ENDPOINT" != "none" ]; then
            publish_observation_for_peer "$LOCAL_PUBLIC_KEY" "$LOCAL_PEER_ID" "$EXPLICIT_ENDPOINT" "0" "0"
        fi

        if [ -n "$DETECTOR_PEER_IDS" ]; then
            split_detector_peer_ids "$DETECTOR_PEER_IDS" | while IFS= read -r detector_peer_id; do
                log debug "checking detector peer_id=$detector_peer_id"
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
    sig="$1"
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

    if [ -n "$EXPLICIT_ENDPOINT" ] && [ "$EXPLICIT_ENDPOINT" != "none" ]; then
        cache_set_endpoint "$LOCAL_PEER_ID" "$LOCAL_PUBLIC_KEY" "$EXPLICIT_ENDPOINT" "$LOCAL_PEER_ID" "$WG_INTERFACE" "0" "0" || true
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
