package dev.multitode.bridge.shared;

import com.esotericsoftware.kryo.io.Input;
import com.esotericsoftware.kryo.io.Output;
import com.prineside.tdi2.Game;
import com.prineside.tdi2.GameSystemProvider;
import com.prineside.tdi2.Screen;
import com.prineside.tdi2.screens.GameScreen;
import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.Bridge;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;

public final class BridgeApi {
    private static final TLog LOGGER = TLog.forTag("multitode/BridgeApi");
    public static final BridgeApi INSTANCE = new BridgeApi();
    private static final Path CONFIG_PATH = Paths.get("cache", "script-data", "multitode", "session-config.properties");

    private static Bridge bridge;
    private final SessionConfig sessionConfig = new SessionConfig();
    private final Map<String, Integer> approvedQueuedActionCounts = new HashMap<>();
    private final Map<Integer, String> stateHashSamples = new HashMap<>();
    private String pendingStartupSyncJson;

    public BridgeApi() {
    }

    public synchronized Bridge initialize(String roleName) {
        configureRole(roleName);
        return initialize();
    }

    public synchronized Bridge initialize() {
        if (bridge != null) {
            LOGGER.i("Bridge already initialized as %s", bridge.getContext().getRole().name());
            return bridge;
        }

        validateConfigOrThrow();
        LOGGER.i("Initializing bridge with config %s", sessionConfig.describe());
        bridge = Bridge.create(sessionConfig);
        return bridge;
    }

    public synchronized Bridge start(String roleName) {
        configureRole(roleName);
        return start();
    }

    public synchronized Bridge start() {
        Bridge initializedBridge = initialize();
        LOGGER.i("Starting bridge through API");
        initializedBridge.start();
        return initializedBridge;
    }

    public synchronized void stop() {
        if (bridge == null) {
            LOGGER.i("Stop requested before bridge initialization");
            return;
        }

        LOGGER.i("Stopping bridge through API");
        bridge.stop();
        bridge = null;
    }

    public synchronized boolean isInitialized() {
        return bridge != null;
    }

    public synchronized Bridge getBridge() {
        return bridge;
    }

    public synchronized String getVersion() {
        return Bridge.getVersion();
    }

    public synchronized String getRoleName() {
        if (bridge == null) {
            return null;
        }

        return bridge.getContext().getRole().name();
    }

    public synchronized String getLifecycleStateName() {
        if (bridge == null) {
            return null;
        }

        return bridge.getContext().getLifecycleState().name();
    }

    public synchronized void resetConfig() {
        sessionConfig.setRole(SessionRole.HOST_AND_CLIENT);
        sessionConfig.getPlayer().setName("Player");
        sessionConfig.getNetwork().setHost("0.0.0.0");
        sessionConfig.getNetwork().setPort(24812);
    }

    public synchronized void configureRole(String roleName) {
        sessionConfig.setRoleName(roleName);
    }

    public synchronized String getConfiguredRoleName() {
        return sessionConfig.getRole().name();
    }

    public synchronized void setPlayerName(String name) {
        sessionConfig.getPlayer().setName(name);
    }

    public synchronized String getPlayerName() {
        return sessionConfig.getPlayer().getName();
    }

    public synchronized void setHost(String host) {
        sessionConfig.getNetwork().setHost(host);
    }

    public synchronized String getHost() {
        return sessionConfig.getNetwork().getHost();
    }

    public synchronized void setPort(int port) {
        sessionConfig.getNetwork().setPort(port);
    }

    public synchronized int getPort() {
        return sessionConfig.getNetwork().getPort();
    }

    public synchronized String describeConfig() {
        return sessionConfig.describe();
    }

    public synchronized String getConfigFilePath() {
        return CONFIG_PATH.toString().replace('\\', '/');
    }

    public synchronized void saveConfig() {
        Properties properties = new Properties();
        properties.setProperty("role", sessionConfig.getRole().name());
        properties.setProperty("playerName", sessionConfig.getPlayer().getName());
        properties.setProperty("host", sessionConfig.getNetwork().getHost());
        properties.setProperty("port", Integer.toString(sessionConfig.getNetwork().getPort()));

        try {
            Path parent = CONFIG_PATH.getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }

            try (OutputStream outputStream = Files.newOutputStream(CONFIG_PATH)) {
                properties.store(outputStream, "Multitode session config");
            }
        } catch (IOException exception) {
            throw new IllegalStateException("Failed to save config to " + getConfigFilePath(), exception);
        }

