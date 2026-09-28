package dev.multitode.bridge.shared;

import com.esotericsoftware.kryo.io.Input;
import com.esotericsoftware.kryo.io.Output;
import com.badlogic.gdx.graphics.g2d.ParticleEffectPool;
import com.prineside.tdi2.Game;
import com.prineside.tdi2.GameSystemProvider;
import com.prineside.tdi2.Screen;
import com.prineside.tdi2.screens.GameScreen;
import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.Bridge;
import dev.multitode.bridge.shared.net.LocalSessionInfo;

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
import java.util.List;
import java.util.Map;
import java.util.Properties;

import dev.multitode.bridge.shared.net.PeerInfo;

public final class BridgeApi {
    private static final TLog LOGGER = TLog.forTag("multitode/BridgeApi");
    public static final BridgeApi INSTANCE = new BridgeApi();
    private static final Path CONFIG_PATH = resolveConfigPath();

    private static Path resolveConfigPath() {
        // Allows two game instances on one machine to use separate configs.
        // System property first (explicit -Dmultitode.config=... on the java
        // command line, immune to environment inheritance quirks), then env.
        String override = System.getProperty("multitode.config");
        if (override == null || override.isBlank()) {
            override = System.getenv("MULTITODE_CONFIG_PATH");
        }
        if (override != null && !override.isBlank()) {
            return Paths.get(override.trim());
        }
        return Paths.get("cache", "script-data", "multitode", "session-config.properties");
    }

    private static volatile Bridge bridge;
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

    // ------------------------------------------------------------------ tiles
    // These live in Java because the Lua whitelist exposes no safe coordinate ->
    // Tile lookup: MapSystem only offers getTileAndNeighbours(int,int,Array) (Lua
    // cannot build that Array) and setHoveredTileAtPos mutates the game's hover
    // state, which left MapSystem.drawBatch with a null highlightParticleA and
    // crashed the game. Here we can call Map.getTile(x, y) directly.

    private GameScreen currentGameScreen() {
        Screen screen = Game.i.screenManager.getCurrentScreen();
        if (screen instanceof GameScreen) {
            return (GameScreen) screen;
        }
        return null;
    }

    /** Highlight a tile by grid coordinates. Returns false if there is no such tile. */
    public synchronized boolean highlightTileAt(int tileX, int tileY) {
        try {
            GameScreen screen = currentGameScreen();
            if (screen == null || screen.S == null || screen.S.map == null) {
                return false;
            }
            com.prineside.tdi2.Map map = screen.S.map.getMap();
            if (map == null) {
                return false;
            }
            com.prineside.tdi2.Tile tile = map.getTile(tileX, tileY);
            if (tile == null) {
                return false;
            }
            screen.S.map.highlightTile(tile);

            // Position the highlight particles IMMEDIATELY. The engine only assigns
            // their position inside MapSystem.drawBatch, and only for tiles it is
            // currently drawing - so a highlighted tile that is not being drawn
            // leaves its particles at the default position (world origin 0,0, the
            // map's bottom-left corner). That is the particle pile. Tile centres are
            // at (x * 128 + 64, y * 128 + 64), same as the engine's own math.
            float worldX = tileX * 128f + 64f;
            float worldY = tileY * 128f + 64f;
            try {
                if (tile.highlightParticleA != null) {
                    tile.highlightParticleA.setPosition(worldX, worldY);
                }
                if (tile.highlightParticleB != null) {
                    tile.highlightParticleB.setPosition(worldX, worldY);
                }
            } catch (Throwable ignoredPositioning) {
                // positioning is cosmetic - never let it break the mark
            }
            return true;
        } catch (Throwable throwable) {
            LOGGER.w("highlightTileAt(%d,%d) failed: %s", tileX, tileY, throwable.toString());
            return false;
        }
    }

