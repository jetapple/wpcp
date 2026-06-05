#!/bin/sh

# wg-conf-to-json.sh
# Reads WireGuard configuration from the current system and outputs
# structured JSON.
#
# Default behavior:
#   - If -o/--output is provided, per-interface JSON files are written.
#   - If -o/--output is omitted, per-interface JSON objects are printed
#     to stdout, one object per line.
#
# Combined behavior (-c/--combined):
#   - Output a single aggregated JSON object containing all interfaces.
#   - With -o/--output, write one file: wpcp-combined-conf.json
#
# Supported platforms:
#   - Linux:   /etc/wireguard/*.conf
#   - OpenWRT: UCI (uci show network)
#
# Output format:
#   {
#     "<ifname>": {
#       "public_key": "...",         # omitted if unavailable
#       "peer_id": "...",            # omitted if public_key unavailable
#       "listen_port": N,              # omitted if absent
#       "address": ["..."],           # omitted if absent
#       "mtu": N,                      # omitted if absent
#       "peers": {
#         "<peer_id>": {
#           "public_key": "...",
#           "allowed_ips": ["..."],   # omitted if absent
#           "assigned_ips": ["..."],  # omitted if absent
#           "endpoint": "...",        # omitted if absent
#           "persistent_keepalive": N,  # omitted if absent
#           "disabled": "0|1"         # omitted if absent
#         }
#       }
#     }
#   }
#
# peer_id = base32_lowercase( sha256(public_key)[0:16] )

set -u

OUTPUT_DIR=""
COMBINED_MODE=0

