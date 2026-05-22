#!/bin/sh

# wg-conf-to-json.sh
# Reads WireGuard configuration from the current system and outputs
# structured JSON to stdout by default. If -o/--output is provided,
# JSON is written to the specified file.
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

OUTPUT_FILE=""

usage() {
    cat <<EOF
Usage: wg-conf-to-json.sh [options]

Options:
  -o, --output PATH   Output JSON path (if omitted, print JSON to stdout)
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
    # One-pass UCI parsing to avoid repeated scans and per-field awk processes.
    uci_dump="$(uci show network 2>/dev/null)"
    field_sep="$(printf '\036')"
    col_sep="$(printf '\037')"

    printf '%s\n' "$uci_dump" | awk -v FSSEP="$field_sep" -v COLSEP="$col_sep" '
        BEGIN {
            prefix = "network."
            pfxlen = length(prefix)
        }
        {
            p = index($0, "=")
            if (p <= 0) next

            key = substr($0, 1, p - 1)
            val = substr($0, p + 1)
            gsub("\047", "", val)

            if (index(key, prefix) != 1) next
            rest = substr(key, pfxlen + 1)
            dot = index(rest, ".")

            if (dot == 0) {
                sec = rest
                section_type[sec] = val
                section_order[++section_count] = sec
            } else {
                sec = substr(rest, 1, dot - 1)
                opt = substr(rest, dot + 1)
                k = sec SUBSEP opt
                if (opt == "allowed_ips") {
                    if (k in section_opt && section_opt[k] != "") {
                        section_opt[k] = section_opt[k] FSSEP val
                    } else {
                        section_opt[k] = val
                    }
                } else {
                    section_opt[k] = val
                }
            }
        }
        END {
            # First pass: resolve wireguard interfaces and preserve discovery order
            for (i = 1; i <= section_count; i++) {
                sec = section_order[i]
                if (section_type[sec] != "interface") continue

                proto = section_opt[sec SUBSEP "proto"]
                if (proto != "wireguard") continue

                ifname = section_opt[sec SUBSEP "ifname"]
                if (ifname == "") ifname = sec

                if (!(ifname in iface_seen)) {
                    iface_seen[ifname] = 1
                    iface_order[++iface_count] = ifname
                    print "I" COLSEP ifname
                }
            }

            # Second pass: emit peer rows linked to existing wireguard interfaces
            for (i = 1; i <= section_count; i++) {
                sec = section_order[i]
                typ = section_type[sec]
                if (index(typ, "wireguard_") != 1) continue

                ifname = substr(typ, 11)
                if (!(ifname in iface_seen)) continue

                print "P" COLSEP ifname COLSEP \
                      section_opt[sec SUBSEP "public_key"] COLSEP \
                      section_opt[sec SUBSEP "disabled"] COLSEP \
                      section_opt[sec SUBSEP "endpoint_host"] COLSEP \
                      section_opt[sec SUBSEP "endpoint_port"] COLSEP \
                      section_opt[sec SUBSEP "persistent_keepalive"] COLSEP \
                      section_opt[sec SUBSEP "description"] COLSEP \
                      section_opt[sec SUBSEP "allowed_ips"]
            }
        }
    ' | while IFS="$col_sep" read -r rec_type ifname pubkey disabled_val ep_host ep_port keepalive description allowed_raw; do
        case "$rec_type" in
            I)
                printf '%s\n' "$(jq -cn --arg ifname "$ifname" '{ifname:$ifname}')"
                ;;
            P)
                case "$disabled_val" in
                    1|true|yes|on) continue ;;
                esac

                [ -z "$pubkey" ] && continue
                peer_id="$(calc_peer_id "$pubkey")"
                [ -z "$peer_id" ] && continue

                endpoint=""
                if [ -n "$ep_host" ] && [ -n "$ep_port" ]; then
                    # IPv6 host needs brackets
                    case "$ep_host" in
                        *:*) endpoint="[${ep_host}]:${ep_port}" ;;
                        *)   endpoint="${ep_host}:${ep_port}" ;;
                    esac
                fi

                printf '%s\n' "$(jq -cn \
                    --arg ifname "$ifname" \
                    --arg pid "$peer_id" \
                    --arg pk "$pubkey" \
                    --arg ips_raw "$allowed_raw" \
                    --arg sep "$field_sep" \
                    --arg ep "$endpoint" \
                    --arg ka "$keepalive" \
                    --arg desc "$description" \
                    '{
                        ifname:$ifname,
                        peer_id:$pid,
                        obj:(
                            {public_key:$pk, allowed_ips:(if $ips_raw == "" then [] else ($ips_raw | split($sep) | map(select(length > 0))) end)}
                            + (if $ep != "" then {endpoint:$ep} else {} end)
                            + (if $ka != "" then {persistent_keepalive:($ka|tonumber)} else {} end)
                            + (if $desc != "" then {description:$desc} else {} end)
                        )
                    }')"
                ;;
        esac
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

    if [ -n "$OUTPUT_FILE" ]; then
        tmp_out="$(mktemp)"
        printf '%s\n' "$result" > "$tmp_out"
        mv "$tmp_out" "$OUTPUT_FILE"
        printf 'written: %s\n' "$OUTPUT_FILE"
    else
        printf '%s\n' "$result"
    fi
}

main "$@"
