package com.galaxycallbridge.diagnostics;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Fixed-size, versioned local tunnel framing. No audio-file or logging helpers. */
public final class AudioWire {
    public static final int MAGIC = 0x47434231; // GCB1
    public static final int HEADER_BYTES = 8;
    public static final int PCM_BYTES = 640; // 20 ms, mono, 16 kHz, signed PCM16
    public static final int MAX_PAYLOAD = PCM_BYTES;
    public static final int HELLO = 1;
    public static final int STATUS = 2;
    public static final int SILENCE = 0x20;
    public static final int SILENCE_RESULT = 0x21;
    public static final int START_DOWNLINK = 0x30;
    public static final int DOWNLINK_PCM = 0x31;
    public static final int START_UPLINK = 0x32;
    public static final int UPLINK_PCM = 0x33;
    public static final int STOP = 0x34;

    private AudioWire() {}

    public static final class Frame {
        public final int type;
        public final byte[] payload;
        Frame(int type, byte[] payload) { this.type = type; this.payload = payload; }
    }

    public static void write(OutputStream output, int type, byte[] payload) throws IOException {
        if (payload == null || payload.length > MAX_PAYLOAD) throw new IOException("frame payload too large");
        DataOutputStream out = new DataOutputStream(output);
        out.writeInt(MAGIC);
        out.writeShort(type & 0xffff);
        out.writeShort(payload.length);
        out.write(payload);
        out.flush();
    }

    public static Frame read(InputStream input) throws IOException {
        DataInputStream in = new DataInputStream(input);
        final int magic;
        try { magic = in.readInt(); } catch (EOFException eof) { return null; }
        if (magic != MAGIC) throw new IOException("bad frame magic");
        int type = in.readUnsignedShort();
        int length = in.readUnsignedShort();
        if (length > MAX_PAYLOAD) throw new IOException("frame payload too large");
        byte[] payload = new byte[length];
        in.readFully(payload);
        return new Frame(type, payload);
    }

    public static boolean allZero(byte[] bytes) {
        if (bytes == null) return false;
        for (byte b : bytes) if (b != 0) return false;
        return true;
    }
}