        LOGGER.i("Saved config to %s", getConfigFilePath());
    }

    public synchronized boolean loadConfig() {
        if (!Files.exists(CONFIG_PATH)) {
            LOGGER.i("Config file does not exist: %s", getConfigFilePath());
            return false;
        }

        Properties properties = new Properties();
        try (InputStream inputStream = Files.newInputStream(CONFIG_PATH)) {
            properties.load(inputStream);
        } catch (IOException exception) {
            throw new IllegalStateException("Failed to load config from " + getConfigFilePath(), exception);
        }

        if (properties.containsKey("role")) {
            sessionConfig.setRoleName(properties.getProperty("role"));
        }
        if (properties.containsKey("playerName")) {
            sessionConfig.getPlayer().setName(properties.getProperty("playerName"));
        }
        if (properties.containsKey("host")) {
            sessionConfig.getNetwork().setHost(properties.getProperty("host"));
        }
        if (properties.containsKey("port")) {
            sessionConfig.getNetwork().setPort(parseIntProperty(properties, "port", sessionConfig.getNetwork().getPort()));
        }

        LOGGER.i("Loaded config from %s: %s", getConfigFilePath(), describeConfig());
        return true;
    }

    public synchronized boolean isConfigValid() {
        return sessionConfig.isValid();
    }

    public synchronized String getConfigValidationError() {
        return sessionConfig.getValidationError();
    }

    public synchronized boolean isSessionActive() {
        if (bridge == null) {
            return false;
        }

        return bridge.getContext().getSessionRegistry().getLocalSessionInfo().getConnectionState() == dev.multitode.bridge.shared.net.ConnectionState.ACTIVE;
    }

    public synchronized String getConnectionStateName() {
        if (bridge == null) {
            return null;
        }

        return bridge.getContext().getSessionRegistry().getLocalSessionInfo().getConnectionState().name();
    }

    public synchronized String getSessionId() {
        if (bridge == null) {
            return null;
        }

        return bridge.getContext().getSessionRegistry().getLocalSessionInfo().getSessionId();
    }

    public synchronized int getLocalPlayerId() {
        if (bridge == null) {
            return 0;
        }

        return bridge.getContext().getSessionRegistry().getLocalSessionInfo().getLocalPlayerId();
    }

    public synchronized int getConnectedPeerCount() {
        if (bridge == null) {
            return 0;
        }

        return bridge.getContext().getSessionRegistry().getConnectedPeerCount();
    }

    public synchronized String describeSession() {
        if (bridge == null) {
            return "session not initialized";
        }

        return bridge.getContext().getSessionRegistry().describe();
    }

    public synchronized String describePeers() {
        if (bridge == null) {
            return "session not initialized";
        }

        return bridge.getContext().getSessionRegistry().describePeers();
    }

    public synchronized boolean hasPeers() {
        return getConnectedPeerCount() > 0;
    }

    public synchronized boolean sendLuaMessageToHost(String messageChannel, String messageName, String payloadJson) {
        requireUserChannel(messageChannel);
        Bridge currentBridge = requireBridge();
        return currentBridge.getClientModule().sendLuaMessageToHost(messageChannel, messageName, getEffectiveSenderPlayerId(), payloadJson);
    }

    public synchronized boolean broadcastLuaMessage(String messageChannel, String messageName, String payloadJson) {
        requireUserChannel(messageChannel);
        Bridge currentBridge = requireBridge();
        return currentBridge.getHostModule().broadcastLuaMessage(messageChannel, messageName, getEffectiveSenderPlayerId(), payloadJson);
    }

    public synchronized boolean sendLuaMessageToPeer(int playerId, String messageChannel, String messageName, String payloadJson) {
        requireUserChannel(messageChannel);
        Bridge currentBridge = requireBridge();
        return currentBridge.getHostModule().sendLuaMessageToPeer(playerId, messageChannel, messageName, getEffectiveSenderPlayerId(), payloadJson);
    }

    public synchronized String pollInboundLuaMessageJson() {
        Bridge currentBridge = bridge;
        if (currentBridge == null) {
            return null;
        }

        dev.multitode.bridge.shared.net.InboundLuaMessage message = currentBridge.getContext().getSessionRegistry().pollInboundLuaMessage();
        if (message == null) {
            return null;
        }

        return message.toJson();
    }

    public synchronized int getPendingLuaMessageCount() {
        if (bridge == null) {
            return 0;
        }

        return bridge.getContext().getSessionRegistry().getPendingLuaMessageCount();
    }

    public synchronized void approveQueuedAction(int targetTick, String actionString) {
        String key = targetTick + ":" + actionString;
        approvedQueuedActionCounts.put(key, approvedQueuedActionCounts.getOrDefault(key, 0) + 1);
    }

    public synchronized boolean consumeApprovedQueuedAction(int targetTick, String actionString) {
        String key = targetTick + ":" + actionString;
        Integer remaining = approvedQueuedActionCounts.get(key);
        if (remaining == null || remaining <= 0) {
            return false;
        }

        if (remaining == 1) {
            approvedQueuedActionCounts.remove(key);
        } else {
            approvedQueuedActionCounts.put(key, remaining - 1);
        }

        return true;
    }

    public synchronized void resetApprovedQueuedActions() {
        approvedQueuedActionCounts.clear();
    }

    public synchronized void saveStateHashSampleJson(int tick, String sampleJson) {
        stateHashSamples.put(tick, sampleJson);
    }

    public synchronized String getStateHashSampleJson(int tick) {
        return stateHashSamples.get(tick);
    }

    public synchronized void clearStateHashSamples() {
        stateHashSamples.clear();
    }

    public synchronized void savePendingStartupSyncJson(String payloadJson) {
        pendingStartupSyncJson = payloadJson;
    }

    public synchronized String getPendingStartupSyncJson() {
        return pendingStartupSyncJson;
    }

    public synchronized void clearPendingStartupSync() {
        pendingStartupSyncJson = null;
    }

    public synchronized String captureCurrentGameSnapshotBase64() {
        Screen currentScreen = Game.i.screenManager.getCurrentScreen();
        if (!(currentScreen instanceof GameScreen gameScreen) || gameScreen.S == null) {
            throw new IllegalStateException("Current screen is not an active GameScreen");
        }

        ByteArrayOutputStream byteStream = new ByteArrayOutputStream();
        Output output = new Output(byteStream);
        gameScreen.S.serialize(output);
        output.close();
        return Base64.getEncoder().encodeToString(byteStream.toByteArray());
    }

    public synchronized void restoreGameSnapshotBase64(String snapshotBase64, long gameStartTimestamp) {
        if (snapshotBase64 == null || snapshotBase64.isBlank()) {
            throw new IllegalArgumentException("snapshotBase64 must not be blank");
        }

        byte[] bytes = Base64.getDecoder().decode(snapshotBase64);
        Input input = new Input(new ByteArrayInputStream(bytes));
        GameSystemProvider systems = GameSystemProvider.unserialize(input);
        systems.createAndSetupNonStateAffectingSystemsAfterDeserialization();
        GameScreen screen = new GameScreen(systems, gameStartTimestamp);
        Game.i.screenManager.setScreen(screen);

        systems.gameState.setGameSpeed(1.0f);
    }

    private void validateConfigOrThrow() {
        String validationError = sessionConfig.getValidationError();
        if (validationError == null) {
            return;
        }

        throw new IllegalStateException("Invalid session config: " + validationError);
    }

    private Bridge requireBridge() {
        if (bridge == null) {
            throw new IllegalStateException("Bridge is not initialized");
        }

        return bridge;
    }

    private int getEffectiveSenderPlayerId() {
        int localPlayerId = getLocalPlayerId();
        if (localPlayerId > 0) {
            return localPlayerId;
        }

        return 0;
    }

    private void requireUserChannel(String messageChannel) {
        if (messageChannel == null || messageChannel.isBlank()) {
            throw new IllegalArgumentException("messageChannel must not be blank");
        }
        if ("system".equals(messageChannel)) {
            throw new IllegalArgumentException("messageChannel 'system' is reserved");
        }
    }

    private int parseIntProperty(Properties properties, String key, int defaultValue) {
        String value = properties.getProperty(key);
        if (value == null || value.isBlank()) {
            return defaultValue;
        }

        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException exception) {
            throw new IllegalStateException("Invalid integer for config key '" + key + "': " + value, exception);
        }
    }
}
