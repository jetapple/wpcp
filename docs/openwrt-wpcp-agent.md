# OpenWRT WPCP Agent

This document describes the OpenWRT-compatible implementation in:

- `scripts/wpcp-agent.sh`
- `openwrt/init.d/wpcp-agent`

## Features Implemented

- Monitors and controls a specified WireGuard interface.
- Uses MQTT as WPCP control/observation bus.
- Maintains local observation cache for all connection-related peers, including local peer.
- Stores endpoint cache as a per-family map:
  - `endpoint.ipv4`
  - `endpoint.ipv6`
  - each family value is `{endpoint, observed_by, observed_at, interface, latest_handshake}`
- Activation endpoint selection policy:
  - Optional `family` override is supported by activation flow:
    - `ipv6`: select only target `endpoint.ipv6.endpoint`.
    - `ipv4`: select only target `endpoint.ipv4.endpoint`.
    - other/empty: use auto policy below.
  - If both local peer and target peer have cached IPv6 endpoints, use target IPv6 first.
  - Otherwise prefer target IPv4.
  - If no IPv4 but IPv6 exists, fallback to IPv6.
- Uses `wg show` as the authoritative source for connectivity state.
- Supports foreground run and OpenWRT procd service mode.
- For control `activate`/`deactivate` messages, optional payload field `reason` is supported for intent/context propagation; if absent on receive, it defaults to `remote-request`.
- For control `activate` messages, optional payload field `family` (`ipv4`/`ipv6`) is supported and propagated when relaying activate requests.
- For control `activate`/`deactivate` messages, payload field `target_public_key` is required and validated on receive against local peer identity.

## Dependencies

Install packages (names may vary by feed/build):

```sh
opkg update
opkg install wireguard-tools mosquitto-client jq coreutils-base32 coreutils-stat
# Optional helper for peer_id conversion fallback:
opkg install openssl-util
```

The script requires either `openssl` or `xxd` to convert SHA256 bytes for `peer_id` calculation.

## Foreground Run Example

```sh
chmod +x /usr/bin/wpcp-agent.sh
/usr/bin/wpcp-agent.sh \
  --interface wg0 \
  --broker 10.0.0.10 \
  --config /etc/wpcp/wg0-peers.json \
  --auto 1 \
  --port 1883 \
  --username mqtt_user \
  --password mqtt_pass \
  --tls 0 \
  --topic-prefix wg \
  --state-interval 15 \
  --endpoint-timeout 180 \
  --failed-timeout 30 \
  --keepalive-active 25
```

## procd Service Setup

1. Install files:

```sh
cp /path/to/repo/scripts/wpcp-agent.sh /usr/bin/wpcp-agent.sh
chmod 0755 /usr/bin/wpcp-agent.sh
cp /path/to/repo/openwrt/init.d/wpcp-agent /etc/init.d/wpcp-agent
chmod 0755 /etc/init.d/wpcp-agent
```

2. Create config file `/etc/config/wpcp-agent`:

```uci
config instance 'main'
    option enabled '1'
    option interface 'wg0'
    option broker '10.0.0.10'
    option port '1883'
    option username 'mqtt_user'
    option password 'mqtt_pass'
    option tls '0'
    option topic_prefix 'wg'
    option config '/etc/wg-conf.json'
    option auto '1'
    option state_interval '15'
    option endpoint_timeout '180'
    option failed_timeout '30'
    option keepalive_active '25'
    option qos_control '1'
    option qos_observation '0'
    option log_level 'info'
```

3. Enable and start:

```sh
/etc/init.d/wpcp-agent enable
/etc/init.d/wpcp-agent start
```

## Cache File

Default cache file:

```text
/tmp/wpcp-<interface>-cache.json
```

Each peer entry is keyed by WPCP `peer_id` and can contain:

- `public_key`
- `endpoint` map:
  - `ipv4`: `{endpoint, observed_by, observed_at, interface, latest_handshake}`
  - `ipv6`: `{endpoint, observed_by, observed_at, interface, latest_handshake}`
- `latest_handshake`
- `state`
- `activation_started_at`
- `updated_at`

## Optional Configuration Parameters

In addition to the required and shown parameters above, the following optional parameters are supported:

### Endpoint Detection

- `option endpoint '<ADDR>'` — Explicit local public endpoint (format: `host:port`, `[v6]:port`, or `none` to disable)
- `option detector '<PEER_IDS>'` — Comma-separated list of peer IDs to assist with endpoint detection

Example with endpoint detection:

```uci
config instance 'main'
    option enabled '1'
    option interface 'wg0'
    option broker '10.0.0.10'
    option endpoint '203.0.113.42:51820'
    option detector 'peer1,peer2'
    # ... other options ...
```

### Cache File Location

- `option cache_file '<PATH>'` — Override default cache file location (default: `/tmp/wpcp-<interface>-cache.json`)

Example:

```uci
config instance 'main'
    # ... other options ...
    option cache_file '/var/cache/wpcp-wg0.json'
```

### Config Peer Auto-Management