usage() {
    cat <<EOF
Usage: wg-conf-to-json.sh [options]

Options:
  -o, --output DIR    Output JSON directory (wpcp-<ifname>-conf.json per interface)
  -c, --combined      Output one aggregated JSON containing all interfaces
  -h, --help          Show this help and exit

This script auto-detects platform and reads WireGuard peer config from:
  - Linux:   /etc/wireguard/*.conf
  - OpenWRT: UCI network config

Output behavior:
  - With -o/--output DIR: write one file per interface:
      DIR/wpcp-<ifname>-conf.json
  - Without -o/--output: print one interface JSON object per line to stdout
    - With -c/--combined: output one aggregated JSON object
    - With -c/--combined and -o/--output DIR:
            DIR/wpcp-combined-conf.json
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o|--output)
                if [ "$#" -lt 2 ]; then
                    printf 'error: missing argument for %s\n' "$1" >&2
                    usage >&2
                    exit 1
                fi
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -c|--combined)
                COMBINED_MODE=1
                shift
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
# derive_public_key <private_key>
# Derive WireGuard public key from private key if wg is available.
# ---------------------------------------------------------------------------
derive_public_key() {
    private_key="$1"
    [ -z "$private_key" ] && return 1

    if command -v wg >/dev/null 2>&1; then
        pubkey="$(printf '%s\n' "$private_key" | wg pubkey 2>/dev/null || true)"
        [ -n "$pubkey" ] || return 1
        printf '%s' "$pubkey"
        return 0
    fi

    return 1
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
# JSON objects to stdout.
# Interface line: {"ifname":"wg0","iface":{...}}
# Peer line:      {"ifname":"wg0","peer_id":"...","obj":{...}}
# ---------------------------------------------------------------------------
parse_linux_conf() {
    conf="$1"
    ifname="${conf##*/}"
    ifname="${ifname%.conf}"
    field_sep="$(printf '\036')"
    col_sep="$(printf '\037')"

    awk -v FSSEP="$field_sep" -v COLSEP="$col_sep" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function flush_iface() {
            print "I" COLSEP if_private_key COLSEP if_address COLSEP if_listen_port COLSEP if_mtu
        }
        function flush_peer() {
            if (pubkey == "") return
            print "P" COLSEP pubkey COLSEP allowed_ips COLSEP assigned_ips COLSEP endpoint COLSEP keepalive COLSEP description
            pubkey = ""
            allowed_ips = ""
            assigned_ips = ""
            endpoint = ""
            keepalive = ""
            description = ""
        }
        {
            line = $0
            sub(/#.*/, "", line)
            line = trim(line)
            if (line == "") next

            low = tolower(line)
            if (low == "[interface]") {
                in_interface = 1
                in_peer = 0
                next
            }

            if (low == "[peer]") {
                flush_peer()
                in_interface = 0
                in_peer = 1
                next
            }

            if (substr(line, 1, 1) == "[") {
                flush_peer()
                in_interface = 0
                in_peer = 0
                next
            }

            if (in_interface) {
                p = index(line, "=")
                if (p <= 0) next

                key = trim(substr(line, 1, p - 1))
                val = trim(substr(line, p + 1))

                if (key == "PrivateKey") {
                    if_private_key = val
                } else if (key == "Address") {
                    n = split(val, _addrs, ",")
                    for (j = 1; j <= n; j++) {
                        _a = _addrs[j]
                        sub(/^[[:space:]]+/, "", _a)
                        sub(/[[:space:]]+$/, "", _a)
                        if (_a == "") continue
                        if_address = (if_address == "") ? _a : (if_address FSSEP _a)
                    }
                } else if (key == "ListenPort") {
                    if_listen_port = val
                } else if (key == "MTU") {
                    if_mtu = val
                }
                next
            }

            if (!in_peer) next

            p = index(line, "=")
            if (p <= 0) next

            key = trim(substr(line, 1, p - 1))
            val = trim(substr(line, p + 1))

            if (key == "PublicKey") {
                pubkey = val
            } else if (key == "AllowedIPs") {
                if (allowed_ips == "") {
                    allowed_ips = val
                } else {
                    allowed_ips = allowed_ips FSSEP val
                }
            } else if (key == "AssignedIPs") {
                if (assigned_ips == "") {
                    assigned_ips = val
                } else {
                    assigned_ips = assigned_ips FSSEP val
                }
            } else if (key == "Endpoint") {
                endpoint = val
            } else if (key == "PersistentKeepalive") {
                keepalive = val
            } else if (key == "Description" || key == "description") {
                description = val
            }
        }
        END {
            flush_iface()
            flush_peer()
        }
    ' "$conf" | while IFS="$col_sep" read -r rec_type v1 v2 v3 v4 v5 v6; do
        case "$rec_type" in
            I)
                if_private="$v1"
                if_addr_raw="$v2"
                if_listen_port="$v3"
                if_mtu="$v4"

                # Validate numeric fields in shell - avoids regex in jq
                case "$if_listen_port" in
                    ''|*[!0-9]*) if_listen_port="" ;;
                esac
                case "$if_mtu" in
                    ''|*[!0-9]*) if_mtu="" ;;
                esac

                if_pubkey=""
                if_peer_id=""
                if_pubkey="$(derive_public_key "$if_private" || true)"
                if [ -n "$if_pubkey" ]; then
                    if_peer_id="$(calc_peer_id "$if_pubkey")"
                fi

                printf '%s\n' "$(jq -cn \
                    --arg ifname "$ifname" \
                    --arg ifpk "$if_pubkey" \
                    --arg ifpid "$if_peer_id" \
                    --arg addr_raw "$if_addr_raw" \
                    --arg sep "$field_sep" \
                    --arg lp "$if_listen_port" \
                    --arg mtu "$if_mtu" \
                    '{
                        ifname:$ifname,
                        iface:(
                            ({})
                            + (if $ifpk != "" then {public_key:$ifpk} else {} end)
                            + (if $ifpid != "" then {peer_id:$ifpid} else {} end)
                            + (if $addr_raw != "" then {address:($addr_raw | split($sep) | map(select(length > 0)))} else {} end)
                            + (if $lp != "" then {listen_port:($lp|tonumber)} else {} end)
                            + (if $mtu != "" then {mtu:($mtu|tonumber)} else {} end)
                        )
                    }' </dev/null)"
                ;;
            P)
                pubkey="$v1"
                allowed_raw="$v2"
                assigned_raw="$v3"
                endpoint="$v4"
                keepalive="$v5"
                description="$v6"

                [ -z "$pubkey" ] && continue

                peer_id="$(calc_peer_id "$pubkey")"
                [ -z "$peer_id" ] && continue

                printf '%s\n' "$(jq -cn \
                    --arg ifname "$ifname" \
                    --arg pid "$peer_id" \
                    --arg pk "$pubkey" \
                    --arg ips_raw "$allowed_raw" \
                    --arg assigned_raw "$assigned_raw" \
                    --arg sep "$field_sep" \
                    --arg ep "$endpoint" \
                    --arg ka "$keepalive" \
                    --arg desc "$description" \
                    'def normalize_ip_list($raw; $sep):
                        (
                            $raw
                            | split($sep)
                            | map(gsub(","; " ") | gsub("\t"; " ") | split(" ") | map(select(length > 0)))
                            | flatten
                        );
                    {
                        ifname:$ifname,
                        peer_id:$pid,
                        obj:(
                            ({public_key:$pk}
                            + (if $ips_raw != "" then {allowed_ips:(normalize_ip_list($ips_raw; $sep))} else {} end))
                            + (if $assigned_raw != "" then {assigned_ips:(normalize_ip_list($assigned_raw; $sep))} else {} end)
                            + (if $ep != "" then {endpoint:$ep} else {} end)
                            + (if $ka != "" then {persistent_keepalive:($ka|tonumber)} else {} end)
                            + (if $desc != "" then {description:$desc} else {} end)
                        )
                    }' </dev/null)"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# collect_linux
