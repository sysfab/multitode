package dev.multitode.bridge.shared.net;

public final class LuaMessagePacket {
    private final String messageChannel;
    private final String messageName;
    private final int senderPlayerId;
    private final String payloadJson;

    public LuaMessagePacket(String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        this.messageChannel = messageChannel;
        this.messageName = messageName;
        this.senderPlayerId = senderPlayerId;
        this.payloadJson = payloadJson;
    }

    public String getMessageChannel() {
        return messageChannel;
    }

    public String getMessageName() {
        return messageName;
    }

    public int getSenderPlayerId() {
        return senderPlayerId;
    }

    public String getPayloadJson() {
        return payloadJson;
    }
}
