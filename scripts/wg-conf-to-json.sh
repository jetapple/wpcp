#!/bin/sh

# wg-conf-to-json.sh
# Reads WireGuard configuration from the current system and writes
# structured JSON to /tmp/wg.conf.json.
#
# Supported platforms:
#   - Linux:   /etc/wireguard/*.conf
#   - OpenWRT: UCI (uci show network)
#
# Output format:
#   {
#     "<ifname>": {
#       "<peer_id>": {
#         "public_key": "...",
#         "allowed_ips": ["..."],
#         "endpoint": "...",          # omitted if absent
#         "persistent_keepalive": N   # omitted if absent
#       }
#     }
#   }
#
# peer_id = base32_lowercase( sha256(public_key)[0:16] )

set -u

OUTPUT_FILE="/tmp/wg.conf.json"

usage() {
    cat <<EOF
Usage: wg-conf-to-json.sh [options]

Options:
  -o, --output PATH   Output JSON path (default: /tmp/wg.conf.json)
  -h, --help          Show this help and exit

This script auto-detects platform and reads WireGuard peer config from:
  - Linux:   /etc/wireguard/*.conf
  - OpenWRT: UCI network config
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'error: unknown option: %s\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# calc_peer_id <public_key>
# Derive deterministic peer_id from a WireGuard public key.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# parse_linux_conf <conf_file>
# Parse a single /etc/wireguard/*.conf file and print newline-delimited
# JSON objects, one per [Peer] block, to stdout.
# Each line: {"ifname":"wg0","peer_id":"...","obj":{...}}
# ---------------------------------------------------------------------------
parse_linux_conf() {
    conf="$1"
    ifname="$(basename "$conf" .conf)"

    in_peer=0
    pubkey=""
    allowed_ips=""
    endpoint=""
    keepalive=""
    description=""

    # Flush the accumulated peer block as a JSON line
    flush_peer() {
        [ -z "$pubkey" ] && return
        peer_id="$(calc_peer_id "$pubkey")"
        [ -z "$peer_id" ] && return

        # Build allowed_ips JSON array from comma-separated values.
        # Use jq split/map so empty input is safely converted to [] without stderr noise.
        ips_json="$(jq -cn --arg ips "$allowed_ips" '($ips | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0)))')"

        obj="$(jq -cn \
            --arg pk "$pubkey" \
            --argjson ips "$ips_json" \
            --arg ep "$endpoint" \
            --arg ka "$keepalive" \
            --arg desc "$description" \
            '{public_key:$pk, allowed_ips:$ips}
             + (if $ep != "" then {endpoint:$ep} else {} end)
             + (if $ka != "" then {persistent_keepalive:($ka|tonumber)} else {} end)
             + (if $desc != "" then {description:$desc} else {} end)')"

        printf '%s\n' "$(jq -cn \
            --arg ifname "$ifname" \
            --arg pid "$peer_id" \
            --argjson obj "$obj" \
            '{ifname:$ifname,peer_id:$pid,obj:$obj}')"
    }

    while IFS= read -r line || [ -n "$line" ]; do
        # Strip inline comments and leading/trailing whitespace
        line="$(printf '%s' "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue

        case "$line" in
            \[Peer\]|\[peer\])
                flush_peer
                in_peer=1
                pubkey=""
                allowed_ips=""
                endpoint=""
                keepalive=""
                description=""
                ;;
            \[*)
                flush_peer
                in_peer=0
                pubkey=""
                allowed_ips=""
                endpoint=""
                keepalive=""
                description=""
                ;;
            *)
                [ "$in_peer" = "0" ] && continue
                key="$(printf '%s' "$line" | cut -d= -f1 | sed 's/[[:space:]]*$//')"
                val="$(printf '%s' "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//')"
                case "$key" in
                    PublicKey)           pubkey="$val" ;;
                    AllowedIPs)
                        if [ -z "$allowed_ips" ]; then
                            allowed_ips="$val"
                        else
                            allowed_ips="${allowed_ips},${val}"
                        fi
                        ;;
                    Endpoint)            endpoint="$val" ;;
                    PersistentKeepalive) keepalive="$val" ;;
                    Description|description) description="$val" ;;
                esac
                ;;
        esac
    done < "$conf"

    flush_peer
}

# ---------------------------------------------------------------------------
# collect_linux
# Iterate all /etc/wireguard/*.conf files and print peer JSON lines.
# ---------------------------------------------------------------------------
collect_linux() {
    found=0
    for conf in /etc/wireguard/*.conf; do
        [ -f "$conf" ] || continue
        found=1
        ifname="$(basename "$conf" .conf)"
        printf '%s\n' "$(jq -cn --arg ifname "$ifname" '{ifname:$ifname}')"
        parse_linux_conf "$conf"
    done
    [ "$found" = "0" ] && printf 'warn: no .conf files found in /etc/wireguard/\n' >&2
}

# ---------------------------------------------------------------------------
# collect_openwrt
# Use UCI to read WireGuard interfaces and their peers; skip disabled peers.
# ---------------------------------------------------------------------------
collect_openwrt() {
    # Discover WireGuard interface names:
    # sections of type 'interface' whose proto option equals 'wireguard'
    uci_dump="$(uci show network 2>/dev/null)"

    uci_get_first() {
        key="$1"
        printf '%s\n' "$uci_dump" \
            | awk -v k="$key" '
                {
                    p = index($0, "=")
                    if (p <= 0) next
                    lk = substr($0, 1, p - 1)
                    if (lk == k) {
                        v = substr($0, p + 1)
                        gsub("\047", "", v)
                        print v
                        exit
                    }
                }
            '
    }

    uci_get_all() {
        key="$1"
        printf '%s\n' "$uci_dump" \
            | awk -v k="$key" '
                {
                    p = index($0, "=")
                    if (p <= 0) next
                    lk = substr($0, 1, p - 1)
                    if (lk == k) {
                        v = substr($0, p + 1)
                        gsub("\047", "", v)
                        print v
                    }
                }
            '
    }

    # network.<section>=interface  → check network.<section>.proto=wireguard
    echo "$uci_dump" | grep "=interface$" | while IFS= read -r iface_line; do
        section="$(printf '%s' "$iface_line" | cut -d= -f1)"   # network.<s>
        proto_val="$(uci_get_first "${section}.proto")"
        [ "$proto_val" = "wireguard" ] || continue
        # The actual Linux interface name may be set via option ifname or defaults to section name
        ifname_val="$(uci_get_first "${section}.ifname")"
        if [ -z "$ifname_val" ]; then
            # Default: UCI section name (strip 'network.' prefix)
            ifname_val="$(printf '%s' "$section" | sed 's/^network\.//')"
        fi
        printf '%s\n' "$ifname_val"
    done | sort -u | while IFS= read -r ifname; do
        printf '%s\n' "$(jq -cn --arg ifname "$ifname" '{ifname:$ifname}')"

        # Find peer sections: type 'wireguard_<ifname>'
        section_type="wireguard_${ifname}"
        echo "$uci_dump" | grep "=${section_type}$" | while IFS= read -r peer_line; do
            peer_section="$(printf '%s' "$peer_line" | cut -d= -f1)"  # network.<ps>

            # Skip disabled peers
            disabled_val="$(uci_get_first "${peer_section}.disabled")"
            case "$disabled_val" in
                1|true|yes|on) continue ;;
            esac

            pubkey="$(uci_get_first "${peer_section}.public_key")"
            [ -z "$pubkey" ] && continue

            peer_id="$(calc_peer_id "$pubkey")"
            [ -z "$peer_id" ] && continue

            # Collect allowed_ips list entries
            ips_json="$(uci_get_all "${peer_section}.allowed_ips" | jq -Rsc 'split("\n") | map(select(length > 0))')"
            [ -z "$ips_json" ] && ips_json="[]"

            ep_host="$(uci_get_first "${peer_section}.endpoint_host")"
            ep_port="$(uci_get_first "${peer_section}.endpoint_port")"
            endpoint=""
            if [ -n "$ep_host" ] && [ -n "$ep_port" ]; then
                # IPv6 host needs brackets
                case "$ep_host" in
                    *:*) endpoint="[${ep_host}]:${ep_port}" ;;
                    *)   endpoint="${ep_host}:${ep_port}" ;;
                esac
            fi

            keepalive="$(uci_get_first "${peer_section}.persistent_keepalive")"
            description="$(uci_get_first "${peer_section}.description")"

            obj="$(jq -cn \
                --arg pk "$pubkey" \
                --argjson ips "$ips_json" \
                --arg ep "$endpoint" \
                --arg ka "$keepalive" \
                --arg desc "$description" \
                '{public_key:$pk, allowed_ips:$ips}
                 + (if $ep != "" then {endpoint:$ep} else {} end)
                 + (if $ka != "" then {persistent_keepalive:($ka|tonumber)} else {} end)
                 + (if $desc != "" then {description:$desc} else {} end)')"

            printf '%s\n' "$(jq -cn \
                --arg ifname "$ifname" \
                --arg pid "$peer_id" \
                --argjson obj "$obj" \
                '{ifname:$ifname,peer_id:$pid,obj:$obj}')"
        done
    done
}

# ---------------------------------------------------------------------------
# detect_platform
# Outputs "openwrt" or "linux".
# ---------------------------------------------------------------------------
detect_platform() {
    if [ -f /etc/openwrt_release ] || command -v uci >/dev/null 2>&1; then
        printf 'openwrt'
    else
        printf 'linux'
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    command -v jq      >/dev/null 2>&1 || { printf 'error: jq is required\n' >&2; exit 1; }
    command -v base32  >/dev/null 2>&1 || { printf 'error: base32 is required\n' >&2; exit 1; }
    if ! command -v openssl >/dev/null 2>&1 && ! command -v xxd >/dev/null 2>&1; then
        printf 'error: openssl or xxd is required for peer_id calculation\n' >&2
        exit 1
    fi

    platform="$(detect_platform)"

    # Collect all peer lines, then aggregate into final JSON
    tmp_lines="$(mktemp)"
    trap 'rm -f "$tmp_lines"' EXIT

    if [ "$platform" = "openwrt" ]; then
        collect_openwrt > "$tmp_lines"
    else
        collect_linux > "$tmp_lines"
    fi

    # Aggregate: fold all {ifname, peer_id, obj} lines into nested JSON
    result="$(jq -sc '
        reduce .[] as $e (
            {};
            if ($e | has("peer_id")) and ($e | has("obj")) then
                .[$e.ifname] = ((.[$e.ifname] // {}) + {($e.peer_id): $e.obj})
            else
                .[$e.ifname] = (.[$e.ifname] // {})
            end
        )
    ' "$tmp_lines")"

    tmp_out="$(mktemp)"
    printf '%s\n' "$result" > "$tmp_out"
    mv "$tmp_out" "$OUTPUT_FILE"

    printf 'written: %s\n' "$OUTPUT_FILE"
}

main "$@"