# Iterate all /etc/wireguard/*.conf files and print JSON lines.
# ---------------------------------------------------------------------------
collect_linux() {
    found=0
    for conf in /etc/wireguard/*.conf; do
        [ -f "$conf" ] || continue
        found=1
        parse_linux_conf "$conf"
    done
    [ "$found" = "0" ] && printf 'warn: no .conf files found in /etc/wireguard/\n' >&2
}

# ---------------------------------------------------------------------------
# collect_openwrt
# Use UCI to read WireGuard interfaces and their peers.
# ---------------------------------------------------------------------------
collect_openwrt() {
    # One-pass UCI parsing to avoid repeated scans and per-field awk processes.
    uci_dump="$(uci show network 2>/dev/null)"
    field_sep="$(printf '\036')"
    col_sep="$(printf '\037')"
    debug_openwrt="${WG_CONF_DEBUG_OPENWRT:-0}"

    if [ "$debug_openwrt" = "1" ]; then
        printf 'debug: collect_openwrt: begin\n' >&2
        printf 'debug: collect_openwrt: uci_dump_bytes=%s\n' "$(printf '%s' "$uci_dump" | wc -c | awk '{print $1}')" >&2
        printf 'debug: collect_openwrt: uci_dump_lines=%s\n' "$(printf '%s\n' "$uci_dump" | wc -l | awk '{print $1}')" >&2
    fi

    tmp_rows="$(mktemp)"
    if [ -z "$tmp_rows" ]; then
        printf 'error: collect_openwrt: failed to allocate temporary file\n' >&2
        return 1
    fi

    if ! printf '%s\n' "$uci_dump" | awk -v FSSEP="$field_sep" -v COLSEP="$col_sep" '
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
                if (opt == "allowed_ips" || opt == "assigned_ips") {
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
                    print "I" COLSEP ifname COLSEP \
                          section_opt[sec SUBSEP "private_key"] COLSEP \
                          section_opt[sec SUBSEP "addresses"] COLSEP \
                          section_opt[sec SUBSEP "listen_port"] COLSEP \
                          section_opt[sec SUBSEP "mtu"]
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
                      section_opt[sec SUBSEP "allowed_ips"] COLSEP \
                      section_opt[sec SUBSEP "assigned_ips"]
            }
        }
    ' > "$tmp_rows"; then
        printf 'error: collect_openwrt: failed to parse uci network config\n' >&2
        rm -f "$tmp_rows"
        return 1
    fi

    if [ "$debug_openwrt" = "1" ]; then
        printf 'debug: collect_openwrt: parsed_rows_begin\n' >&2
        awk '{printf "debug: collect_openwrt: row=%d raw=%s\\n", NR, $0}' "$tmp_rows" >&2
        printf 'debug: collect_openwrt: parsed_rows_end\n' >&2
    fi

    rec_no=0
    while IFS="$col_sep" read -r rec_type ifname v1 v2 v3 v4 v5 v6 v7 v8; do
        rec_no=$((rec_no + 1))
        if [ "$debug_openwrt" = "1" ]; then
            printf 'debug: collect_openwrt: rec=%s type=%s ifname=%s\n' "$rec_no" "$rec_type" "$ifname" >&2
        fi
        case "$rec_type" in
            I)
                if_private="$v1"
                if_addr_raw="$v2"
                if_listen_port="$v3"
                if_mtu="$v4"

                # Validate numeric fields in shell - avoids regex in jq
                case "$if_listen_port" in
                    ''|*[!0-9]*) if_listen_port="" ;;
                esac
                case "$if_mtu" in
                    ''|*[!0-9]*) if_mtu="" ;;
                esac

                if_pubkey=""
                if_peer_id=""
                if_pubkey="$(derive_public_key "$if_private" || true)"
                if [ -n "$if_pubkey" ]; then
                    if_peer_id="$(calc_peer_id "$if_pubkey")"
                fi

                if [ "$debug_openwrt" = "1" ]; then
                    printf 'debug: collect_openwrt: rec=%s stage=iface_jq ifname=%s listen_port=%s mtu=%s\n' "$rec_no" "$ifname" "$if_listen_port" "$if_mtu" >&2
                fi

                iface_json="$(jq -cn \
                    --arg ifname "$ifname" \
                    --arg ifpk "$if_pubkey" \
                    --arg ifpid "$if_peer_id" \
                    --arg addr_raw "$if_addr_raw" \
                    --arg sep "$field_sep" \
                    --arg lp "$if_listen_port" \
                    --arg mtu "$if_mtu" \
                    '{
                        ifname:$ifname,
                        iface:(
                            ({})
                            + (if $ifpk != "" then {public_key:$ifpk} else {} end)
                            + (if $ifpid != "" then {peer_id:$ifpid} else {} end)
                            + (if $addr_raw != "" then {address:($addr_raw | split($sep) | map(select(length > 0)))} else {} end)
                            + (if $lp != "" then {listen_port:($lp|tonumber)} else {} end)
                            + (if $mtu != "" then {mtu:($mtu|tonumber)} else {} end)
                        )
                    }' </dev/null)"
                iface_jq_rc=$?
                if [ "$iface_jq_rc" -ne 0 ] || [ -z "$iface_json" ]; then
                    printf 'error: collect_openwrt: iface jq failed rec=%s ifname=%s rc=%s\n' "$rec_no" "$ifname" "$iface_jq_rc" >&2
                    if [ "$debug_openwrt" = "1" ]; then
                        printf 'debug: collect_openwrt: rec=%s iface_raw addr=%s lp=%s mtu=%s\n' "$rec_no" "$if_addr_raw" "$if_listen_port" "$if_mtu" >&2
                    fi
                    continue
                fi

                printf '%s\n' "$iface_json"
                ;;
            P)
                pubkey="$v1"
                disabled_val="$v2"
                ep_host="$v3"
                ep_port="$v4"
                keepalive="$v5"
                description="$v6"
                allowed_raw="$v7"
                assigned_raw="$v8"

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

                # Pre-normalize IP lists in shell: replace FSSEP and commas with
                # spaces, then re-join non-empty tokens with FSSEP.  This avoids
                # gsub/def in jq, which crash on older OpenWRT jq builds.
                allowed_norm="$(printf '%s' "$allowed_raw" \
                    | tr "${field_sep}," '  ' \
                    | awk 'BEGIN{ORS="";n=0}{for(i=1;i<=NF;i++){if($i!=""){if(n>0)printf "\036";printf "%s",$i;n++}}}')"
                assigned_norm="$(printf '%s' "$assigned_raw" \
                    | tr "${field_sep}," '  ' \
                    | awk 'BEGIN{ORS="";n=0}{for(i=1;i<=NF;i++){if($i!=""){if(n>0)printf "\036";printf "%s",$i;n++}}}')"

                if [ "$debug_openwrt" = "1" ]; then
                    printf 'debug: collect_openwrt: rec=%s stage=peer_jq ifname=%s peer_id=%s allowed_norm=%s assigned_norm=%s\n' "$rec_no" "$ifname" "$peer_id" "$allowed_norm" "$assigned_norm" >&2
                fi

                peer_json="$(jq -cn \
                    --arg ifname "$ifname" \
                    --arg pid "$peer_id" \
                    --arg pk "$pubkey" \
                    --arg ips_raw "$allowed_norm" \
                    --arg assigned_raw "$assigned_norm" \
                    --arg sep "$field_sep" \
                    --arg ep "$endpoint" \
                    --arg ka "$keepalive" \
                    --arg desc "$description" \
                    --arg dis "$disabled_val" \
                    '{
                        ifname:$ifname,
                        peer_id:$pid,
                        obj:(
                            ({public_key:$pk}
                            + (if $ips_raw != "" then {allowed_ips:($ips_raw | split($sep) | map(select(length > 0)))} else {} end))
                            + (if $assigned_raw != "" then {assigned_ips:($assigned_raw | split($sep) | map(select(length > 0)))} else {} end)
                            + (if $ep != "" then {endpoint:$ep} else {} end)
                            + (if $ka != "" then {persistent_keepalive:($ka|tonumber)} else {} end)
                            + (if $desc != "" then {description:$desc} else {} end)
                            + (if $dis != "" then {disabled:$dis} else {} end)
                        )
                    }' </dev/null)"
                peer_jq_rc=$?
                if [ "$peer_jq_rc" -ne 0 ] || [ -z "$peer_json" ]; then
                    printf 'error: collect_openwrt: peer jq failed rec=%s ifname=%s peer_id=%s rc=%s\n' "$rec_no" "$ifname" "$peer_id" "$peer_jq_rc" >&2
                    if [ "$debug_openwrt" = "1" ]; then
                        printf 'debug: collect_openwrt: rec=%s peer_raw pubkey=%s dis=%s ep_host=%s ep_port=%s ka=%s desc=%s allowed_norm=%s assigned_norm=%s\n' "$rec_no" "$pubkey" "$disabled_val" "$ep_host" "$ep_port" "$keepalive" "$description" "$allowed_norm" "$assigned_norm" >&2
                    fi
                    continue
                fi

                printf '%s\n' "$peer_json"
                ;;
        esac
    done < "$tmp_rows"

    rm -f "$tmp_rows"
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

    # Aggregate: fold interface and peer lines into nested JSON
    result="$(jq -sc '
        reduce .[] as $e (
            {};
            .[$e.ifname] = (
                (.[$e.ifname] // {})
                + (if ($e | has("iface")) then $e.iface else {} end)
                + (if (($e | has("peer_id")) and ($e | has("obj")))
                   then {peers:(((.[$e.ifname].peers // {}) + {($e.peer_id): $e.obj}))}
                   else {}
                   end)
            )
        )
        | with_entries(.value = (.value + {peers:(.value.peers // {})}))
    ' "$tmp_lines")"

    if [ -n "$OUTPUT_DIR" ]; then
        if [ ! -d "$OUTPUT_DIR" ]; then
            printf 'error: output directory does not exist: %s\n' "$OUTPUT_DIR" >&2
            exit 1
        fi

        if [ "$COMBINED_MODE" -eq 1 ]; then
            out_file="$OUTPUT_DIR/wpcp-conf.json"
            tmp_out="$(mktemp)"

            if ! printf '%s\n' "$result" | jq -c '.' > "$tmp_out"; then
                printf 'error: failed to build combined JSON output\n' >&2
                rm -f "$tmp_out"
                exit 1
            fi

            if ! mv "$tmp_out" "$out_file"; then
                printf 'error: failed to write output file: %s\n' "$out_file" >&2
                rm -f "$tmp_out"
                exit 1
            fi

            printf 'written: %s\n' "$out_file"
            exit 0
        fi

        write_failed=0
        tmp_ifnames="$(mktemp)"
        if ! printf '%s\n' "$result" | jq -r 'keys[]' > "$tmp_ifnames"; then
            printf 'error: failed to enumerate interfaces from JSON result\n' >&2
            rm -f "$tmp_ifnames"
            exit 1
        fi

        while IFS= read -r ifname; do
            [ -z "$ifname" ] && continue

            out_file="$OUTPUT_DIR/wpcp-${ifname}-conf.json"
            tmp_out="$(mktemp)"

            if ! printf '%s\n' "$result" | jq --arg ifname "$ifname" '{($ifname): .[$ifname]}' > "$tmp_out"; then
                printf 'error: failed to build JSON for interface: %s\n' "$ifname" >&2
                rm -f "$tmp_out"
                write_failed=1
                continue
            fi

            if ! mv "$tmp_out" "$out_file"; then
                printf 'error: failed to write output file: %s\n' "$out_file" >&2
                rm -f "$tmp_out"
                write_failed=1
                continue
            fi

            printf 'written: %s\n' "$out_file"
        done < "$tmp_ifnames"

        rm -f "$tmp_ifnames"

        if [ "$write_failed" -ne 0 ]; then
            exit 1
        fi
    else
        if [ "$COMBINED_MODE" -eq 1 ]; then
            printf '%s\n' "$result" | jq -c '.'
        else
            printf '%s\n' "$result" | jq -c 'to_entries[] | {(.key): .value}'
        fi
    fi
}

main "$@"
