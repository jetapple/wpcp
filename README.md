# WireGuard Peer Coordination Protocol (WPCP): A Distributed MQTT Control Plane

## 1. Overview

The **WPCP protocol** serves as a specialized **control plane** designed to manage **WireGuard VPN peers** by using **MQTT** for communication. Instead of relying on centralized databases or complex networking protocols like STUN, it uses **distributed endpoint discovery** to share connection details across a network. A peer's identity is strictly tied to its **WireGuard public key**, ensuring that security remains rooted in the encryption layer rather than the hardware. This system facilitates **NAT traversal** by allowing peers to signal their availability and update their connection points in real time. Because the protocol keeps the **data plane and control plane separate**, encrypted traffic continues to flow directly between devices via UDP. Ultimately, this approach offers a **minimalist and peer-centric** way to maintain secure tunnels in dynamic or restricted network environments.

![WPCP - WireGuard Peer Coordination Protocol](imgs/wpcp.png)