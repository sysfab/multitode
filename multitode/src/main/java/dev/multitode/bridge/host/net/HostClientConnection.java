package dev.multitode.bridge.host.net;

import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.shared.net.HelloAcceptedPacket;
import dev.multitode.bridge.shared.net.HelloPacket;
import dev.multitode.bridge.shared.net.HelloRejectedPacket;
import dev.multitode.bridge.shared.net.PacketType;
import dev.multitode.bridge.shared.net.PacketCodec;
import dev.multitode.bridge.shared.net.PingPacket;
import dev.multitode.bridge.shared.net.ProtocolVersion;
import dev.multitode.bridge.shared.net.DisconnectPacket;
import dev.multitode.bridge.shared.net.PeerInfo;
import dev.multitode.bridge.shared.net.InboundLuaMessage;
import dev.multitode.bridge.shared.net.LuaMessagePacket;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;

public final class HostClientConnection {
    private static final TLog LOGGER = TLog.forTag("multitode/HostClientConnection");
    
    private static final int SOCKET_TIMEOUT_MILLIS = 10000;
    private static final long PING_INTERVAL_MILLIS = 5000L;
    private static final long INACTIVITY_TIMEOUT_MILLIS = 10000L;

    private final HostSession hostSession;
    private final Socket socket;
    private final AtomicBoolean running = new AtomicBoolean(true);
    private int playerId;
    private volatile DataOutputStream outputStream;

    public HostClientConnection(HostSession hostSession, Socket socket) {
        this.hostSession = hostSession;
        this.socket = socket;
    }

    public void start() {
        Thread thread = new Thread(this::runHandshake, "multitode-host-client-" + socket.getPort());
        thread.setDaemon(true);
        thread.start();
    }

    private void runHandshake() {
        String remoteAddress = socket.getRemoteSocketAddress().toString();
        try (Socket closableSocket = socket;
             DataInputStream inputStream = new DataInputStream(closableSocket.getInputStream());
             DataOutputStream outputStream = new DataOutputStream(closableSocket.getOutputStream())) {
            this.outputStream = outputStream;
            closableSocket.setSoTimeout(SOCKET_TIMEOUT_MILLIS);
            // Small, frequent gameplay packets: disable Nagle.
            try {
                closableSocket.setTcpNoDelay(true);
            } catch (IOException ignored) {
            }
            HelloPacket helloPacket = PacketCodec.readHello(inputStream);
            LOGGER.i("Received HELLO from %s player=%s role=%s protocol=%s",
                    remoteAddress,
                    helloPacket.getPlayerName(),
                    helloPacket.getRequestedRole().name(),
                    helloPacket.getProtocolVersion());

            if (helloPacket.getProtocolVersion() != ProtocolVersion.CURRENT) {
                PacketCodec.writeHelloRejected(outputStream, new HelloRejectedPacket(
                        "Protocol mismatch: expected " + ProtocolVersion.CURRENT + " but received " + helloPacket.getProtocolVersion()
                ));
                return;
            }

            HelloAcceptedPacket acceptedPacket = hostSession.createHelloAcceptedPacket();
            this.playerId = acceptedPacket.getPlayerId();
            PacketCodec.writeHelloAccepted(outputStream, acceptedPacket);
            hostSession.registerConnection(this);
            hostSession.bindPlayerConnection(playerId, this);
            PeerInfo peerInfo = hostSession.registerPeer(
                    acceptedPacket.getPlayerId(),
                    helloPacket.getPlayerName(),
                    helloPacket.getRequestedRole(),
                    remoteAddress
            );
            LOGGER.i("Accepted %s as playerId=%s sessionId=%s",
                    remoteAddress,
                    acceptedPacket.getPlayerId(),
                    acceptedPacket.getSessionId());
            LOGGER.i("Registered peer playerId=%s name=%s activeConnections=%s",
                    peerInfo.getPlayerId(),
                    peerInfo.getPlayerName(),
                    hostSession.getActiveConnectionCount());

            runSessionLoop(remoteAddress, inputStream, outputStream);
        } catch (IOException exception) {
            LOGGER.w("Host client handshake failed for %s: %s", remoteAddress, exception.getMessage());
        } finally {
            running.set(false);
            synchronized (this) {
                this.outputStream = null;
            }
            hostSession.unregisterConnection(this);
            if (playerId != 0) {
                hostSession.disconnectPeer(playerId);
            }
            LOGGER.i("Closed host connection for %s, activeConnections=%s", remoteAddress, hostSession.getActiveConnectionCount());
        }
    }

