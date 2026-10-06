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
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

public final class ClientConnection {
    private static final TLog LOGGER = TLog.forTag("multitode/ClientConnection");
    private static final int SOCKET_TIMEOUT_MILLIS = 1000;
    private static final int CONNECT_TIMEOUT_MILLIS = 5000;
    private static final long CONNECT_RETRY_INTERVAL_MILLIS = 1500L;
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

        int attempt = 0;
        try {
            while (running.get()) {
                attempt++;
                Socket socket = new Socket();
                boolean activeSessionStarted = false;
                try {
                    synchronized (this) {
                        if (!running.get()) {
                            return;
                        }
                        activeSocket = socket;
                    }
                    socket.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLIS);
                    socket.setSoTimeout(SOCKET_TIMEOUT_MILLIS);
                    socket.setTcpNoDelay(true);

                    DataOutputStream outputStream = new DataOutputStream(socket.getOutputStream());
                    DataInputStream inputStream = new DataInputStream(socket.getInputStream());

                    activeOutputStream = outputStream;

                    state.set(ConnectionState.HANDSHAKE);
                    synchronized (this) {
                        PacketCodec.writeHello(outputStream, new HelloPacket(
                                ProtocolVersion.CURRENT,
                                context.getSessionConfig().getPlayer().getName(),
                                context.getSessionConfig().getRole()
                        ));
                        context.getSessionRegistry().recordPacketSent();
                    }
                    LOGGER.i("Sent HELLO to %s:%s as %s", host, port, context.getSessionConfig().getPlayer().getName());

                    PacketType packetType = PacketCodec.readType(inputStream);
                    if (packetType == PacketType.HELLO_ACCEPTED) {
                        HelloAcceptedPacket acceptedPacket = PacketCodec.readHelloAcceptedPayload(inputStream);
                        context.getSessionRegistry().recordPacketReceived();
                        activeSessionStarted = true;
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
                        attempt = 0;
                        runSessionLoop(host, port, inputStream, outputStream);
                    } else if (packetType == PacketType.HELLO_REJECTED) {
                        HelloRejectedPacket rejectedPacket = PacketCodec.readHelloRejectedPayload(inputStream);
                        context.getSessionRegistry().recordPacketReceived();
                        state.set(ConnectionState.DISCONNECTED);
                        context.getSessionRegistry().getLocalSessionInfo().setConnectionState(ConnectionState.DISCONNECTED);
                        LOGGER.w("Connection rejected by host: %s", rejectedPacket.getReason());
                        return;
                    } else {
                        throw new IOException("Unexpected packet during handshake: " + packetType);
                    }
                } catch (IOException exception) {
                    if (running.get()) {
                        LOGGER.w("Connection to %s:%s lost - %s", host, port, exception.getMessage());
                    }
                } finally {
                    try {
                        socket.close();
                    } catch (IOException ignored) {
                    }
                    if (activeSocket == socket) {
                        activeSocket = null;
                        activeOutputStream = null;
                    }
                }

                if (!running.get()) {
                    return;
                }
                if (activeSessionStarted) {
                    enqueueLocalPlayerDisconnected();
                }

                state.set(ConnectionState.CONNECTING);
                context.getSessionRegistry().getLocalSessionInfo().setConnectionState(ConnectionState.CONNECTING);
                LOGGER.i("Reconnecting to %s:%s in %sms (attempt %s)",
                        host,
                        port,
                        CONNECT_RETRY_INTERVAL_MILLIS,
                        attempt + 1);
                try {
                    Thread.sleep(CONNECT_RETRY_INTERVAL_MILLIS);
                } catch (InterruptedException exception) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
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
                synchronized (this) {
                    PacketCodec.writeDisconnect(outputStream, new DisconnectPacket("Timed out waiting for host traffic"));
                    context.getSessionRegistry().recordPacketSent();
                }
                throw new IOException("Host timed out");
            }

            if (now - lastPingAt >= PING_INTERVAL_MILLIS) {
                synchronized (this) {
                    PacketCodec.writePing(outputStream, new PingPacket(now));
                    context.getSessionRegistry().recordPacketSent();
                }
                lastPingAt = now;
            }

            try {
                PacketType packetType = PacketCodec.readType(inputStream);
                lastReceivedAt = System.currentTimeMillis();
                context.getSessionRegistry().getLocalSessionInfo().setLastPacketAtMillis(lastReceivedAt);
                if (packetType == PacketType.PING) {
                    PacketCodec.readPingPayload(inputStream);
                    context.getSessionRegistry().recordPacketReceived();
                    continue;
                }

                if (packetType == PacketType.LUA_MESSAGE) {
                    LuaMessagePacket messagePacket = PacketCodec.readLuaMessagePayload(inputStream);
                    context.getSessionRegistry().recordPacketReceived();
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
                    context.getSessionRegistry().recordPacketReceived();
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
        if (!running.get() || state.get() != ConnectionState.ACTIVE || activeOutputStream == null) {
            return false;
        }

        try {
            PacketCodec.writeLuaMessage(activeOutputStream, new LuaMessagePacket(messageChannel, messageName, senderPlayerId, payloadJson));
            context.getSessionRegistry().recordPacketSent();
            return true;
        } catch (IOException exception) {
            LOGGER.w("Failed to send Lua message to host: %s", exception.getMessage());
            return false;
        }
    }

    private void enqueueLocalPlayerDisconnected() {
        LocalSessionInfo localSessionInfo = context.getSessionRegistry().getLocalSessionInfo();
        context.getSessionRegistry().enqueueInboundLuaMessage(new InboundLuaMessage(
                "CLIENT",
                "system",
                "player_disconnected",
                localSessionInfo.getLocalPlayerId(),
                InboundLuaMessage.quoteJson(context.getSessionConfig().getPlayer().getName())
        ));
    }
}
