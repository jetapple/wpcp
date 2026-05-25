# MQTT-based WireGuard Peer Coordination Protocol (WPCP)

## 1. Overview

WPCP is a lightweight MQTT-based coordination protocol for WireGuard peer activation and endpoint propagation in dynamic NAT environments.

WPCP intentionally minimizes protocol complexity:

- WireGuard remains the authoritative data plane
    
- MQTT acts only as a coordination and observation bus
    
- Identity is WireGuard-native
    
- Peer state is locally observed
    
- Endpoint knowledge is distributed
    
- Connectivity is soft-state rather than session-oriented
    

The protocol is peer-centric, not device-centric.

---

# 2. Core Design Principles

---

## 2.1 WireGuard PublicKey is the Cryptographic Identity

Every peer is fundamentally identified by:

```text
WireGuard PublicKey
```

The PublicKey defines:

- cryptographic identity
    
- peer ownership
    
- trust relationship
    

The protocol never replaces PublicKey as the source of truth.

---

## 2.2 Peer ID is the MQTT Routing Namespace

MQTT topics MUST use:

```text
peer_id
```

instead of raw PublicKey.

Definition:

```text
peer_id = base32_lowercase(
    sha256(wireguard_public_key)[0:16]
)
```

Properties:

|Property|Value|
|---|---|
|deterministic|yes|
|collision resistant|yes|
|reversible|no|
|mqtt-safe|yes|
|fixed length|yes|

The Peer ID is a control-plane routing identifier only.

---

## 2.3 MQTT is Control Plane Only

MQTT MUST NOT carry VPN payload traffic.

MQTT is only responsible for:

- peer activation signaling
    
- peer deactivation signaling
    
- endpoint observation propagation
    
- lightweight coordination
    

All encrypted traffic flows exclusively through native WireGuard UDP transport.

---

## 2.4 Endpoint Knowledge is Distributed

Any active WireGuard peer may observe:

```text
endpoint
latest handshake
```

for connected peers.

Therefore endpoint knowledge naturally exists as distributed observations across the overlay network.

No centralized STUN database is required.

---

## 2.5 Endpoint Validity is Handshake-Based

Endpoint validity is determined by:

```text
latest_handshake_age < endpoint_timeout
```

NOT by static TTL.

Recommended:

```text
endpoint_timeout = 180 seconds
```

---

## 2.6 WPCP Does Not Manage Sessions

WPCP does NOT define VPN sessions.

Instead:

```text
WPCP coordinates peer activation state.
```

Actual connectivity is always determined by:

```bash
wg show
```

---

# 3. MQTT Topic Structure

---

# 3.1 Peer Control Topic

Topic:

```text
wg/peer/{peer_id}/control
```

Purpose:

- activate peer
    
- deactivate peer
    

Example:

```text
wg/peer/mfrggzdfmztwq2lknnwg23tpoi/control
```

---

# 3.2 Peer Observation Topic

Topic:

```text
wg/peer/{peer_id}/observation
```

Purpose:

Distributed endpoint observation propagation.

Example:

```text
wg/peer/mfrggzdfmztwq2lknnwg23tpoi/observation
```

---

# 3.3 Optional Global Observation Bus

Large deployments SHOULD avoid this.

Topic:

```text
wg/observation
```

Purpose:

- debugging
    
- small-network aggregation
    

---

# 4. Protocol Messages

---

# 4.1 Activate Message

Purpose:

Request remote peer activation.

Topic:

```text
wg/peer/{target_peer_id}/control
```

Payload:

```json
{
  "type": "activate",

  "peer_id": "source_peer_id",

  "public_key": "source_wireguard_public_key",

  "target_public_key": "target_wireguard_public_key",

  "reason": "peer-request|endpoint-detection|<custom>",

  "family": "ipv4|ipv6" 
}
```

`reason` is optional. It carries activation intent/context for observability and policy decisions. If absent, receiver SHOULD treat it as `remote-request`.

`family` is optional. When present and valid (`ipv4` or `ipv6`), receiver SHOULD activate using only that endpoint family. If absent or invalid, receiver SHOULD use automatic endpoint selection policy.

Receivers SHOULD verify:

```text
peer_id == hash(public_key)
local_peer_id == hash(target_public_key)
```

before processing.

Meaning:

```text
"Please activate your WireGuard peer for me."
```

---

# 4.2 Deactivate Message

Purpose:

Request remote peer deactivation.

Topic:

```text
wg/peer/{target_peer_id}/control
```

