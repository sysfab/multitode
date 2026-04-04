package dev.multitode.bridge.shared.net;

public final class HelloRejectedPacket {
    private final String reason;

    public HelloRejectedPacket(String reason) {
        this.reason = reason;
    }

    public String getReason() {
        return reason;
    }
}
