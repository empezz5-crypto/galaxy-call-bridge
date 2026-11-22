package com.galaxycallbridge.diagnostics;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Arrays;

/** Pure synthetic data checks. Does not open a socket or an audio device. */
public final class AudioWireSelfCheck {
    public static void main(String[] args) throws Exception {
        ByteArrayOutputStream helloOut = new ByteArrayOutputStream();
        AudioWire.write(helloOut, AudioWire.HELLO, new byte[0]);
        byte[] vector = new byte[] {0x47, 0x43, 0x42, 0x31, 0, 1, 0, 0};
        require(Arrays.equals(helloOut.toByteArray(), vector), "hello vector");
        AudioWire.Frame hello = AudioWire.read(new ByteArrayInputStream(vector));
        require(hello != null && hello.type == AudioWire.HELLO && hello.payload.length == 0, "hello round trip");

        byte[] silence = new byte[AudioWire.PCM_BYTES];
        ByteArrayOutputStream audioOut = new ByteArrayOutputStream();
        AudioWire.write(audioOut, AudioWire.SILENCE, silence);
        AudioWire.Frame audio = AudioWire.read(new ByteArrayInputStream(audioOut.toByteArray()));
        require(audio.type == AudioWire.SILENCE && audio.payload.length == AudioWire.PCM_BYTES, "silence frame size");
        require(AudioWire.allZero(audio.payload), "synthetic silence payload");

        byte[] bad = vector.clone(); bad[0] = 0;
        try { AudioWire.read(new ByteArrayInputStream(bad)); throw new AssertionError("bad magic accepted"); }
        catch (IOException expected) { }
        System.out.println("PASS: GCB1 cross-language frame vector, 20 ms synthetic silence, bounds and invalid-magic checks; no audio devices or sockets opened.");
    }
    private static void require(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}