Payload:

```json
{
  "type": "deactivate",

  "peer_id": "source_peer_id",

  "public_key": "source_wireguard_public_key",

  "target_public_key": "target_wireguard_public_key",

  "reason": "peer-request|endpoint-detection|<custom>"
}
```

`reason` is optional. It carries deactivation intent/context for observability and policy decisions. If absent, receiver SHOULD treat it as `remote-request`.

`target_public_key` is required. Receiver MUST verify it matches local peer identity before processing.

Meaning:

```text
"Please stop attempting connectivity with me."
```

---

# 4.3 Observation Message

Purpose:

Propagate endpoint observations.

Topic:

```text
wg/peer/{observed_peer_id}/observation
```

Payload:

```json
{
  "type": "observation",

  "peer_id": "mfrggzdfmztwq2lknnwg23tpoi",

  "public_key": "base64_wireguard_public_key",

  "endpoint": "1.2.3.4:54321",

  "latest_handshake": 1750000000,

  "observed_at": 1750000012,

  "observed_by": "observer_peer_id",

  "interface": "wg0"
}
```

Receivers SHOULD verify:

```text
peer_id == hash(public_key)
```

before accepting observations.

---

# 5. Peer Connectivity State

---

## 5.1 Definition

Peer Connectivity State is:

```text
A locally observed connectivity state associated
with a (Local WireGuard Interface, Remote Peer) pair.
```

The authoritative state source is always:

```bash
wg show
```

NOT MQTT.

---

## 5.2 State Scope

Peer Connectivity State is strictly LOCAL.

Example:

```text
(A.wg0, PeerB) -> CONNECTED
(B.wg0, PeerA) -> STALE
```

This is valid and expected.

WPCP NEVER attempts global state synchronization.

---

## 5.3 Peer Connectivity States

---

# INACTIVE

Definition:

```text
Remote peer is not configured on the local WireGuard interface.
```

Characteristics:

- peer absent from `wg show`
    

---

# IDLE

Definition:

```text
Peer exists locally but is inactive.
```

Characteristics:

- peer configured
    
- no endpoint
    
- no keepalive
    
- no handshake state
    

---

# ACTIVATING

Definition:

```text
Peer activation has started locally.
```

Characteristics:

- peer configured
    
- persistent_keepalive > 0
    
- outbound UDP transmission active
    
- handshake not yet established
    

---

# CONNECTED

Definition:

```text
Peer has a recent successful handshake.
```

Condition:

```text
latest_handshake_age < endpoint_timeout
```

Characteristics:

- endpoint considered valid
    
- bidirectional encrypted traffic possible
    

---

# STALE

Definition:

```text
Peer exists but latest handshake has expired.
```

Condition:

```text
latest_handshake_age >= endpoint_timeout
```

Characteristics:

- endpoint may no longer be valid
    
- keepalive MAY still be active
    
- automatic reconnection MAY still succeed
    

---

# FAILED

Definition:

```text
Peer activation failed within retry timeout.
```

Characteristics:

- keepalive active
    
- no successful handshake
    
- retry pending
    

Example:

```text
ACTIVATING > 30 seconds
```

without successful handshake.

---

# 6. Connection Lifecycle

---

# 6.1 Initial Conditions

Peers already possess:

- remote public key
    
- allowed ips
    
- interface configuration
    

Peers SHOULD remain permanently configured.

Inactive peers SHOULD use:

```text
persistent-keepalive = 0
```

---

# 6.2 Activation Flow

---

## Step 1 — Initiator Sends Activation Request

Peer A publishes:

Topic:

```text
wg/peer/B_peer_id/control
```

Payload:

```json
{
  "type": "activate",

  "peer_id": "A_peer_id",

  "public_key": "A_public_key",

  "reason": "peer-request"
}
```

Meaning:

```text
"Please activate your peer for me."
```

---

## Step 2 — Receiver Activates Peer

Peer B receives activation request.

Peer B executes:

```bash
wg set wg_in peer A \
endpoint <known-endpoint> \
persistent-keepalive 25
```

Local state:

```text
ACTIVATING
```

Peer B immediately begins transmitting keepalive packets.

---

## Step 3 — Initiator Activates Peer

After sending activation request:

Peer A executes:

```bash
wg set wg_out peer B \
endpoint <known-endpoint> \
persistent-keepalive 25
```

Local state:

```text
ACTIVATING
```

Peer A immediately begins transmitting keepalive packets.

