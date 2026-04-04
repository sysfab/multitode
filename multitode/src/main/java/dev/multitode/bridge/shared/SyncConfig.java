package dev.multitode.bridge.shared;

public final class SyncConfig {
    private int snapshotIntervalTicks = 100;

    public int getSnapshotIntervalTicks() {
        return snapshotIntervalTicks;
    }

    public void setSnapshotIntervalTicks(int snapshotIntervalTicks) {
        if (snapshotIntervalTicks <= 0) {
            this.snapshotIntervalTicks = 100;
            return;
        }

        this.snapshotIntervalTicks = snapshotIntervalTicks;
    }
}
