package dev.multitode.bridge.shared.net;

public final class DisconnectPacket {
    private final String reason;

    public DisconnectPacket(String reason) {
        this.reason = reason;
    }

    public String getReason() {
        return reason;
    }
}