---

## Step 4 — WireGuard Establishes Connectivity

Both peers continuously exchange keepalive traffic.

Connectivity success is determined exclusively through:

```bash
wg show
```

Specifically:

```text
latest handshake
```

Once:

```text
latest_handshake_age < endpoint_timeout
```

local state becomes:

```text
CONNECTED
```

No MQTT ACK is required.

---

# 6.3 Failure Handling

If:

```text
ACTIVATING
```

persists longer than retry timeout without successful handshake:

Local state becomes:

```text
FAILED
```

Peers MAY retry activation later.

---

# 6.4 Deactivation Flow

---

## Step 1 — Peer Sends Deactivation Request

Topic:

```text
wg/peer/{target_peer_id}/control
```

Payload:

```json
{
  "type": "deactivate",

  "peer_id": "source_peer_id",

  "public_key": "source_public_key",

  "reason": "peer-request"
}
```

---

## Step 2 — Receiver Disables Peer Activity

Receiver SHOULD execute:

```bash
wg set peer SOURCE persistent-keepalive 0
```

Receiver SHOULD NOT remove peer configuration unless explicitly configured.

Local state transitions to:

```text
IDLE
```

---

# 7. Endpoint Observation Propagation

---

## 7.1 Observation Source

Any active WireGuard peer may observe:

- peer endpoint
    
- latest handshake
    

through:

```bash
wg show
```

Example:

```text
peer: ABCDEF
endpoint: 5.6.7.8:45678
latest handshake: 8 seconds ago
```

---

## 7.2 Observation Publication

Observed endpoint information SHOULD be periodically published.

Topic:

```text
wg/peer/{peer_id}/observation
```

Payload:

```json
{
  "type": "observation",

  "peer_id": "target_peer_id",

  "public_key": "target_public_key",

  "endpoint": "5.6.7.8:45678",

  "latest_handshake": 1750000000,

  "observed_at": 1750000008,

  "observed_by": "observer_peer_id",

  "interface": "wg_relay"
}
```

---

## 7.3 Endpoint Adoption

Peers MAY adopt observed endpoints:

```bash
wg set peer TARGET endpoint 5.6.7.8:45678
```

then activate keepalive transmission.

---

# 8. Recommended WireGuard Behavior

---

# Persistent Peer Model (Recommended)

Peers SHOULD remain permanently configured.

Activation SHOULD only toggle:

```text
persistent-keepalive
```

Recommended values:

|State|Keepalive|
|---|---|
|inactive|0|
|active|25|

Advantages:

- lower configuration churn
    
- faster activation
    
- simpler embedded implementation
    
- fewer race conditions
    

---

# 9. MQTT QoS Recommendations

|Message Type|QoS|
|---|---|
|activate|1|
|deactivate|1|
|observation|0 or 1|

QoS 2 is NOT recommended.

---

# 10. Security Model

---

## 10.1 MQTT TLS

MQTT transport MUST use TLS.

---

## 10.2 Client Authentication

Each peer SHOULD possess:

- unique MQTT credentials  
    or
    
- unique TLS client certificate
    

---

## 10.3 ACL Model

Peers SHOULD only publish to:

```text
wg/peer/<owned-peer-id>/#
```

Peers SHOULD subscribe only to:

- relevant control topics
    
- relevant observation topics
    

Global subscriptions SHOULD be avoided in large deployments.

Control message receivers MUST reject payloads missing `target_public_key`, and MUST reject payloads where `target_public_key` does not bind to the receiver peer identity.

---

# 11. Architectural Properties

|Capability|Supported|
|---|---|
|Distributed endpoint discovery|YES|
|Dynamic endpoint propagation|YES|
|WireGuard-native identity|YES|
|Peer-centric architecture|YES|
|Multi-interface devices|YES|
|NAT traversal assistance|YES|
|Distributed endpoint observation|YES|
|Relay-compatible architecture|YES|
|Soft-state connectivity model|YES|

---

# 12. Design Philosophy

WPCP intentionally avoids:

- centralized session orchestration
    
- device-centric identity
    
- globally synchronized peer state
    
- SDP negotiation
    
- ICE complexity
    

Instead:

```text
WireGuard provides cryptographic identity and transport.

MQTT provides lightweight coordination and observation propagation.

Peers collectively maintain distributed endpoint knowledge.
```

This results in a clean, decentralized, WireGuard-native overlay coordination architecture optimized for embedded systems, OpenWRT routers, and self-hosted private networks.