    private void runSessionLoop(String remoteAddress, DataInputStream inputStream, DataOutputStream outputStream) throws IOException {
        long lastReceivedAt = System.currentTimeMillis();
        long lastPingAt = 0L;

        while (running.get()) {
            long now = System.currentTimeMillis();
            if (now - lastReceivedAt > INACTIVITY_TIMEOUT_MILLIS) {
                PacketCodec.writeDisconnect(outputStream, new DisconnectPacket("Timed out waiting for client traffic"));
                throw new IOException("Client timed out");
            }

            if (now - lastPingAt >= PING_INTERVAL_MILLIS) {
                synchronized (this) {
                    PacketCodec.writePing(outputStream, new PingPacket(now));
                }
                lastPingAt = now;
            }

            try {
                PacketType packetType = PacketCodec.readType(inputStream);
                lastReceivedAt = System.currentTimeMillis();
                hostSession.touchPeer(playerId);
                if (packetType == PacketType.PING) {
                    PingPacket pingPacket = PacketCodec.readPingPayload(inputStream);
                    long sentAt = pingPacket.getSentAtMillis();
                    if (sentAt > 0) {
                        // A request: echo it back so the peer can measure RTT.
                        synchronized (this) {
                            PacketCodec.writePing(outputStream, new PingPacket(-sentAt));
                        }
                    } else if (sentAt < 0) {
                        // A reply to our own ping: sentAt is -sentTime.
                        long rtt = System.currentTimeMillis() + sentAt;
                        if (rtt >= 0 && rtt < 60000) {
                            PeerInfo peerInfo = hostSession.getContext().getSessionRegistry().getPeer(playerId);
                            if (peerInfo != null) {
                                peerInfo.setLastRttMillis(rtt);
                            }
                            if (hostSession.getContext().getSessionRegistry().getLocalSessionInfo().getLocalPlayerId() == playerId) {
                                hostSession.getContext().getSessionRegistry().getLocalSessionInfo().setLastRttMillis(rtt);
                            }
                        }
                    }
                    continue;
                }

                if (packetType == PacketType.LUA_MESSAGE) {
                    LuaMessagePacket messagePacket = PacketCodec.readLuaMessagePayload(inputStream);
                    // Never trust the sender id from the wire: stamp the id this
                    // connection was authenticated with during the HELLO handshake.
                    // A hand-crafted packet could otherwise impersonate another
                    // peer (or the host) in HOST-context Lua handlers. Honest
                    // clients always send their own local id, so this only ever
                    // differs for spoofed traffic - which we log loudly.
                    int claimedSender = messagePacket.getSenderPlayerId();
                    int authenticatedSender = this.playerId;
                    if (claimedSender != authenticatedSender) {
                        LOGGER.w("Sender mismatch from %s: claimed=%s authenticated=%s (using authenticated)",
                                remoteAddress, claimedSender, authenticatedSender);
                    }
                    hostSession.getContext().getSessionRegistry().enqueueInboundLuaMessage(new InboundLuaMessage(
                            "HOST",
                            messagePacket.getMessageChannel(),
                            messagePacket.getMessageName(),
                            authenticatedSender,
                            messagePacket.getPayloadJson()
                    ));
                    LOGGER.i("Queued Lua message for host channel=%s name=%s sender=%s",
                            messagePacket.getMessageChannel(),
                            messagePacket.getMessageName(),
                            authenticatedSender);
                    continue;
                }

                if (packetType == PacketType.DISCONNECT) {
                    DisconnectPacket disconnectPacket = PacketCodec.readDisconnectPayload(inputStream);
                    LOGGER.i("Client %s disconnected: %s", remoteAddress, disconnectPacket.getReason());
                    return;
                }

                throw new IOException("Unexpected packet during active session: " + packetType);
            } catch (SocketTimeoutException ignored) {
            }
        }
    }

    public synchronized boolean sendLuaMessage(LuaMessagePacket packet) {
        if (!running.get() || outputStream == null) {
            return false;
        }

        try {
            PacketCodec.writeLuaMessage(outputStream, packet);
            return true;
        } catch (IOException exception) {
            LOGGER.w("Failed to send Lua message to playerId=%s: %s", playerId, exception.getMessage());
            return false;
        }
    }

    public synchronized boolean sendDisconnect(String reason) {
        if (outputStream == null) {
            return false;
        }

        try {
            PacketCodec.writeDisconnect(outputStream, new DisconnectPacket(reason == null ? "Host shutting down" : reason));
            return true;
        } catch (IOException exception) {
            LOGGER.w("Failed to send disconnect to playerId=%s: %s", playerId, exception.getMessage());
            return false;
        }
    }

    public void stop() {
        running.set(false);
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }
}
