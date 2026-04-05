package dev.multitode.bridge.client.net;

import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.shared.BridgeContext;
import dev.multitode.bridge.shared.net.ConnectionState;
import dev.multitode.bridge.shared.net.HelloAcceptedPacket;
import dev.multitode.bridge.shared.net.HelloPacket;
import dev.multitode.bridge.shared.net.HelloRejectedPacket;
import dev.multitode.bridge.shared.net.LocalSessionInfo;
import dev.multitode.bridge.shared.net.DisconnectPacket;
import dev.multitode.bridge.shared.net.InboundLuaMessage;
import dev.multitode.bridge.shared.net.LuaMessagePacket;
import dev.multitode.bridge.shared.net.PacketCodec;
import dev.multitode.bridge.shared.net.PacketType;
import dev.multitode.bridge.shared.net.PingPacket;
import dev.multitode.bridge.shared.net.ProtocolVersion;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

public final class ClientConnection {
    private static final TLog LOGGER = TLog.forTag("multitode/ClientConnection");
    private static final int SOCKET_TIMEOUT_MILLIS = 1000;
    private static final long PING_INTERVAL_MILLIS = 2000L;
    private static final long INACTIVITY_TIMEOUT_MILLIS = 10000L;

    private final BridgeContext context;
    private final AtomicBoolean running = new AtomicBoolean();
    private final AtomicReference<ConnectionState> state = new AtomicReference<>(ConnectionState.DISCONNECTED);
    private Thread connectionThread;
    private Socket activeSocket;
    private DataOutputStream activeOutputStream;

    public ClientConnection(BridgeContext context) {
        this.context = context;
    }

    public synchronized void start() {
        if (!state.compareAndSet(ConnectionState.DISCONNECTED, ConnectionState.CONNECTING)) {
            LOGGER.i("Client connection already started in state %s", state.get().name());
            return;
        }

        running.set(true);
        connectionThread = new Thread(this::runConnection, "multitode-client-connection");
        connectionThread.setDaemon(true);
        connectionThread.start();
    }

    public synchronized void stop() {
        state.set(ConnectionState.DISCONNECTING);
        running.set(false);
        closeActiveSocket();
        if (connectionThread != null) {
            connectionThread.interrupt();
        }
        state.set(ConnectionState.DISCONNECTED);
    }

    public ConnectionState getState() {
        return state.get();
    }

    private void runConnection() {
        String host = context.getSessionConfig().getNetwork().getHost();
        int port = context.getSessionConfig().getNetwork().getPort();

        try (Socket socket = new Socket(host, port);
             DataOutputStream outputStream = new DataOutputStream(socket.getOutputStream());
             DataInputStream inputStream = new DataInputStream(socket.getInputStream())) {
            activeSocket = socket;
            activeOutputStream = outputStream;
            socket.setSoTimeout(SOCKET_TIMEOUT_MILLIS);
            state.set(ConnectionState.HANDSHAKE);
            PacketCodec.writeHello(outputStream, new HelloPacket(
                    ProtocolVersion.CURRENT,
                    context.getSessionConfig().getPlayer().getName(),
                    context.getSessionConfig().getRole()
            ));
            LOGGER.i("Sent HELLO to %s:%s as %s", host, port, context.getSessionConfig().getPlayer().getName());

            PacketType packetType = PacketCodec.readType(inputStream);
            if (packetType == PacketType.HELLO_ACCEPTED) {
                HelloAcceptedPacket acceptedPacket = PacketCodec.readHelloAcceptedPayload(inputStream);
                state.set(ConnectionState.ACTIVE);
                LocalSessionInfo localSessionInfo = context.getSessionRegistry().getLocalSessionInfo();
                long now = System.currentTimeMillis();
                localSessionInfo.setSessionId(acceptedPacket.getSessionId());
                localSessionInfo.setLocalPlayerId(acceptedPacket.getPlayerId());
                localSessionInfo.setRemoteAddress(host + ":" + port);
                localSessionInfo.setConnectedAtMillis(now);
                localSessionInfo.setLastPacketAtMillis(now);
                localSessionInfo.setConnectionState(ConnectionState.ACTIVE);
                LOGGER.i("Connected to session %s as playerId=%s",
                        acceptedPacket.getSessionId(),
                        acceptedPacket.getPlayerId());
                runSessionLoop(host, port, inputStream, outputStream);
                return;
            }

            if (packetType == PacketType.HELLO_REJECTED) {
                HelloRejectedPacket rejectedPacket = PacketCodec.readHelloRejectedPayload(inputStream);
                state.set(ConnectionState.DISCONNECTED);
                context.getSessionRegistry().getLocalSessionInfo().setConnectionState(ConnectionState.DISCONNECTED);
                LOGGER.w("Connection rejected by host: %s", rejectedPacket.getReason());
                return;
            }

            throw new IOException("Unexpected packet during handshake: " + packetType);
        } catch (IOException exception) {
            state.set(ConnectionState.DISCONNECTED);
            context.getSessionRegistry().getLocalSessionInfo().setConnectionState(ConnectionState.DISCONNECTED);
            LOGGER.w("Failed to connect to %s:%s - %s", host, port, exception.getMessage());
        } finally {
            activeSocket = null;
            activeOutputStream = null;
            running.set(false);
        }
    }

