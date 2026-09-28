package dev.multitode.gameplay;

import com.badlogic.gdx.graphics.g2d.ParticleEffectPool;
import com.prineside.tdi2.Game;
import com.prineside.tdi2.Screen;
import com.prineside.tdi2.screens.GameScreen;
import com.prineside.tdi2.utils.logging.TLog;

import java.util.ArrayList;

/**
 * Gameplay-side particle work: the tile marks ("here" / "NOT here").
 *
 * <p>This sits outside the bridge on purpose. The bridge is the thin Lua-facing API
 * surface - networking, lobby, chat, session state - while marks are plain in-game
 * visuals that merely happen to be triggered from Lua. Keeping them here means more
 * in-game behaviour can be added without growing the bridge or the network code.</p>
 *
 * <p>The mark particles are owned here: we obtain them, position them and own every
 * mark's lifetime. The engine's own highlightTile()/removeHighlights() only assigns
 * a particle's position while that tile is being drawn (so an off-screen highlight
 * sat at the world origin - the map's bottom-left corner), and it does not handle an
 * exhausted pool, which left MapSystem.drawBatch holding a null particle (crash).
 * Neither can happen when we hold the effects ourselves.</p>
 *
 * <p>The "here" highlight is two effects chasing each other around the tile's
 * perimeter, exactly like the engine does it: MapSystem walks a phase 0..1 around
 * the tile edges with corners at +/-64 (the tile bounds) and offsets the second
 * effect by half a phase. Setting both to the tile centre instead collapses them
 * into a cluster, so we reproduce that path here.</p>
 */
public final class TileMarks {

    private static final TLog LOGGER = TLog.forTag("multitode/TileMarks");

    /** World size of one map tile; a tile's centre is (x * 128 + 64, y * 128 + 64). */
    private static final float TILE_WORLD_SIZE = 128f;
    /** Half a tile - the corners the highlight walks around, same as the engine. */
    private static final float TILE_HALF = TILE_WORLD_SIZE / 2f;
    /** One full lap of the highlight takes 2s (the engine advances 0.5 per second). */
    private static final long LAP_MS = 2000L;
    /** The "NOT here" flash is one-shot, so it is re-fired while the mark lives. */
    private static final long RED_RESPAWN_MS = 2500L;

    private static final class TileMark {
        boolean warning;
        float worldX;
        float worldY;
        long expiresAtMs;
        long nextSpawnAtMs;
        ParticleEffectPool pool;
        final ArrayList<ParticleEffectPool.PooledEffect> effects =
                new ArrayList<ParticleEffectPool.PooledEffect>();
    }

    private static final long DEDUPE_MS = 600L;

    private final ArrayList<TileMark> tileMarks = new ArrayList<TileMark>();
    /** tile+mode -> last accepted time, so a mark cannot be applied twice at once. */
    private final java.util.HashMap<String, Long> recentMarks = new java.util.HashMap<String, Long>();

    private GameScreen currentGameScreen() {
        Screen screen = Game.i.screenManager.getCurrentScreen();
        if (screen instanceof GameScreen) {
            return (GameScreen) screen;
        }
        return null;
    }

    /**
     * Walk a phase around a square the size of one tile, matching the engine's own
     * highlight path: 0-0.25 up the left edge, 0.25-0.5 along the top, then the
     * right edge and the bottom back to the start. Writes x/y into the result.
     */
    private static float[] squareOffset(float phase) {
        float p = phase - (float) Math.floor(phase);
        float left = -TILE_HALF;
        float right = TILE_HALF;
        float bottom = -TILE_HALF;
        float top = TILE_HALF;
        if (p < 0.25f) {
            return new float[]{left, p / 0.25f * (top - bottom) + bottom};
        }
        if (p < 0.5f) {
            return new float[]{(p - 0.25f) / 0.25f * (right - left) + left, top};
        }
        if (p < 0.75f) {
            return new float[]{right, (p - 0.5f) / 0.25f * (bottom - top) + top};
        }
        return new float[]{(p - 0.75f) / 0.25f * (left - right) + right, bottom};
    }

