package dev.multitode.bridge.host.net;

import dev.multitode.bridge.shared.BridgeContext;
import dev.multitode.bridge.shared.net.ConnectionState;
import dev.multitode.bridge.shared.net.HelloAcceptedPacket;
import dev.multitode.bridge.shared.net.LuaMessagePacket;
import dev.multitode.bridge.shared.net.PeerInfo;

import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

public final class HostSession {
    private final BridgeContext context;
    private final String sessionId = UUID.randomUUID().toString();
    private final AtomicInteger nextPlayerId = new AtomicInteger(1);
    private final Set<HostClientConnection> activeConnections = ConcurrentHashMap.newKeySet();
    private final ConcurrentHashMap<Integer, HostClientConnection> connectionsByPlayerId = new ConcurrentHashMap<>();

    public HostSession(BridgeContext context) {
        this.context = context;
    }

    public BridgeContext getContext() {
        return context;
    }

    public HelloAcceptedPacket createHelloAcceptedPacket() {
        return new HelloAcceptedPacket(
                sessionId,
                nextPlayerId.getAndIncrement()
        );
    }

    public void registerConnection(HostClientConnection connection) {
        activeConnections.add(connection);
    }

    public void unregisterConnection(HostClientConnection connection) {
        activeConnections.remove(connection);
    }

    public int getActiveConnectionCount() {
        return activeConnections.size();
    }

    public PeerInfo registerPeer(int playerId, String playerName, dev.multitode.bridge.shared.SessionRole requestedRole, String remoteAddress) {
        long now = System.currentTimeMillis();
        PeerInfo peerInfo = new PeerInfo(playerId, playerName, requestedRole, remoteAddress, now);
        context.getSessionRegistry().putPeer(peerInfo);
        return peerInfo;
    }

    public void bindPlayerConnection(int playerId, HostClientConnection connection) {
        connectionsByPlayerId.put(playerId, connection);
    }

    public void touchPeer(int playerId) {
        PeerInfo peerInfo = context.getSessionRegistry().getPeer(playerId);
        if (peerInfo == null) {
            return;
        }

        peerInfo.setLastPacketAtMillis(System.currentTimeMillis());
    }

    public void disconnectPeer(int playerId) {
        connectionsByPlayerId.remove(playerId);
        PeerInfo peerInfo = context.getSessionRegistry().getPeer(playerId);
        if (peerInfo == null) {
            return;
        }

        peerInfo.setConnectionState(ConnectionState.DISCONNECTED);
        context.getSessionRegistry().removePeer(playerId);
    }

    public boolean broadcastLuaMessage(String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        boolean sent = false;
        LuaMessagePacket packet = new LuaMessagePacket(messageChannel, messageName, senderPlayerId, payloadJson);
        for (HostClientConnection connection : activeConnections) {
            sent |= connection.sendLuaMessage(packet);
        }
        return sent;
    }

    public boolean sendLuaMessageToPeer(int playerId, String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        HostClientConnection connection = connectionsByPlayerId.get(playerId);
        if (connection == null) {
            return false;
        }

        return connection.sendLuaMessage(new LuaMessagePacket(messageChannel, messageName, senderPlayerId, payloadJson));
    }
}
