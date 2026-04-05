package dev.multitode.bridge.shared.net;

public final class HelloAcceptedPacket {
    private final String sessionId;
    private final int playerId;

    public HelloAcceptedPacket(String sessionId, int playerId) {
        this.sessionId = sessionId;
        this.playerId = playerId;
    }

    public String getSessionId() {
        return sessionId;
    }

    public int getPlayerId() {
        return playerId;
    }
}
