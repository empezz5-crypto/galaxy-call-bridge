package com.galaxycallbridge.diagnostics;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Device-runtime JSON/gate tests use ONLY a fake backend; never invoke live Telecom actions. */
public final class CallControlContractProbe {
    private static int checks;
    public static void main(String[] args) throws Exception {
        Class<?> api = Class.forName("com.android.internal.telecom.ITelecomService");
        api.getMethod("getCallStateUsingPackage", String.class, String.class);
        api.getMethod("placeCall", android.net.Uri.class, android.os.Bundle.class, String.class, String.class);
        api.getMethod("acceptRingingCallWithVideoState", String.class, int.class);
        api.getMethod("endCall", String.class);
        android.telecom.TelecomManager.class.getDeclaredMethod("getTelecomService");
        android.telephony.TelephonyManager.class.getMethod("isEmergencyNumber", String.class);
        check(true, "live-api-signatures-only");
        Fake backend = new Fake();
        CallControlServer server = new CallControlServer(backend);
        JSONObject status = server.handle("{\"action\":\"status\"}");
        check(status.getBoolean("ok") && status.getBoolean("canDial") && !status.getBoolean("canAnswer"), "idle-capabilities");
        check(backend.commands == 0, "status-no-action");
        error(server, "{\"action\":\"answer\"}", "CALL_NOT_RINGING");
        error(server, "{\"action\":\"end\"}", "NO_CALL");
        String[] invalid = {"", "*123#", "tel:123", "12;34", "123,45", "123+45", "++123", "+", "１２３", "123\n456", "\t123", "123\r", "12", "123456789012345678901234567890123"};
        for (String number : invalid) error(server, new JSONObject().put("action", "dial").put("number", number).toString(), "INVALID_NUMBER");
        check("+821012345678".equals(CallControlServer.normalizeNumber(" +82 (10) 1234-5678 ")), "normalize-only-permitted-characters");
        error(server, "{\"action\":\"dial\",\"number\":112}", "INVALID_REQUEST");
        error(server, "{\"action\":\"status\",\"extra\":true}", "INVALID_REQUEST");
        error(server, "{\"action\":\"status\"} ignored", "INVALID_REQUEST");
        error(server, "{\"action\":\"not-a-command\"}", "UNKNOWN_ACTION");
        error(server, "[]", "INVALID_REQUEST");
        backend.emergency = true;
        error(server, "{\"action\":\"dial\",\"number\":\"112\"}", "EMERGENCY_NUMBER_BLOCKED");
        backend.emergency = false;
        backend.emergencyThrows = true;
        error(server, "{\"action\":\"dial\",\"number\":\"12345\"}", "EMERGENCY_CHECK_UNAVAILABLE");
        backend.emergencyThrows = false;
        check(backend.commands == 0, "rejections-have-no-side-effects");
        backend.state = "ringing";
        status = server.handle("{\"action\":\"status\"}");
        check(status.getBoolean("canAnswer") && status.getBoolean("canEnd") && !status.getBoolean("canDial"), "ringing-capabilities");
        error(server, "{\"action\":\"dial\",\"number\":\"12345\"}", "CALL_NOT_IDLE");
        check(server.handle("{\"action\":\"answer\"}").getString("result").equals("requested") && backend.commands == 1, "fake-answer-explicit-only");
        backend.state = "active";
        error(server, "{\"action\":\"answer\"}", "CALL_NOT_RINGING");
        check(server.handle("{\"action\":\"end\"}").getBoolean("ok") && backend.commands == 2, "fake-end-explicit-only");
        backend.state = "unknown";
        error(server, "{\"action\":\"end\"}", "STATE_UNAVAILABLE");
        backend.state = "idle";
        check(server.handle("{\"action\":\"dial\",\"number\":\"+82 (10) 1234-5678\"}").getBoolean("ok")
                && backend.commands == 3 && backend.lastNumber.equals("+821012345678"), "fake-dial-normalized");
        error(server, "{\"action\":\"dial\",\"number\":\"12345\"}", "ACTION_PENDING");
        check(backend.commands == 3 && !server.handle("{\"action\":\"status\"}").getBoolean("canDial"), "duplicate-dial-blocked");
        backend.stateThrows = true;
        error(server, "{\"action\":\"status\"}", "PERMISSION_DENIED");
        check(CallControlServer.readRequest(new ByteArrayInputStream("{\"action\":\"status\"}\n".getBytes(StandardCharsets.UTF_8))).equals("{\"action\":\"status\"}"), "framing");
        try { CallControlServer.readRequest(new ByteArrayInputStream("{}".getBytes(StandardCharsets.UTF_8))); throw new AssertionError("EOF accepted"); }
        catch (java.io.IOException expected) { check(true, "EOF-rejected"); }
        byte[] huge = new byte[1026]; java.util.Arrays.fill(huge, (byte) ' '); huge[1025] = '\n';
        try { CallControlServer.readRequest(new ByteArrayInputStream(huge)); throw new AssertionError("oversize accepted"); }
        catch (java.io.IOException expected) { check(true, "oversize-rejected"); }
        try { CallControlServer.readRequest(new ByteArrayInputStream(new byte[]{(byte) 0xc0, (byte) 0xaf, '\n'})); throw new AssertionError("bad UTF8 accepted"); }
        catch (java.nio.charset.CharacterCodingException expected) { check(true, "invalid-utf8-rejected"); }
        System.out.println("PASS checks=" + checks + " liveTelecomActions=0 audioEndpoints=0 contactsRead=0 numbersLogged=0");
    }
    private static void error(CallControlServer server, String request, String expected) throws Exception {
        JSONObject result = server.handle(request);
        check(!result.getBoolean("ok") && result.getString("error").equals(expected), expected);
    }
    private static void check(boolean value, String label) { if (!value) throw new AssertionError(label); checks++; }
    private static final class Fake implements CallControlServer.Backend {
        String state = "idle", lastNumber;
        int commands;
        boolean emergency, emergencyThrows, stateThrows;
        public String state() { if (stateThrows) throw new SecurityException("synthetic"); return state; }
        public boolean canDial() { return true; }
        public boolean canAnswer() { return true; }
        public boolean canEnd() { return true; }
        public boolean isEmergency(String number) { if (emergencyThrows) throw new IllegalStateException("synthetic"); return emergency; }
        public void dial(String number) { commands++; lastNumber = number; }
        public void answer() { commands++; }
        public boolean end() { commands++; return true; }
    }
}
