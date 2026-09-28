package dev.multitode.bridge.shared.net;

public final class PingPacket {
    private final long sentAtMillis;

    public PingPacket(long sentAtMillis) {
        this.sentAtMillis = sentAtMillis;
    }

    public long getSentAtMillis() {
        return sentAtMillis;
    }
}