- `option config '<PATH>'` — Path to the WireGuard peer policy JSON consumed by `--config`
- `option auto '0|1'` — Enable automatic reconciliation of configured peers; `1` requires `option config` to be set

The file referenced by `option config` (for example, `/etc/wpcp-conf.json`) is a per-interface peer policy map.

- Top-level keys are WireGuard interface names (for example, `wg0`, `wg1`)
- Each interface value contains a `peers` object keyed by WPCP `peer_id`
- Each peer object supports:
  - `public_key` (required): peer WireGuard public key
  - `allowed_ips` (optional): list of allowed IP CIDRs
  - `description` (optional): free-text description
  - `assigned_ips` (optional): list of assigned tunnel IP CIDRs
  - `disabled` (optional): `"1"` to disable this peer in auto-management, `"0"` (or absent) to keep it enabled

Example `/etc/wpcp-conf.json`:

```json
{
  "wg1": {
    "peers": {
      "ugiujuhy6kon5zugsbpau3wuj4": {
        "public_key": "HK+hq8Fkk1gbD07sYz/QpG8zMETCUu+3snLS6/EiVX8=",
        "allowed_ips": [
          "0.0.0.0/0"
        ],
        "description": "Homeport",
        "assigned_ips": [
          "10.13.23.10/24"
        ],
        "disabled": "0"
      }
    }
  }
}
```

In this example, `wg0` has no managed peers, while `wg1` manages one enabled peer.

Example:

```uci
config instance 'main'
    # ... other options ...
    option config '/etc/wpcp-conf.json'
    option auto '1'
```


## Notes

- The agent never treats MQTT as data plane; VPN payload still flows only in native WireGuard UDP.
- On deactivation, peer config is kept and only `persistent-keepalive` is set to `0`.
- If observation cache lacks endpoint data, activation is skipped and logged.

---

## Ubus / LuCI Integration

### Runtime Files

When running, the agent creates two additional files per interface:

| File | Purpose |
|---|---|
| `/tmp/wpcp-<iface>-main.pid` | Main agent PID (used by rpcd plugin to detect if agent is alive) |
| `/tmp/wpcp-<iface>-cmd.fifo` | Named pipe for local command delivery (used by rpcd plugin) |

Both files are removed on clean agent shutdown.

### rpcd Shell Plugin

The `openwrt/rpcd/wpcp` script exposes wpcp-agent as a `wpcp` ubus object via rpcd.

#### Install

```sh
cp /path/to/repo/openwrt/rpcd/wpcp /usr/libexec/rpcd/wpcp
chmod 0755 /usr/libexec/rpcd/wpcp
cp /path/to/repo/openwrt/rpcd-acl/wpcp.json /usr/share/rpcd/acl.d/wpcp.json
/etc/init.d/rpcd restart
```

Additional dependency:

```sh
opkg install jq
```

#### Methods

| Method | Input fields | Description |
|---|---|---|
| `status` | `interface` | Returns agent running state, local peer_id, public key, and peer count |
| `peers` | `interface` | Returns the full observation cache for all known peers |
| `activate` | `interface`, `peer_id`, `family` (optional: `ipv4`/`ipv6`/`auto`) | Queues a local activate command for the specified peer |
| `deactivate` | `interface`, `peer_id` | Queues a local deactivate command for the specified peer |
| `reload` | `interface` | Triggers a config file reload inside the running agent |
| `get_config` | `interface` | Returns the current UCI configuration for the interface |

#### Examples

```sh
# Check agent status
ubus call wpcp status '{"interface":"wg0"}'

# List all known peers from cache
ubus call wpcp peers '{"interface":"wg0"}'

# Activate a peer (auto endpoint family selection)
ubus call wpcp activate '{"interface":"wg0","peer_id":"ugiujuhy6kon5zugsbpau3wuj4"}'

# Activate a peer over IPv4 only
ubus call wpcp activate '{"interface":"wg0","peer_id":"ugiujuhy6kon5zugsbpau3wuj4","family":"ipv4"}'

# Deactivate a peer
ubus call wpcp deactivate '{"interface":"wg0","peer_id":"ugiujuhy6kon5zugsbpau3wuj4"}'

# Reload agent config
ubus call wpcp reload '{"interface":"wg0"}'

# Read UCI config for this interface
ubus call wpcp get_config '{"interface":"wg0"}'
```

### Local Command Channel

`activate` and `deactivate` commands sent via `ubus call wpcp` are delivered through a named pipe (`/tmp/wpcp-<iface>-cmd.fifo`) rather than through MQTT. This means:

- LuCI operations work even when the MQTT broker is unreachable.
- The agent processes the command locally and (for `activate`) still relays an MQTT notification to the remote peer via `publish_control`.

### ACL Configuration

`openwrt/rpcd-acl/wpcp.json` assigns:

- **Read** access (`status`, `peers`, `get_config`) to the `wpcp` group.
- **Write** access (`activate`, `deactivate`, `reload`) to the `wpcp` group.

Grant these permissions in LuCI user management or extend the ACL file to map to existing roles (e.g., `luci-app-admin`).