    /**
     * Show the warning ("NOT here") particle at a tile, but only if that tile
     * actually exists on the map. The Lua side cannot validate coordinates, and an
     * out-of-range position made the particle pile up in the map's bottom-left
     * corner instead of failing.
     */
    public synchronized boolean showTileWarningParticleAt(int tileX, int tileY) {
        try {
            GameScreen screen = currentGameScreen();
            if (screen == null || screen.S == null || screen.S.map == null) {
                return false;
            }
            com.prineside.tdi2.Map map = screen.S.map.getMap();
            if (map == null || map.getTile(tileX, tileY) == null) {
                return false;
            }
            screen.S.map.showTileWarningParticle(tileX, tileY);
            return true;
        } catch (Throwable throwable) {
            LOGGER.w("showTileWarningParticleAt(%d,%d) failed: %s", tileX, tileY, throwable.toString());
            return false;
        }
    }

    // ------------------------------------------------------------- tile marks
    // The implementation lives in dev.multitode.gameplay.TileMarks: owning mark
    // particles and their lifetimes is plain in-game work, not networking, so it
    // stays out of the bridge and shows up here only as the Lua-facing surface.

    private final dev.multitode.gameplay.TileMarks gameplayMarks = new dev.multitode.gameplay.TileMarks();

    /** Add a mark with its own lifetime (durationMs), managed by the gameplay side. */
    public synchronized boolean addTileMark(int tileX, int tileY, boolean warning, int durationMs) {
        return gameplayMarks.addTileMark(tileX, tileY, warning, durationMs);
    }

    /** Called from the render hook so mark lifetimes are honoured every frame. */
    public synchronized void tickTileMarks() {
        gameplayMarks.tickTileMarks();
    }

    public synchronized int getTileMarkCount() {
        return gameplayMarks.getTileMarkCount();
    }

    /** Put everyone's still-live marks back after a level snapshot restore. */
    public synchronized int respawnTileMarks() {
        return gameplayMarks.respawnTileMarks();
    }

    /** Finish every mark now (lets each particle play out and return to its pool). */
    public synchronized void clearTileMarks() {
        gameplayMarks.clearTileMarks();
    }

    /** Remove a single mark at (tileX, tileY) if present (erase mode). */
    public synchronized boolean removeTileMarkAt(int tileX, int tileY) {
        return gameplayMarks.removeTileMarkAt(tileX, tileY);
    }

    /** Update (or create) a remote player's cursor marker at a tile. */
    public synchronized void setRemoteCursor(int playerId, int tileX, int tileY) {
        gameplayMarks.setRemoteCursor(playerId, tileX, tileY);
    }

    /** Drop a remote player's cursor (player left / stopped sending). */
    public synchronized void clearRemoteCursor(int playerId) {
        gameplayMarks.clearRemoteCursor(playerId);
    }

    /** Drop every remote cursor (level change / disconnect). */
    public synchronized void clearAllRemoteCursors() {
        gameplayMarks.clearAllRemoteCursors();
    }

    /** Safe clear of all tile highlights. */
    public synchronized void clearTileHighlights() {
        try {
            GameScreen screen = currentGameScreen();
            if (screen != null && screen.S != null && screen.S.map != null) {
                screen.S.map.removeHighlights();
            }
        } catch (Throwable throwable) {
            LOGGER.w("clearTileHighlights failed: %s", throwable.toString());
        }
    }

    /** Tile under the mouse cursor; Integer.MIN_VALUE when it cannot be resolved. */
    public synchronized int getCursorTileX() {
        return cursorTile()[0];
    }

    public synchronized int getCursorTileY() {
        return cursorTile()[1];
    }

