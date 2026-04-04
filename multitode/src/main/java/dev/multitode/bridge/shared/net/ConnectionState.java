package dev.multitode.bridge.shared.net;

public enum ConnectionState {
    DISCONNECTED,
    CONNECTING,
    HANDSHAKE,
    SYNCING,
    ACTIVE,
    DISCONNECTING
}
