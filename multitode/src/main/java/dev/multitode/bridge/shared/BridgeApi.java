package dev.multitode.bridge.shared;

import com.esotericsoftware.kryo.io.Input;
import com.esotericsoftware.kryo.io.Output;
import com.prineside.tdi2.Enemy;
import com.prineside.tdi2.Game;
import com.prineside.tdi2.GameSystemProvider;
import com.prineside.tdi2.Miner;
import com.prineside.tdi2.Modifier;
import com.prineside.tdi2.Projectile;
import com.prineside.tdi2.Screen;
import com.prineside.tdi2.Tower;
import com.prineside.tdi2.Unit;
import com.prineside.tdi2.Wave;
import com.prineside.tdi2.enums.ResourceType;
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
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;

public final class BridgeApi {
    private static final TLog LOGGER = TLog.forTag("multitode/BridgeApi");
    public static final BridgeApi INSTANCE = new BridgeApi();
    private static final Path CONFIG_PATH = Paths.get("cache", "script-data", "multitode", "session-config.properties");
    private static final String STATE_HASH_SCHEMA = "canonical-v1";

    private static Bridge bridge;
    private final SessionConfig sessionConfig = new SessionConfig();
    private final Map<String, Integer> approvedQueuedActionCounts = new HashMap<>();
    private final Map<Integer, String> stateHashSamples = new HashMap<>();
    private final Set<String> claimedGlobalHooks = new HashSet<>();
    private String pendingStartupSyncJson;
    private String claimedLevelSyncKey;
    private int nextLevelSyncId = 1;
    private int pauseApplyDepth;
    private int pauseRevision;
    private boolean synchronizedPauseActive;

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
        pauseApplyDepth = 0;
        pauseRevision = 0;
        synchronizedPauseActive = false;
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

    public synchronized long getPacketsSent() {
        if (bridge == null) {
            return 0L;
        }

        return bridge.getContext().getSessionRegistry().getPacketsSent();
    }

