package dev.multitode.bridge.host;

import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.host.net.HostServer;
import dev.multitode.bridge.shared.AbstractBridgeModule;
import dev.multitode.bridge.shared.BridgeContext;
import dev.multitode.bridge.shared.ModuleKind;

public final class HostModule extends AbstractBridgeModule {
    private static final TLog LOGGER = TLog.forTag("multitode/HostModule");

    private HostServer hostServer;

    public HostModule(BridgeContext context) {
        super(context);
    }

    @Override
    public ModuleKind getKind() {
        return ModuleKind.HOST;
    }

    @Override
    public void start() {
        LOGGER.i("Host module start for role %s", getContext().getRole().name());
        hostServer = new HostServer(getContext());
        hostServer.start();
    }

    @Override
    public void stop() {
        LOGGER.i("Host module stop for role %s", getContext().getRole().name());
        if (hostServer != null) {
            hostServer.stop();
            hostServer = null;
        }
    }

    public boolean broadcastLuaMessage(String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        if (hostServer == null) {
            return false;
        }

        return hostServer.broadcastLuaMessage(messageChannel, messageName, senderPlayerId, payloadJson);
    }

    public boolean sendLuaMessageToPeer(int playerId, String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        if (hostServer == null) {
            return false;
        }

        return hostServer.sendLuaMessageToPeer(playerId, messageChannel, messageName, senderPlayerId, payloadJson);
    }
}