    /** Put a mark's effects on their path (blue chases around the tile, red stays put). */
    private void positionMarkTile(TileMark mark) {
        if (mark.effects.isEmpty()) {
            return;
        }
        if (mark.warning) {
            for (ParticleEffectPool.PooledEffect effect : mark.effects) {
                if (effect != null) {
                    effect.setPosition(mark.worldX, mark.worldY);
                }
            }
            return;
        }
        float phase = (float) ((System.currentTimeMillis() % LAP_MS) / (double) LAP_MS);
        for (int i = 0; i < mark.effects.size(); i++) {
            ParticleEffectPool.PooledEffect effect = mark.effects.get(i);
            if (effect == null) {
                continue;
            }
            float[] offset = squareOffset(phase + i * 0.5f);
            effect.setPosition(mark.worldX + offset[0], mark.worldY + offset[1]);
        }
    }

    /** Add a mark with its own lifetime (durationMs), managed entirely on this side.
     *  durationMs <= 0 means the mark is permanent (never expires until cleared). */
    public synchronized boolean addTileMark(int tileX, int tileY, boolean warning, int durationMs) {
        try {
            GameScreen screen = currentGameScreen();
            if (screen == null || screen.S == null || screen.S.map == null || screen.S._particle == null) {
                return false;
            }
            com.prineside.tdi2.Map map = screen.S.map.getMap();
            if (map == null || map.getTile(tileX, tileY) == null) {
                return false;
            }
            ParticleEffectPool pool = warning
                    ? Game.i.mapManager.tileWarningParticlePool
                    : Game.i.mapManager.highlightParticlesPool;
            if (pool == null) {
                return false;
            }

            pruneTileMarks();

            // Dedupe: a client mark is applied locally, then the host applies it and
            // re-broadcasts it, so the same tile can arrive twice in the same instant.
            // Two live marks on one tile stack particles and look thicker, so a repeat
            // within DEDUPE_MS is accepted as "already marked" instead of spawning again.
            long nowMs = System.currentTimeMillis();
            String dedupeKey = tileX + ":" + tileY + ":" + warning;
            Long lastMs = recentMarks.get(dedupeKey);
            if (lastMs != null && nowMs - lastMs < DEDUPE_MS) {
                LOGGER.i("mark %d:%d already applied %.0fms ago - ignored duplicate",
                        tileX, tileY, (nowMs - lastMs) / 1.0f);
                return true;
            }
            if (recentMarks.size() > 512) {
                recentMarks.clear();
            }
            recentMarks.put(dedupeKey, nowMs);

            TileMark mark = new TileMark();
            mark.warning = warning;
            mark.pool = pool;
            mark.worldX = tileX * TILE_WORLD_SIZE + TILE_HALF;
            mark.worldY = tileY * TILE_WORLD_SIZE + TILE_HALF;
            if (durationMs <= 0) {
                // Permanent: never expires until explicitly cleared/erased.
                mark.expiresAtMs = Long.MAX_VALUE;
                mark.nextSpawnAtMs = warning
                        ? System.currentTimeMillis() + RED_RESPAWN_MS
                        : Long.MAX_VALUE;
            } else {
                mark.expiresAtMs = System.currentTimeMillis() + Math.max(500, durationMs);
                mark.nextSpawnAtMs = mark.expiresAtMs;
            }

            spawnMarkEffects(screen, mark);
            if (mark.effects.isEmpty()) {
                return false;
            }
            tileMarks.add(mark);
            return true;
        } catch (Throwable throwable) {
            LOGGER.w("addTileMark(%d,%d) failed: %s", tileX, tileY, throwable.toString());
            return false;
        }
    }