    private int[] cursorTile() {
        try {
            GameScreen screen = currentGameScreen();
            if (screen == null || screen.S == null || screen.S._render == null) {
                return new int[] { Integer.MIN_VALUE, Integer.MIN_VALUE };
            }
            com.badlogic.gdx.graphics.OrthographicCamera camera = screen.S._render.getCamera();
            if (camera == null) {
                return new int[] { Integer.MIN_VALUE, Integer.MIN_VALUE };
            }
            com.badlogic.gdx.math.Vector3 point = new com.badlogic.gdx.math.Vector3(
                    com.badlogic.gdx.Gdx.input.getX(), com.badlogic.gdx.Gdx.input.getY(), 0f);
            camera.unproject(point, 0f, 0f,
                    com.badlogic.gdx.Gdx.graphics.getWidth(), com.badlogic.gdx.Gdx.graphics.getHeight());
            return new int[] {
                    (int) Math.floor(point.x / 128f),
                    (int) Math.floor(point.y / 128f)
            };
        } catch (Throwable throwable) {
            return new int[] { Integer.MIN_VALUE, Integer.MIN_VALUE };
        }
    }

    // --------------------------------------------------------------- settings
    // Persisted so user choices (sync precision, marks visibility, key bind...)
    // survive restarts. Stored in settings.properties next to the session config.

    private static final Path SETTINGS_PATH =
            CONFIG_PATH.resolveSibling(CONFIG_PATH.getFileName().toString().replace(".properties", "") + "-settings.properties");
    private final java.util.LinkedHashMap<String, String> settings = new java.util.LinkedHashMap<String, String>();
    private boolean settingsLoaded = false;

    private synchronized void ensureSettingsLoaded() {
        if (settingsLoaded) {
            return;
        }
        settingsLoaded = true;
        try {
            if (Files.exists(SETTINGS_PATH)) {
                java.util.Properties properties = new java.util.Properties();
                try (InputStream input = Files.newInputStream(SETTINGS_PATH)) {
                    properties.load(input);
                }
                for (String name : properties.stringPropertyNames()) {
                    settings.put(name, properties.getProperty(name));
                }
            }
        } catch (Throwable throwable) {
            LOGGER.w("Could not read settings: %s", throwable.toString());
        }
    }

    private synchronized void persistSettings() {
        try {
            java.util.Properties properties = new java.util.Properties();
            for (java.util.Map.Entry<String, String> entry : settings.entrySet()) {
                properties.setProperty(entry.getKey(), entry.getValue());
            }
            try (OutputStream output = Files.newOutputStream(SETTINGS_PATH)) {
                properties.store(output, "Multitode settings");
            }
        } catch (Throwable throwable) {
            LOGGER.w("Could not save settings: %s", throwable.toString());
        }
    }

    public synchronized void setSetting(String key, String value) {
        ensureSettingsLoaded();
        settings.put(key, value == null ? "" : value);
        persistSettings();
    }