    private void runSessionLoop(String host, int port, DataInputStream inputStream, DataOutputStream outputStream) throws IOException {
        long lastReceivedAt = System.currentTimeMillis();
        long lastPingAt = 0L;

        while (running.get()) {
            long now = System.currentTimeMillis();
            if (now - lastReceivedAt > INACTIVITY_TIMEOUT_MILLIS) {
                PacketCodec.writeDisconnect(outputStream, new DisconnectPacket("Timed out waiting for host traffic"));
                throw new IOException("Host timed out");
            }

            if (now - lastPingAt >= PING_INTERVAL_MILLIS) {
                PacketCodec.writePing(outputStream, new PingPacket(now));
                lastPingAt = now;
            }

            try {
                PacketType packetType = PacketCodec.readType(inputStream);
                lastReceivedAt = System.currentTimeMillis();
                context.getSessionRegistry().getLocalSessionInfo().setLastPacketAtMillis(lastReceivedAt);
                if (packetType == PacketType.PING) {
                    PacketCodec.readPingPayload(inputStream);
                    continue;
                }

                if (packetType == PacketType.LUA_MESSAGE) {
                    LuaMessagePacket messagePacket = PacketCodec.readLuaMessagePayload(inputStream);
                    context.getSessionRegistry().enqueueInboundLuaMessage(new InboundLuaMessage(
                            "CLIENT",
                            messagePacket.getMessageChannel(),
                            messagePacket.getMessageName(),
                            messagePacket.getSenderPlayerId(),
                            messagePacket.getPayloadJson()
                    ));
                    LOGGER.i("Queued Lua message for client channel=%s name=%s sender=%s",
                            messagePacket.getMessageChannel(),
                            messagePacket.getMessageName(),
                            messagePacket.getSenderPlayerId());
                    continue;
                }

                if (packetType == PacketType.DISCONNECT) {
                    DisconnectPacket disconnectPacket = PacketCodec.readDisconnectPayload(inputStream);
                    state.set(ConnectionState.DISCONNECTED);
                    context.getSessionRegistry().getLocalSessionInfo().setConnectionState(ConnectionState.DISCONNECTED);
                    LOGGER.i("Disconnected by host %s:%s - %s", host, port, disconnectPacket.getReason());
                    return;
                }

                throw new IOException("Unexpected packet during active session: " + packetType);
            } catch (SocketTimeoutException ignored) {
            }
        }
    }

    private synchronized void closeActiveSocket() {
        if (activeSocket == null) {
            activeOutputStream = null;
            return;
        }

        try {
            activeSocket.close();
        } catch (IOException ignored) {
        }
        activeOutputStream = null;
    }

    public synchronized boolean sendLuaMessageToHost(String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        if (!running.get() || activeOutputStream == null) {
            return false;
        }

        try {
            PacketCodec.writeLuaMessage(activeOutputStream, new LuaMessagePacket(messageChannel, messageName, senderPlayerId, payloadJson));
            return true;
        } catch (IOException exception) {
            LOGGER.w("Failed to send Lua message to host: %s", exception.getMessage());
            return false;
        }
    }
}
