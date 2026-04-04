package dev.multitode.bridge.shared;

public final class DebugConfig {
    private boolean verboseLogging = true;
    private boolean logCommands = true;
    private boolean logDesyncs = true;

    public boolean isVerboseLogging() {
        return verboseLogging;
    }

    public void setVerboseLogging(boolean verboseLogging) {
        this.verboseLogging = verboseLogging;
    }

    public boolean isLogCommands() {
        return logCommands;
    }

    public void setLogCommands(boolean logCommands) {
        this.logCommands = logCommands;
    }

    public boolean isLogDesyncs() {
        return logDesyncs;
    }

    public void setLogDesyncs(boolean logDesyncs) {
        this.logDesyncs = logDesyncs;
    }
}