    public synchronized long getPacketsReceived() {
        if (bridge == null) {
            return 0L;
        }

        return bridge.getContext().getSessionRegistry().getPacketsReceived();
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

    public synchronized void beginPauseApply() {
        pauseApplyDepth++;
    }

    public synchronized void endPauseApply() {
        pauseApplyDepth = Math.max(0, pauseApplyDepth - 1);
    }

    public synchronized boolean isPauseApplyActive() {
        return pauseApplyDepth > 0;
    }

    public synchronized int nextPauseRevision() {
        return ++pauseRevision;
    }

    public synchronized void setSynchronizedPauseActive(boolean paused) {
        synchronizedPauseActive = paused;
    }

    public synchronized boolean isSynchronizedPauseActive() {
        return synchronizedPauseActive;
    }

    public synchronized void saveStateHashSampleJson(int tick, String sampleJson) {
        stateHashSamples.put(tick, sampleJson);
        if (stateHashSamples.size() > 256) {
            stateHashSamples.remove(stateHashSamples.keySet().stream().min(Integer::compareTo).orElse(tick));
        }
    }

    public synchronized String getStateHashSampleJson(int tick) {
        return stateHashSamples.get(tick);
    }

    public synchronized void clearStateHashSamples() {
        stateHashSamples.clear();
    }

    public synchronized String getCurrentGameStateHash() {
        Screen currentScreen = Game.i.screenManager.getCurrentScreen();
        if (!(currentScreen instanceof GameScreen gameScreen) || gameScreen.S == null) {
            throw new IllegalStateException("Current screen is not an active GameScreen");
        }

        try {
            StateHashWriter writer = new StateHashWriter(MessageDigest.getInstance("SHA-256"));
            writeCanonicalGameState(writer, gameScreen.S);
            byte[] digest = writer.finish();
            StringBuilder hash = new StringBuilder(digest.length * 2);
            for (byte value : digest) {
                hash.append(Character.forDigit((value >>> 4) & 0xF, 16));
                hash.append(Character.forDigit(value & 0xF, 16));
            }
            return STATE_HASH_SCHEMA + ":" + hash;
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private static void writeCanonicalGameState(StateHashWriter writer, GameSystemProvider systems) {
        // Do not hash save/replay metadata, real-time counters, listeners, or local action history.
        // Those legitimately differ between peers even when their gameplay state is equivalent.
        writer.putString(STATE_HASH_SCHEMA);
        writer.putInt(systems.state.updateNumber);

        writer.putLong(systems.gameState.getSeed());
        writer.putLong(systems.gameState.getRandomState(0));
        writer.putLong(systems.gameState.getRandomState(1));
        writer.putInt(systems.gameState.getMoney());
        writer.putInt(systems.gameState.getHealth());
        writer.putLong(systems.gameState.getScore());
        writer.putBoolean(systems.gameState.isGameOver());
        writer.putInt(systems.gameState.modeDifficultyMultiplier);
        writer.putInt(systems.gameState.averageDifficulty);
        writer.putInt(systems.gameState.pxpExperience);
        writer.putLong(systems.gameState.scoreWithEndlessTimeLimit);
        writer.putString(systems.gameState.difficultyMode == null ? null : systems.gameState.difficultyMode.name());
        writer.putString(systems.gameState.gameMode == null ? null : systems.gameState.gameMode.name());
        writer.putString(systems.gameState.basicLevelName);
        writer.putString(systems.gameState.userMapId);
        writer.putInt(systems.gameState.userMapOriginalSeed);
        writer.putBoolean(systems.gameState.canLootCases);
        writer.putBoolean(systems.gameState.lootBoostEnabled);
        writer.putBoolean(systems.gameState.rarityBoostEnabled);
        writer.putFloat(systems.gameState.getDoubleSpeedTimeLeft());
        for (ResourceType resourceType : ResourceType.values) {
            writer.putInt(systems.gameState.getResources(resourceType));
        }

        writer.putString(systems.wave.mode == null ? null : systems.wave.mode.name());
        writer.putString(systems.wave.status == null ? null : systems.wave.status.name());
        writer.putInt(systems.wave.getCompletedWavesCount());
        writer.putBoolean(systems.wave.isForceWaveAvailable());
        writer.putInt(systems.wave.getForceWaveBonus());
        writer.putFloat(systems.wave.getTimeToNextWave());
        writeWave(writer, systems.wave.wave);

        writer.putBoolean(systems.bonus.isEnabled());
        writer.putInt(systems.bonus.getCurrentVisualProgressStageNumber());
        writer.putInt(systems.bonus.getCurrentVisualProgressPoints());
        writer.putInt(systems.bonus.getNextStagePointsRequirement());
        writer.putInt(systems.bonus.selectedBonuses.size);
        for (int index = 0; index < systems.bonus.selectedBonuses.size; index++) {
            writer.putInt(systems.bonus.selectedBonuses.get(index));
        }
        writer.putInt(systems.bonus.stageReRolls.size);
        for (int index = 0; index < systems.bonus.stageReRolls.size; index++) {
            writer.putInt(systems.bonus.stageReRolls.get(index));
        }
        var bonusStage = systems.bonus.getStageToChooseBonusFor();
        writer.putBoolean(bonusStage != null);
        if (bonusStage != null) {
            writer.putInt(bonusStage.getNumber());
            writer.putInt(bonusStage.getPoints());
            writer.putInt(bonusStage.getPointsRequirement());
            var offeredBonuses = bonusStage.getBonusesToChooseFrom();
            writer.putInt(offeredBonuses.size);
            for (int index = 0; index < offeredBonuses.size; index++) {
                var bonus = offeredBonuses.get(index);
                writer.putString(bonus.getId());
                writer.putInt(bonus.getPower());
            }
        }

        List<Enemy> enemies = new ArrayList<>();
        for (int index = 0; index < systems.map.spawnedEnemies.size; index++) {
            Enemy enemy = systems.map.spawnedEnemies.get(index).enemy;
            if (enemy != null) {
                enemies.add(enemy);
            }
        }
        enemies.sort(Comparator.comparingInt(enemy -> enemy.id));
        writer.putInt(enemies.size());
        for (Enemy enemy : enemies) {
            writer.putString(enemy.getClass().getName());
            writer.putInt(enemy.id);
            writer.putString(enemy.type == null ? null : enemy.type.name());
            writer.putFloat(enemy.getPosition().x);
            writer.putFloat(enemy.getPosition().y);
            writer.putFloat(enemy.getHealth());
            writer.putFloat(enemy.maxHealth);
            writer.putFloat(enemy.getSpeed());
            writer.putFloat(enemy.getBuffedSpeed());
            writer.putFloat(enemy.angle);
            writer.putFloat(enemy.passedTiles);
            writer.putFloat(enemy.sumPassedTiles);
            writer.putFloat(enemy.existsTime);
            writer.putFloat(enemy.bounty);
            writer.putInt(enemy.sideShiftIndex);
            writer.putInt(enemy.pathSearches);
            writer.putInt(enemy.killScore);
            writer.putInt(enemy.ignitionIncreasedLastFrame);
            writer.putFloat(enemy.ignitionProgress);
            writer.putInt(enemy.totalCatchesByCrushers);
            writer.putBoolean(enemy.ignorePathfinding);
            writer.putBoolean(enemy.chasedByCrusher);
            writer.putBoolean(enemy.gaveMiningSpeedForGauss);
            writer.putBoolean(enemy.doesNotDisableTowers);
            writer.putBoolean(enemy.ignoredOnGameOverNoEnemies);
            writer.putBoolean(enemy.canNotBeDisoriented);
            writer.putBoolean(enemy.ignoredByAutoWaveCall);
            writer.putFloat(enemy.buffFreezingPercent);
            writer.putFloat(enemy.buffFreezingLightningLengthBonus);
            writer.putFloat(enemy.buffFreezingPoisonDurationBonus);
            writer.putInt(enemy.buffSnowballHits);
            if (enemy.buffsByType == null) {
                writer.putInt(-1);
            } else {
                writer.putInt(enemy.buffsByType.length);
                for (com.badlogic.gdx.utils.DelayedRemovalArray<?> buffs : enemy.buffsByType) {
                    writer.putInt(buffs == null ? -1 : buffs.size);
                }
            }
        }

        List<Unit> units = new ArrayList<>();
        for (int index = 0; index < systems.map.spawnedUnits.size; index++) {
            units.add(systems.map.spawnedUnits.get(index));
        }
        units.sort(Comparator.comparingInt(unit -> unit.id));
        writer.putInt(units.size());
        for (Unit unit : units) {
            writer.putString(unit.getClass().getName());
            writer.putInt(unit.id);
            writer.putString(unit.type == null ? null : unit.type.name());
            writer.putFloat(unit.position.x);
            writer.putFloat(unit.position.y);
            writer.putFloat(unit.angle);
            writer.putFloat(unit.speed);
            writer.putInt(unit.sideShiftIndex);
            writer.putFloat(unit.passedTiles);
            writer.putBoolean(unit.staticPosition);
            writer.putBoolean(unit.spawned);
        }

        List<Tower> towers = new ArrayList<>();
        for (int index = 0; index < systems.tower.towers.size; index++) {
            towers.add(systems.tower.towers.get(index));
        }
        towers.sort(Comparator.comparingInt(tower -> tower.id));
        writer.putInt(towers.size());
        for (Tower tower : towers) {
            writer.putString(tower.getClass().getName());
            writer.putInt(tower.id);
            writer.putString(tower.type == null ? null : tower.type.name());
            writer.putInt(tower.getTile() == null ? -1 : tower.getTile().getX());
            writer.putInt(tower.getTile() == null ? -1 : tower.getTile().getY());
            writer.putString(tower.aimStrategy == null ? null : tower.aimStrategy.name());
            writer.putInt(tower.moneySpentOn);
            writer.putFloat(tower.damageGiven);
            writer.putInt(tower.shotCount);
            writer.putFloat(tower.loopAbilityDamageBuffer);
            writer.putFloat(tower.angle);
            writer.putFloat(tower.experience);
            writer.putFloat(tower.currentLevelExperience);
            writer.putFloat(tower.nextLevelExperience);
            writer.putInt(tower.getLevel());
            writer.putInt(tower.getUpgradeLevel());
            writer.putBoolean(tower.attackDisabled);
            writer.putBoolean(tower.isOutOfOrder());
            Enemy target = tower.getTarget();
            writer.putInt(target == null ? 0 : target.id);
            writer.putInt(tower.installedAbilities.length);
            for (boolean installed : tower.installedAbilities) {
                writer.putBoolean(installed);
            }
        }

        List<Miner> miners = new ArrayList<>();
        for (int index = 0; index < systems.miner.miners.size; index++) {
            miners.add(systems.miner.miners.get(index));
        }
        miners.sort(Comparator.comparingInt(miner -> miner.id));
        writer.putInt(miners.size());
        writer.putFloat(systems.miner.bonusDoubleMiningSpeedTimeLeft);
        for (Miner miner : miners) {
            writer.putString(miner.getClass().getName());
            writer.putInt(miner.id);
            writer.putString(miner.type == null ? null : miner.type.name());
            writer.putInt(miner.getTile() == null ? -1 : miner.getTile().getX());
            writer.putInt(miner.getTile() == null ? -1 : miner.getTile().getY());
            writer.putInt(miner.moneySpentOn);
            writer.putInt(miner.getUpgradeLevel());
            writer.putFloat(miner.getInstallTimeLeft());
            writer.putFloat(miner.existsTime);
            writer.putLong(miner.totalScoreGained);
            writer.putFloat(miner.lastMinedItemTime);
            writer.putString(miner.nextMinedResourceType == null ? null : miner.nextMinedResourceType.name());
            writer.putFloat(miner.miningTime);
            writer.putFloat(miner.doubleSpeedTimeLeft);
            writer.putInt(miner.loopAbilityResourceBuffer);
            writer.putInt(miner.minedResources.length);
            for (int minedResource : miner.minedResources) {
                writer.putInt(minedResource);
            }
        }

        List<Modifier> modifiers = new ArrayList<>();
        for (int index = 0; index < systems.modifier.modifiers.size; index++) {
            modifiers.add(systems.modifier.modifiers.get(index));
        }
        modifiers.sort(Comparator.comparingInt(modifier -> modifier.id));
        writer.putInt(modifiers.size());
        for (Modifier modifier : modifiers) {
            writer.putString(modifier.getClass().getName());
            writer.putInt(modifier.id);
            writer.putString(modifier.type == null ? null : modifier.type.name());
            writer.putInt(modifier.getTile() == null ? -1 : modifier.getTile().getX());
            writer.putInt(modifier.getTile() == null ? -1 : modifier.getTile().getY());
            writer.putFloat(modifier.timeSinceBuilt);
            writer.putInt(modifier.moneySpentOn);
        }
        writeIntArray(writer, systems.modifier.modifiersBuiltByType);
        writeIntArray(writer, systems.modifier.modifiersBuiltByTypeAllTime);
        writeIntArray(writer, systems.modifier.modifiersSoldByTypeAllTime);

        List<Projectile> projectiles = new ArrayList<>();
        for (int index = 0; index < systems.projectile.projectiles.size; index++) {
            projectiles.add(systems.projectile.projectiles.get(index));
        }
        projectiles.sort(Comparator.comparingInt(projectile -> projectile.id));
        writer.putInt(projectiles.size());
        for (Projectile projectile : projectiles) {
            writer.putString(projectile.getClass().getName());
            writer.putInt(projectile.id);
            writer.putString(projectile.type == null ? null : projectile.type.name());
            writer.putFloat(projectile.position.x);
            writer.putFloat(projectile.position.y);
            writer.putFloat(projectile.getDamage());
            writer.putBoolean(projectile.isDone());
            writer.putBoolean(projectile.hasReachedTarget());
        }

        writeIntArray(writer, systems.ability.abilitiesUsed);
        writer.putInt(systems.ability.activeAbilities.size);
        for (int index = 0; index < systems.ability.activeAbilities.size; index++) {
            var ability = systems.ability.activeAbilities.get(index);
            writer.putString(ability.getClass().getName());
            writer.putString(ability.getType() == null ? null : ability.getType().name());
            writer.putFloat(ability.getKilledEnemiesCoinMultiplier());
            writer.putBoolean(ability.isDone());
        }
    }

    private static void writeWave(StateHashWriter writer, Wave wave) {
        writer.putBoolean(wave != null);
        if (wave == null) {
            return;
        }
        writer.putInt(wave.waveNumber);
        writer.putInt(wave.difficulty);
        writer.putInt(wave.totalEnemiesCount);
        writer.putBoolean(wave.enemiesCanBeSplitBetweenSpawns);
        writer.putBoolean(wave.enemiesCanHaveRandomSideShifts);
        writer.putFloat(wave.enemiesSumHealth);
        writer.putFloat(wave.enemiesSumBounty);
        writer.putFloat(wave.enemiesTookDamage);
        writer.putBoolean(wave.started);
        writer.putInt(wave.killedEnemiesCount);
        writer.putInt(wave.passedEnemiesCount);
        writer.putInt(wave.killedEnemiesBountySum);
        writer.putBoolean(wave.completed);
        writer.putInt(wave.enemyGroups.size);
        writer.putString(wave.waveProcessor == null ? null : wave.waveProcessor.getClass().getName());
    }

    private static void writeIntArray(StateHashWriter writer, int[] values) {
        writer.putInt(values == null ? -1 : values.length);
        if (values != null) {
            for (int value : values) {
                writer.putInt(value);
            }
        }
    }

    private static final class StateHashWriter {
        private final MessageDigest digest;

        private StateHashWriter(MessageDigest digest) {
            this.digest = digest;
        }

        private void putBoolean(boolean value) {
            digest.update((byte) (value ? 1 : 0));
        }

        private void putInt(int value) {
            digest.update((byte) (value >>> 24));
            digest.update((byte) (value >>> 16));
            digest.update((byte) (value >>> 8));
            digest.update((byte) value);
        }

        private void putLong(long value) {
            putInt((int) (value >>> 32));
            putInt((int) value);
        }

        private void putFloat(float value) {
            putInt(Float.floatToRawIntBits(value));
        }

        private void putString(String value) {
            if (value == null) {
                putInt(-1);
                return;
            }
            byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
            putInt(bytes.length);
            digest.update(bytes);
        }

        private byte[] finish() {
            return digest.digest();
        }
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

    public synchronized boolean claimLevelSyncAnnouncement(String key) {
        if (key.equals(claimedLevelSyncKey)) {
            return false;
        }
        claimedLevelSyncKey = key;
        return true;
    }

    public synchronized void clearLevelSyncAnnouncement() {
        claimedLevelSyncKey = null;
    }

    public synchronized int nextLevelSyncId() {
        return nextLevelSyncId++;
    }

    public synchronized void releaseLevelSyncAnnouncement(String key) {
        if (key.equals(claimedLevelSyncKey)) {
            claimedLevelSyncKey = null;
        }
    }

    public synchronized boolean claimGlobalHook(String key) {
        return claimedGlobalHooks.add(key);
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
        float gameSpeed = systems.gameState.getNonAnimatedGameSpeed();
        GameScreen screen = new GameScreen(systems, gameStartTimestamp);
        systems.gameState.setGameSpeed(gameSpeed);
        Game.i.screenManager.setScreen(screen);
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
