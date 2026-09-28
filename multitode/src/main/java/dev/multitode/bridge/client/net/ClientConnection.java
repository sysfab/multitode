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
    private static final long PING_INTERVAL_MILLIS = 2000L;
    private static final long INACTIVITY_TIMEOUT_MILLIS = 10000L;
    private static final int MAX_RECONNECT_ATTEMPTS = 5;
    private static final long RECONNECT_BASE_DELAY_MILLIS = 2000L;

    private final BridgeContext context;
    private final AtomicBoolean running = new AtomicBoolean();
    private final AtomicReference<ConnectionState> state = new AtomicReference<>(ConnectionState.DISCONNECTED);
    private Thread connectionThread;
    private volatile Socket activeSocket;
    private volatile DataOutputStream activeOutputStream;

    public ClientConnection(BridgeContext context) {
        this.context = context;
    }

    public synchronized void start() {
        if (!state.compareAndSet(ConnectionState.DISCONNECTED, ConnectionState.CONNECTING)) {
            LOGGER.i("Client connection already started in state %s", state.get().name());
            return;
        }

        running.set(true);
        connectionThread = new Thread(this::runConnectionLoop, "multitode-client-connection");
        connectionThread.setDaemon(true);
        connectionThread.start();
    }

    public synchronized void stop() {
        state.set(ConnectionState.DISCONNECTING);
        running.set(false);
        // Tell the host we are leaving so it can drop us from the lobby
        // immediately instead of waiting out the inactivity timeout.
        DataOutputStream out = activeOutputStream;
        if (out != null) {
            try {
                PacketCodec.writeDisconnect(out, new DisconnectPacket("Client disconnecting"));
            } catch (Exception ignored) {
            }
        }
        closeActiveSocket();
        if (connectionThread != null) {
            connectionThread.interrupt();
        }
        state.set(ConnectionState.DISCONNECTED);
    }

    public ConnectionState getState() {
        return state.get();
    }

    private void runConnectionLoop() {
        String host = context.getSessionConfig().getNetwork().getHost();
        int port = context.getSessionConfig().getNetwork().getPort();
        int attempt = 0;

        while (running.get()) {
            attempt++;
            LOGGER.i("Connection attempt %d to %s:%s", attempt, host, port);

            try {
                attemptConnection(host, port);
            } catch (IOException exception) {
                LOGGER.w("Connection attempt %d failed: %s", attempt, exception.getMessage());
            }

            if (!running.get()) {
                break;
            }

            if (state.get() == ConnectionState.ACTIVE) {
                attempt = 0;
                continue;
            }

            if (attempt >= MAX_RECONNECT_ATTEMPTS) {
                LOGGER.e("Max reconnect attempts (%d) reached, giving up", MAX_RECONNECT_ATTEMPTS);
                break;
            }

            long delay = RECONNECT_BASE_DELAY_MILLIS * Math.min(attempt, 5);
            LOGGER.i("Reconnecting in %d ms...", delay);
            try {
                Thread.sleep(delay);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }

        state.set(ConnectionState.DISCONNECTED);
        context.getSessionRegistry().getLocalSessionInfo().setConnectionState(ConnectionState.DISCONNECTED);
        activeSocket = null;
        activeOutputStream = null;
        running.set(false);
        LOGGER.i("Client connection thread exited");
    }

    private void attemptConnection(String host, int port) throws IOException {
        Socket socket = new Socket();
        try {
            socket.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLIS);
            socket.setSoTimeout(SOCKET_TIMEOUT_MILLIS);
            // Small, frequent gameplay packets: Nagle would batch them and add
            // latency on top of the action lead.
            try {
                socket.setTcpNoDelay(true);
            } catch (IOException ignored) {
            }
            activeSocket = socket;

            DataOutputStream outputStream = new DataOutputStream(socket.getOutputStream());
            DataInputStream inputStream = new DataInputStream(socket.getInputStream());
            activeOutputStream = outputStream;

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
            throw exception;
        } finally {
            closeActiveSocket();
            try {
                socket.close();
            } catch (IOException ignored) {
            }
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
                synchronized (this) {
                    PacketCodec.writePing(outputStream, new PingPacket(now));
                }
                lastPingAt = now;
            }

            try {
                PacketType packetType = PacketCodec.readType(inputStream);
                lastReceivedAt = System.currentTimeMillis();
                context.getSessionRegistry().getLocalSessionInfo().setLastPacketAtMillis(lastReceivedAt);
                if (packetType == PacketType.PING) {
                    PingPacket pingPacket = PacketCodec.readPingPayload(inputStream);
                    long sentAt = pingPacket.getSentAtMillis();
                    if (sentAt > 0) {
                        // A request: answer with the negated timestamp so the
                        // sender can measure RTT. Replies are never answered.
                        synchronized (this) {
                            PacketCodec.writePing(outputStream, new PingPacket(-sentAt));
                        }
                    } else if (sentAt < 0) {
                        // A reply to our own ping: sentAt is -sentTime.
                        long rtt = System.currentTimeMillis() + sentAt;
                        if (rtt >= 0 && rtt < 60000) {
                            context.getSessionRegistry().getLocalSessionInfo().setLastRttMillis(rtt);
                        }
                    }
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
        Socket socket = activeSocket;
        activeOutputStream = null;
        activeSocket = null;
        if (socket != null) {
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
    }

    public synchronized boolean sendLuaMessageToHost(String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        DataOutputStream out = activeOutputStream;
        if (!running.get() || out == null) {
            return false;
        }

        try {
            PacketCodec.writeLuaMessage(out, new LuaMessagePacket(messageChannel, messageName, senderPlayerId, payloadJson));
            return true;
        } catch (IOException exception) {
            LOGGER.w("Failed to send Lua message to host: %s", exception.getMessage());
            return false;
        }
    }
}