    /** Remove a single mark at (tileX, tileY) if present. Used by erase mode. */
    public synchronized boolean removeTileMarkAt(int tileX, int tileY) {
        try {
            float wx = tileX * TILE_WORLD_SIZE + TILE_HALF;
            float wy = tileY * TILE_WORLD_SIZE + TILE_HALF;
            boolean removed = false;
            for (int i = tileMarks.size() - 1; i >= 0; i--) {
                TileMark mark = tileMarks.get(i);
                if (Math.abs(mark.worldX - wx) < 1f && Math.abs(mark.worldY - wy) < 1f) {
                    for (ParticleEffectPool.PooledEffect effect : mark.effects) {
                        if (effect != null) {
                            effect.allowCompletion();
                        }
                    }
                    mark.effects.clear();
                    tileMarks.remove(i);
                    removed = true;
                }
            }
            // Drop dedupe entries for this tile so a re-mark is accepted immediately.
            recentMarks.remove(tileX + ":" + tileY + ":true");
            recentMarks.remove(tileX + ":" + tileY + ":false");
            return removed;
        } catch (Throwable throwable) {
            LOGGER.w("removeTileMarkAt(%d,%d) failed: %s", tileX, tileY, throwable.toString());
            return false;
        }
    }

    // --------------------------------------------------------- remote cursors
    // Lightweight per-player cursor indicators. Positions come from Lua at 4-8 Hz;
    // each marker is one pooled effect parked on the tile centre and expires after
    // CURSOR_TTL_MS without an update (player stopped sending / left the match).

    private static final long CURSOR_TTL_MS = 2500L;

    private static final class RemoteCursor {
        int tileX;
        int tileY;
        long lastUpdateMs;
        ParticleEffectPool.PooledEffect effect;
        GameScreen ownerScreen;
    }

    private final java.util.HashMap<Integer, RemoteCursor> remoteCursors =
            new java.util.HashMap<Integer, RemoteCursor>();

    /** Update (or create) a remote player's cursor marker at a tile. */
    public synchronized void setRemoteCursor(int playerId, int tileX, int tileY) {
        try {
            GameScreen screen = currentGameScreen();
            if (screen == null || screen.S == null || screen.S.map == null || screen.S._particle == null) {
                return;
            }
            com.prineside.tdi2.Map map = screen.S.map.getMap();
            if (map == null || map.getTile(tileX, tileY) == null) {
                return;
            }
            ParticleEffectPool pool = Game.i.mapManager.highlightParticlesPool;
            if (pool == null) {
                return;
            }

            RemoteCursor cursor = remoteCursors.get(playerId);
            long now = System.currentTimeMillis();
            if (cursor == null || cursor.ownerScreen != screen
                    || cursor.effect == null || cursor.effect.isComplete()) {
                if (cursor != null && cursor.effect != null) {
                    cursor.effect.allowCompletion();
                }
                cursor = new RemoteCursor();
                cursor.ownerScreen = screen;
                cursor.effect = pool.obtain();
                if (cursor.effect != null) {
                    screen.S._particle.addParticle(cursor.effect, false);
                }
                remoteCursors.put(playerId, cursor);
            }
            cursor.tileX = tileX;
            cursor.tileY = tileY;
            cursor.lastUpdateMs = now;
            if (cursor.effect != null) {
                cursor.effect.setPosition(
                        tileX * TILE_WORLD_SIZE + TILE_HALF,
                        tileY * TILE_WORLD_SIZE + TILE_HALF);
            }
        } catch (Throwable throwable) {
            LOGGER.w("setRemoteCursor(%d,%d,%d) failed: %s",
                    playerId, tileX, tileY, throwable.toString());
        }
    }

    /** Drop a remote player's cursor (player left / stopped sending). */
    public synchronized void clearRemoteCursor(int playerId) {
        RemoteCursor cursor = remoteCursors.remove(playerId);
        if (cursor != null && cursor.effect != null) {
            cursor.effect.allowCompletion();
        }
    }

    /** Drop every remote cursor (level change / disconnect). */
    public synchronized void clearAllRemoteCursors() {
        for (RemoteCursor cursor : remoteCursors.values()) {
            if (cursor != null && cursor.effect != null) {
                cursor.effect.allowCompletion();
            }
        }
        remoteCursors.clear();
    }

    private synchronized void pruneRemoteCursors() {
        long now = System.currentTimeMillis();
        java.util.Iterator<java.util.Map.Entry<Integer, RemoteCursor>> it =
                remoteCursors.entrySet().iterator();
        while (it.hasNext()) {
            RemoteCursor cursor = it.next().getValue();
            if (cursor == null || now - cursor.lastUpdateMs > CURSOR_TTL_MS) {
                if (cursor != null && cursor.effect != null) {
                    cursor.effect.allowCompletion();
                }
                it.remove();
            }
        }
    }

