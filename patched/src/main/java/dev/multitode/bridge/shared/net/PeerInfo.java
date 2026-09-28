package dev.multitode.bridge.shared.net;

import dev.multitode.bridge.shared.SessionRole;

public final class PeerInfo {
    private final int playerId;
    private final String playerName;
    private final SessionRole requestedRole;
    private final String remoteAddress;
    private final long connectedAtMillis;
    private volatile long lastPacketAtMillis;
    private volatile ConnectionState connectionState;

    public PeerInfo(int playerId, String playerName, SessionRole requestedRole, String remoteAddress, long connectedAtMillis) {
        this.playerId = playerId;
        this.playerName = playerName;
        this.requestedRole = requestedRole;
        this.remoteAddress = remoteAddress;
        this.connectedAtMillis = connectedAtMillis;
        this.lastPacketAtMillis = connectedAtMillis;
        this.connectionState = ConnectionState.ACTIVE;
    }

    public int getPlayerId() {
        return playerId;
    }

    public String getPlayerName() {
        return playerName;
    }

    public SessionRole getRequestedRole() {
        return requestedRole;
    }

    public String getRemoteAddress() {
        return remoteAddress;
    }

    public long getConnectedAtMillis() {
        return connectedAtMillis;
    }

    public long getLastPacketAtMillis() {
        return lastPacketAtMillis;
    }

    public void setLastPacketAtMillis(long lastPacketAtMillis) {
        this.lastPacketAtMillis = lastPacketAtMillis;
    }

    public ConnectionState getConnectionState() {
        return connectionState;
    }

    public void setConnectionState(ConnectionState connectionState) {
        this.connectionState = connectionState;
    }

    public String describe() {
        return "playerId=" + playerId
                + ", playerName=" + playerName
                + ", requestedRole=" + requestedRole.name()
                + ", remoteAddress=" + remoteAddress
                + ", connectionState=" + connectionState.name()
                + ", connectedAtMillis=" + connectedAtMillis
                + ", lastPacketAtMillis=" + lastPacketAtMillis;
    }
}
