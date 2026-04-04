package dev.multitode.bridge.shared.net;

public final class InboundLuaMessage {
    private final String receiverContext;
    private final String messageChannel;
    private final String messageName;
    private final int senderPlayerId;
    private final String payloadJson;

    public InboundLuaMessage(String receiverContext, String messageChannel, String messageName, int senderPlayerId, String payloadJson) {
        this.receiverContext = receiverContext;
        this.messageChannel = messageChannel;
        this.messageName = messageName;
        this.senderPlayerId = senderPlayerId;
        this.payloadJson = payloadJson;
    }

    public String toJson() {
        return "{" +
                "\"receiverContext\":" + quote(receiverContext) + "," +
                "\"messageChannel\":" + quote(messageChannel) + "," +
                "\"messageName\":" + quote(messageName) + "," +
                "\"senderPlayerId\":" + senderPlayerId + "," +
                "\"payload\":" + payloadJson +
                "}";
    }

    private static String quote(String value) {
        StringBuilder builder = new StringBuilder();
        builder.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '\\' -> builder.append("\\\\");
                case '"' -> builder.append("\\\"");
                case '\b' -> builder.append("\\b");
                case '\f' -> builder.append("\\f");
                case '\n' -> builder.append("\\n");
                case '\r' -> builder.append("\\r");
                case '\t' -> builder.append("\\t");
                default -> {
                    if (c < 0x20) {
                        builder.append(String.format("\\u%04x", (int) c));
                    } else {
                        builder.append(c);
                    }
                }
            }
        }
        builder.append('"');
        return builder.toString();
    }
}