    private void spawnMarkEffects(GameScreen screen, TileMark mark) {
        int amount = mark.warning ? 1 : 2;
        for (int i = 0; i < amount; i++) {
            ParticleEffectPool.PooledEffect effect = mark.pool.obtain();
            if (effect == null) {
                break;
            }
            screen.S._particle.addParticle(effect, false);
            mark.effects.add(effect);
        }
        // position them before the next frame draws, so they never appear at the
        // particle default position (the world origin, the map's bottom-left corner)
        positionMarkTile(mark);
        if (mark.warning) {
            // the warning flash is one-shot, so re-fire it while the mark lives
            mark.nextSpawnAtMs = System.currentTimeMillis() + RED_RESPAWN_MS;
        }
    }

    private synchronized void pruneTileMarks() {
        long now = System.currentTimeMillis();
        for (int i = tileMarks.size() - 1; i >= 0; i--) {
            TileMark mark = tileMarks.get(i);

            if (mark.expiresAtMs != Long.MAX_VALUE && mark.expiresAtMs <= now) {
                for (ParticleEffectPool.PooledEffect effect : mark.effects) {
                    if (effect != null) {
                        effect.allowCompletion();
                    }
                }
                mark.effects.clear();
                tileMarks.remove(i);
                continue;
            }

            // keep a one-shot warning visible for the mark's whole lifetime
            // (permanent warning marks re-fire on the normal cadence forever)
            if (mark.warning && now >= mark.nextSpawnAtMs) {
                GameScreen screen = currentGameScreen();
                if (screen != null && screen.S != null && screen.S._particle != null) {
                    spawnMarkEffects(screen, mark);
                }
            }
        }
        pruneRemoteCursors();
    }

    /**
     * Re-create the particles for every live mark. A level snapshot restore replaces the
     * particle system, which wipes the visuals while the marks themselves are still
     * alive here - this puts them back so a resync no longer clears everyone's marks.
     */
    public synchronized int respawnTileMarks() {
        GameScreen screen = currentGameScreen();
        if (screen == null || screen.S == null || screen.S._particle == null) {
            return 0;
        }
        int respawned = 0;
        for (RemoteCursor cursor : remoteCursors.values()) {
            if (cursor == null) {
                continue;
            }
            if (cursor.effect != null) {
                cursor.effect.allowCompletion();
            }
            cursor.ownerScreen = screen;
            cursor.effect = Game.i.mapManager.highlightParticlesPool == null
                    ? null : Game.i.mapManager.highlightParticlesPool.obtain();
            if (cursor.effect != null) {
                screen.S._particle.addParticle(cursor.effect, false);
                cursor.effect.setPosition(
                        cursor.tileX * TILE_WORLD_SIZE + TILE_HALF,
                        cursor.tileY * TILE_WORLD_SIZE + TILE_HALF);
            }
        }
        for (TileMark mark : tileMarks) {
            // drop the dead effects from the replaced particle system and take fresh ones
            for (ParticleEffectPool.PooledEffect effect : mark.effects) {
                if (effect != null) {
                    effect.allowCompletion();
                }
            }
            mark.effects.clear();
            spawnMarkEffects(screen, mark);
            if (!mark.effects.isEmpty()) {
                respawned++;
            }
        }
        LOGGER.i("respawned %d live tile marks after a level restore", respawned);
        return respawned;
    }

    /** Called from the render hook so lifetimes and the highlight path stay live. */
    public synchronized void tickTileMarks() {
        pruneTileMarks();
        for (TileMark mark : tileMarks) {
            positionMarkTile(mark);
        }
    }

    public synchronized int getTileMarkCount() {
        pruneTileMarks();
        return tileMarks.size();
    }

    /** Finish every mark now (lets each particle play out and return to its pool). */
    public synchronized void clearTileMarks() {
        for (TileMark mark : tileMarks) {
            for (ParticleEffectPool.PooledEffect effect : mark.effects) {
                if (effect != null) {
                    effect.allowCompletion();
                }
            }
            mark.effects.clear();
        }
        tileMarks.clear();
        recentMarks.clear();
    }
}