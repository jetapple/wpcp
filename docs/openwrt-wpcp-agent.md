# OpenWRT WPCP Agent

This document describes the OpenWRT-compatible implementation in:

- `scripts/wpcp-agent.sh`
- `openwrt/init.d/wpcp-agent`

## Features Implemented

- Monitors and controls a specified WireGuard interface.
- Uses MQTT as WPCP control/observation bus.
- Maintains local observation cache for all connection-related peers, including local peer.
- Separates endpoint cache by IP family:
  - `endpoint_v4`
  - `endpoint_v6`
- Activation endpoint selection policy:
  - If both local peer and target peer have cached IPv6 endpoints, use target IPv6 first.
  - Otherwise prefer target IPv4.
  - If no IPv4 but IPv6 exists, fallback to IPv6.
- Uses `wg show` as the authoritative source for connectivity state.
- Supports foreground run and OpenWRT procd service mode.

## Dependencies

Install packages (names may vary by feed/build):

```sh
opkg update
opkg install wireguard-tools mosquitto-client jq coreutils-base32
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

Each peer entry is keyed by WPCP `peer_id` and can contain:

- `public_key`
- `endpoint_v4`
- `endpoint_v6`
- `latest_handshake`
- `handshake_age`
- `observed_by`
- `interface`
- `state`
- `activation_started_at`
- `updated_at`

## Notes

- The agent never treats MQTT as data plane; VPN payload still flows only in native WireGuard UDP.
- On deactivation, peer config is kept and only `persistent-keepalive` is set to `0`.
- If observation cache lacks endpoint data, activation is skipped and logged.
