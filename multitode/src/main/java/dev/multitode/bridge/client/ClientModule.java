package dev.multitode.bridge.client;

import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.client.net.ClientConnection;
import dev.multitode.bridge.shared.AbstractBridgeModule;
import dev.multitode.bridge.shared.BridgeContext;
import dev.multitode.bridge.shared.ModuleKind;

public final class ClientModule extends AbstractBridgeModule {
    private static final TLog LOGGER = TLog.forTag("multitode/ClientModule");

    private ClientConnection clientConnection;

    public ClientModule(BridgeContext context) {
        super(context);
    }

    @Override
    public ModuleKind getKind() {
        return ModuleKind.CLIENT;
    }

    @Override
    public void start() {
        LOGGER.i("Client module start for role %s", getContext().getRole().name());

        clientConnection = new ClientConnection(getContext());
        clientConnection.start();
    }

    @Override
    public void stop() {
        LOGGER.i("Client module stop for role %s", getContext().getRole().name());
        if (clientConnection != null) {
            clientConnection.stop();
            clientConnection = null;
        }
    }

    public boolean sendLuaMessageToHost(String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        if (clientConnection == null) {
            return false;
        }

        return clientConnection.sendLuaMessageToHost(messageChannel, messageName, senderPlayerId, payloadJson);
    }
}
