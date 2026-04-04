package dev.multitode.bridge.shared.net;

import dev.multitode.bridge.shared.SessionRole;

public final class HelloPacket {
    private final int protocolVersion;
    private final String playerName;
    private final SessionRole requestedRole;

    public HelloPacket(int protocolVersion, String playerName, SessionRole requestedRole) {
        this.protocolVersion = protocolVersion;
        this.playerName = playerName;
        this.requestedRole = requestedRole;
    }

    public int getProtocolVersion() {
        return protocolVersion;
    }

    public String getPlayerName() {
        return playerName;
    }

    public SessionRole getRequestedRole() {
        return requestedRole;
    }
}