    public synchronized String getSetting(String key, String defaultValue) {
        ensureSettingsLoaded();
        String value = settings.get(key);
        return value == null ? defaultValue : value;
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

    public synchronized int[] getConnectedPeerIds() {
        if (bridge == null) {
            return new int[0];
        }

        List<PeerInfo> peers = bridge.getContext().getSessionRegistry().getPeers();
        int[] ids = new int[peers.size()];
        for (int i = 0; i < peers.size(); i++) {
            ids[i] = peers.get(i).getPlayerId();
        }
        return ids;
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

    /** How far either side may miss the agreed tick before an approval is considered lost. */
    private static final int TICK_TOLERANCE = 30;

    /**
     * Upgrades must land on the EXACT agreed tick.
     *
     * <p>Two fast "upgrade, upgrade" clicks queued on the same tick consume in order; a
     * +/-30 near-miss lets one side apply an upgrade 20 ticks earlier than the other,
     * which is a real divergence (tower level 1 vs 2) that the hash check then sees.
     * The tolerance exists for slow/racy delivery of bulk actions (builds, waves), not
     * for these, so upgrades get an exact match while everything else keeps the window.
     * The action string is the engine's toString, e.g. "UpgradeTower 7 2".</p>
     */
    private static boolean isUpgradeClassAction(String actionString) {
        return actionString.startsWith("UpgradeTower")
                || actionString.startsWith("UpgradeMiner")
                || actionString.startsWith("GlobalUpgradeTower")
                || actionString.startsWith("GlobalUpgradeMiner")
                || actionString.startsWith("CoreUpgrade");
    }

    /**
     * Consume an approved action, tolerating a small tick difference.
     *
     * <p>The two sides have to agree on the tick an action lands on, but they learn about
     * it from different places: the host stamps an "effective" tick, while a side consumes
     * when its own simulation actually reaches the action. If a push arrives late the game
     * may execute it a few ticks off, and an exact-only lookup then missed - the action was
     * silently re-requested instead of applied, and the worlds drifted apart while nothing
     * looked illegal. A near-miss is still the same action, so accept it inside a small
     * window and say so in the log. Upgrade-class actions are exempt (exact tick only).</p>
     */
    public synchronized boolean consumeApprovedQueuedAction(int targetTick, String actionString) {
        if (consumeApprovedAt(targetTick, actionString)) {
            return true;
        }
        int tolerance = isUpgradeClassAction(actionString) ? 0 : TICK_TOLERANCE;
        for (int delta = 1; delta <= tolerance; delta++) {
            if (consumeApprovedAt(targetTick - delta, actionString)) {
                LOGGER.w("action %s approved for tick %d, consumed at %d (delta -%d)",
                        actionString, targetTick - delta, targetTick, delta);
                return true;
            }
            if (consumeApprovedAt(targetTick + delta, actionString)) {
                LOGGER.w("action %s approved for tick %d, consumed at %d (delta +%d)",
                        actionString, targetTick + delta, targetTick, delta);
                return true;
            }
        }
        return false;
    }

    private boolean consumeApprovedAt(int tick, String actionString) {
        String key = tick + ":" + actionString;
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

    public synchronized void cleanupApprovedQueuedActions(int currentTick) {
        approvedQueuedActionCounts.entrySet().removeIf(entry -> {
            String key = entry.getKey();
            int colonIndex = key.indexOf(':');
            if (colonIndex < 0) return true;
            try {
                int tick = Integer.parseInt(key.substring(0, colonIndex));
                return tick < currentTick - 300;
            } catch (NumberFormatException e) {
                return true;
            }
        });
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

    public synchronized void cleanupStateHashSamples(int currentTick) {
        stateHashSamples.entrySet().removeIf(entry -> entry.getKey() < currentTick - 300);
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

    public synchronized void reconnect() {
        Bridge currentBridge = bridge;
        if (currentBridge == null) {
            LOGGER.i("Reconnect requested but bridge is not initialized");
            return;
        }

        LOGGER.i("Reconnecting bridge...");
        currentBridge.stop();
        bridge = null;
        start();
    }

    public synchronized long getLatencyMillis() {
        LocalSessionInfo localInfo = getLocalSessionInfo();
        if (localInfo == null) {
            return -1;
        }

        // Real round-trip time measured from PING replies (-1 = no sample yet).
        // Replaces the old "time since last received packet", which tracked ping
        // cadence rather than latency and inflated the action lead.
        return localInfo.getLastRttMillis();
    }

    private LocalSessionInfo getLocalSessionInfo() {
        Bridge currentBridge = bridge;
        if (currentBridge == null) {
            return null;
        }

        return currentBridge.getContext().getSessionRegistry().getLocalSessionInfo();
    }

    public synchronized String captureCurrentGameSnapshotBase64() {
        Screen currentScreen = Game.i.screenManager.getCurrentScreen();
        if (!(currentScreen instanceof GameScreen gameScreen) || gameScreen.S == null) {
            throw new IllegalStateException("Current screen is not an active GameScreen");
        }

        ByteArrayOutputStream byteStream = new ByteArrayOutputStream();
        try (Output output = new Output(byteStream)) {
            gameScreen.S.serialize(output);
        }
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
