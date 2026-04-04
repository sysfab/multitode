package dev.multitode.bridge.shared.net;

public final class HelloAcceptedPacket {
    private final String sessionId;
    private final int playerId;
    private final int snapshotIntervalTicks;

    public HelloAcceptedPacket(String sessionId, int playerId, int snapshotIntervalTicks) {
        this.sessionId = sessionId;
        this.playerId = playerId;
        this.snapshotIntervalTicks = snapshotIntervalTicks;
    }

    public String getSessionId() {
        return sessionId;
    }

    public int getPlayerId() {
        return playerId;
    }

    public int getSnapshotIntervalTicks() {
        return snapshotIntervalTicks;
    }
}
