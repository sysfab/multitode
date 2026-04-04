package dev.multitode.bridge.host.net;

import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.shared.BridgeContext;

import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public final class HostServer {
    private static final TLog LOGGER = TLog.forTag("multitode/HostServer");

    private final BridgeContext context;
    private final HostSession hostSession;
    private final AtomicBoolean running = new AtomicBoolean();
    private ServerSocket serverSocket;
    private Thread acceptThread;

    public HostServer(BridgeContext context) {
        this.context = context;
        this.hostSession = new HostSession(context);
    }

    public synchronized void start() {
        if (running.get()) {
            LOGGER.i("Host server already running on port %s", context.getSessionConfig().getNetwork().getPort());
            return;
        }

        try {
            serverSocket = new ServerSocket(context.getSessionConfig().getNetwork().getListenPort());
            running.set(true);
            acceptThread = new Thread(this::acceptLoop, "multitode-host-accept");
            acceptThread.setDaemon(true);
            acceptThread.start();
            LOGGER.i("Host server listening on %s:%s", serverSocket.getInetAddress().getHostAddress(), serverSocket.getLocalPort());
        } catch (IOException exception) {
            throw new IllegalStateException("Failed to start host server on port " + context.getSessionConfig().getNetwork().getListenPort(), exception);
        }
    }

    public synchronized void stop() {
        if (!running.getAndSet(false)) {
            return;
        }

        closeServerSocket();
        if (acceptThread != null) {
            acceptThread.interrupt();
        }
        LOGGER.i("Host server stopped");
    }

    public boolean isRunning() {
        return running.get();
    }

    public boolean broadcastLuaMessage(String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        return hostSession.broadcastLuaMessage(messageChannel, messageName, senderPlayerId, payloadJson);
    }

    public boolean sendLuaMessageToPeer(int playerId, String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        return hostSession.sendLuaMessageToPeer(playerId, messageChannel, messageName, senderPlayerId, payloadJson);
    }

    private void acceptLoop() {
        while (running.get()) {
            try {
                Socket socket = serverSocket.accept();
                HostClientConnection connection = new HostClientConnection(hostSession, socket);
                connection.start();
            } catch (SocketException exception) {
                if (running.get()) {
                    LOGGER.e("Host accept loop socket error: %s", exception.getMessage());
                }
                return;
            } catch (IOException exception) {
                LOGGER.e("Host accept loop failed: %s", exception.getMessage());
            }
        }
    }

    private void closeServerSocket() {
        if (serverSocket == null) {
            return;
        }

        try {
            serverSocket.close();
        } catch (IOException exception) {
            LOGGER.w("Failed to close host server socket: %s", exception.getMessage());
        }
    }
}
