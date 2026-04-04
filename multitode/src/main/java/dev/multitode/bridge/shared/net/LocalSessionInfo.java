package dev.multitode.bridge.shared.net;

public final class LocalSessionInfo {
    private String sessionId;
    private int localPlayerId;
    private ConnectionState connectionState = ConnectionState.DISCONNECTED;
    private String remoteAddress;
    private long connectedAtMillis;
    private long lastPacketAtMillis;

    public String getSessionId() {
        return sessionId;
    }

    public void setSessionId(String sessionId) {
        this.sessionId = sessionId;
    }

    public int getLocalPlayerId() {
        return localPlayerId;
    }

    public void setLocalPlayerId(int localPlayerId) {
        this.localPlayerId = localPlayerId;
    }

    public ConnectionState getConnectionState() {
        return connectionState;
    }

    public void setConnectionState(ConnectionState connectionState) {
        this.connectionState = connectionState;
    }

    public String getRemoteAddress() {
        return remoteAddress;
    }

    public void setRemoteAddress(String remoteAddress) {
        this.remoteAddress = remoteAddress;
    }

    public long getConnectedAtMillis() {
        return connectedAtMillis;
    }

    public void setConnectedAtMillis(long connectedAtMillis) {
        this.connectedAtMillis = connectedAtMillis;
    }

    public long getLastPacketAtMillis() {
        return lastPacketAtMillis;
    }

    public void setLastPacketAtMillis(long lastPacketAtMillis) {
        this.lastPacketAtMillis = lastPacketAtMillis;
    }
}
