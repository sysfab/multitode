package dev.multitode.bridge.shared.net;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;

public final class SessionRegistry {
    private final LocalSessionInfo localSessionInfo = new LocalSessionInfo();
    private final Map<Integer, PeerInfo> peersByPlayerId = new ConcurrentHashMap<>();
    private final Queue<InboundLuaMessage> inboundLuaMessages = new ConcurrentLinkedQueue<>();

    public LocalSessionInfo getLocalSessionInfo() {
        return localSessionInfo;
    }

    public void putPeer(PeerInfo peerInfo) {
        peersByPlayerId.put(peerInfo.getPlayerId(), peerInfo);
    }

    public PeerInfo getPeer(int playerId) {
        return peersByPlayerId.get(playerId);
    }

    public void removePeer(int playerId) {
        peersByPlayerId.remove(playerId);
    }

    public int getConnectedPeerCount() {
        return peersByPlayerId.size();
    }

    public List<PeerInfo> getPeers() {
        List<PeerInfo> peers = new ArrayList<>(peersByPlayerId.values());
        peers.sort(Comparator.comparingInt(PeerInfo::getPlayerId));
        return peers;
    }

    public String describePeers() {
        List<PeerInfo> peers = getPeers();
        if (peers.isEmpty()) {
            return "no connected peers";
        }

        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < peers.size(); i++) {
            if (i > 0) {
                builder.append(" | ");
            }
            builder.append(peers.get(i).describe());
        }
        return builder.toString();
    }

    public void enqueueInboundLuaMessage(InboundLuaMessage message) {
        inboundLuaMessages.add(message);
    }

    public InboundLuaMessage pollInboundLuaMessage() {
        return inboundLuaMessages.poll();
    }

    public int getPendingLuaMessageCount() {
        return inboundLuaMessages.size();
    }

    public String describe() {
        return "sessionId=" + localSessionInfo.getSessionId()
                + ", localPlayerId=" + localSessionInfo.getLocalPlayerId()
                + ", connectionState=" + localSessionInfo.getConnectionState().name()
                + ", remoteAddress=" + localSessionInfo.getRemoteAddress()
                + ", connectedPeerCount=" + getConnectedPeerCount();
    }
}
