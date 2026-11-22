package com.galaxycallbridge.diagnostics;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.Uri;
import android.os.Bundle;
import android.os.Process;
import android.telecom.TelecomManager;
import android.telephony.TelephonyManager;
import android.provider.CallLog;
import android.util.Log;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;
import org.json.JSONTokener;

/** Metadata-only call state plus explicit user commands; independent of the PCM connection. */
public final class CallControlServer {
    public static final String BUILD = "20261031-059-r1";
    private static final String SOCKET_NAME = "gcb_control_v1";
    private static final String SHELL_PACKAGE = "com.android.shell";
    private static final int MAX_REQUEST_BYTES = 1024;
    private final Backend backend;
    private final Context context;
    private final boolean diagnostics;
    private final Object commandLock = new Object();
    private volatile long nextDialAt;
    private final Set<LocalSocket> clients = Collections.synchronizedSet(new HashSet<>());
    private volatile LocalServerSocket listener;
    private volatile boolean running;
    private ThreadPoolExecutor workers;

    public CallControlServer(Context base) throws Exception {
        this(new AndroidBackend(base), true, CallAudioBuilders.shellContext(base));
    }
    CallControlServer(Backend backend) { this(backend, false, null); }
    private CallControlServer(Backend backend, boolean diagnostics, Context context) {
        this.backend = backend;
        this.diagnostics = diagnostics;
        this.context = context;
    }
    private void trace(String value) { if (diagnostics) Log.i("GCB_CONTROL", value); }

    public synchronized void start() throws IOException {
        if (running) return;
        LocalServerSocket opened = new LocalServerSocket(SOCKET_NAME);
        ThreadPoolExecutor pool = new ThreadPoolExecutor(2, 2, 0, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(2), task -> new Thread(task, "gcb-control-client"));
        listener = opened;
        workers = pool;
        running = true;
        new Thread(() -> acceptClients(opened, pool), "gcb-control-listener").start();
        trace("LISTEN build=" + BUILD);
    }

    public synchronized void stop() {
        running = false;
        LocalServerSocket closing = listener;
        listener = null;
        if (closing != null) try { closing.close(); } catch (IOException ignored) { }
        synchronized (clients) {
            for (LocalSocket socket : clients) close(socket);
            clients.clear();
        }
        if (workers != null) workers.shutdownNow();
        workers = null;
    }

    private void acceptClients(LocalServerSocket opened, ThreadPoolExecutor pool) {
        try {
            while (running && listener == opened) {
                LocalSocket socket = opened.accept();
                // ADB's Android endpoint is shell/root. Other phone apps cannot use this bridge.
                int uid = socket.getPeerCredentials().getUid();
                if (uid != 2000 && uid != 0) { close(socket); continue; }
                socket.setSoTimeout(2500);
                clients.add(socket);
                try { pool.execute(() -> serve(socket)); }
                catch (RuntimeException rejected) { clients.remove(socket); close(socket); }
            }
        } catch (IOException ignored) {
            if (running && listener == opened) trace("LISTENER_CLOSED");
        } finally {
            synchronized (this) { if (listener == opened) stop(); }
        }
    }

    private void serve(LocalSocket socket) {
        try {
            JSONObject response;
            try { response = handle(readRequest(socket.getInputStream())); }
            catch (Exception invalid) { response = failure("INVALID_REQUEST"); }
            socket.getOutputStream().write((response.toString() + "\n").getBytes(StandardCharsets.UTF_8));
            socket.getOutputStream().flush();
        } catch (IOException ignored) { /* Disconnected clients do not retrigger commands. */ }
        finally { clients.remove(socket); close(socket); }
    }

    private static void close(LocalSocket socket) {
        try { socket.close(); } catch (IOException ignored) { }
    }

    static String readRequest(InputStream input) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        while (true) {
            int value = input.read();
            if (value == -1) throw new IOException("incomplete-request");
            if (value == '\n') break;
            if (bytes.size() == MAX_REQUEST_BYTES) throw new IOException("request-too-long");
            bytes.write(value);
        }
        return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
    }

    /** Never logs requests, numbers, contacts, exception messages, or call audio. */
    JSONObject handle(String line) {
        String action = "invalid";
        try {
            JSONTokener parser = new JSONTokener(line);
            Object parsed = parser.nextValue();
            if (!(parsed instanceof JSONObject) || parser.nextClean() != 0) return failure("INVALID_REQUEST");
            JSONObject request = (JSONObject) parsed;
            Object value = request.opt("action");
            if (!(value instanceof String)) return failure("INVALID_REQUEST");
            action = (String) value;
            if (!(action.equals("status") || action.equals("recentCalls") || action.equals("dial") || action.equals("answer") || action.equals("end")))
                return failure("UNKNOWN_ACTION");
            if (request.length() != (action.equals("dial") ? 2 : 1)
                    || (action.equals("dial") && !(request.opt("number") instanceof String)))
                return failure("INVALID_REQUEST");
            if (action.equals("status")) return status();
            if (action.equals("recentCalls")) return recentCalls();
            // Serialize all user actions and refresh state inside the lock to prevent double dial.
            synchronized (commandLock) {
                String before = checkedState();
                if (before.equals("unknown")) return failure("STATE_UNAVAILABLE");
                if (action.equals("dial")) {
                    if (!before.equals("idle")) return failure("CALL_NOT_IDLE");
                    if (android.os.SystemClock.elapsedRealtime() < nextDialAt) return failure("ACTION_PENDING");
                    if (!backend.canDial()) return failure("DIAL_UNAVAILABLE");
                    String number = normalizeNumber(request.getString("number"));
                    if (number == null) return failure("INVALID_NUMBER");
                    // Korea-specific consumer UI: emergency/service short codes are never dialed here.
                    // Samsung's emergency-classification APIs throw NPE even under shell attribution.
                    if (number.replace("+", "").length() < 9) return failure("SHORT_CODE_BLOCKED");
                    backend.dial(number);
                    // Telecom state changes asynchronously; never permit a duplicate dial in that gap.
                    nextDialAt = android.os.SystemClock.elapsedRealtime() + 3000;
                } else if (action.equals("answer")) {
                    if (!before.equals("ringing")) return failure("CALL_NOT_RINGING");
                    if (!backend.canAnswer()) return failure("ANSWER_UNAVAILABLE");
                    backend.answer();
                } else {
                    if (before.equals("idle")) return failure("NO_CALL");
                    if (!backend.canEnd()) return failure("END_UNAVAILABLE");
                    if (!backend.end()) return failure("END_REJECTED");
                }
                trace("ACTION action=" + action + " state=" + before + " outcome=requested");
                JSONObject response;
                try { response = status(); }
                catch (Exception unavailable) { response = snapshot("unknown"); }
                response.put("ok", true);
                response.put("result", "requested");
                return response;
            }
        } catch (Exception error) {
            Throwable cause = rootCause(error);
            String code = cause instanceof SecurityException ? "PERMISSION_DENIED"
                    : cause instanceof org.json.JSONException ? "INVALID_REQUEST" : "SERVICE_UNAVAILABLE";
            // action is either one of the fixed commands or invalid; raw JSON never reaches logs.
            trace("ERROR code=" + code);
            return failure(code);
        }
    }

    private JSONObject status() throws Exception { return snapshot(checkedState()); }

    /** Returns metadata only to Mac; never logs or persists call details on Android. */
    private JSONObject recentCalls() throws Exception {
        if (context == null) return failure("CALL_LOG_UNAVAILABLE");
        if (context.getPackageManager().getApplicationInfo(SHELL_PACKAGE, 0).uid != Process.myUid()
                || !SHELL_PACKAGE.equals(context.getPackageName())) return failure("CALL_LOG_UNAVAILABLE");
        if (context.checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED)
            return failure("CALL_LOG_PERMISSION_DENIED");
        org.json.JSONArray rows = new org.json.JSONArray();
        Uri uri = CallLog.Calls.CONTENT_URI.buildUpon().appendQueryParameter("limit", "50").build();
        String[] columns = { CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME,
                CallLog.Calls.DATE, CallLog.Calls.DURATION, CallLog.Calls.TYPE };
        try (HistoryProvider provider = new HistoryProvider();
             Cursor cursor = provider.query(uri, columns, context.getAttributionSource())) {
            if (cursor == null) return failure("CALL_LOG_UNAVAILABLE");
            int id = cursor.getColumnIndexOrThrow(CallLog.Calls._ID);
            int number = cursor.getColumnIndexOrThrow(CallLog.Calls.NUMBER);
            int name = cursor.getColumnIndexOrThrow(CallLog.Calls.CACHED_NAME);
            int date = cursor.getColumnIndexOrThrow(CallLog.Calls.DATE);
            int duration = cursor.getColumnIndexOrThrow(CallLog.Calls.DURATION);
            int type = cursor.getColumnIndexOrThrow(CallLog.Calls.TYPE);
            while (cursor.moveToNext() && rows.length() < 50) {
                JSONObject row = new JSONObject().put("id", cursor.getLong(id))
                        .put("number", cursor.isNull(number) ? JSONObject.NULL : cursor.getString(number))
                        .put("name", cursor.isNull(name) ? JSONObject.NULL : cursor.getString(name))
                        .put("date", cursor.getLong(date)).put("duration", cursor.getLong(duration))
                        .put("type", cursor.getInt(type));
                rows.put(row);
            }
        } catch (SecurityException denied) {
            trace("CALL_LOG_READ denied=true");
            return failure("CALL_LOG_PERMISSION_DENIED");
        } catch (RuntimeException unavailable) {
            trace("CALL_LOG_READ failed=true");
            return failure("CALL_LOG_UNAVAILABLE");
        }
        trace("CALL_LOG_READ count=" + rows.length());
        return new JSONObject().put("ok", true).put("state", checkedState()).put("build", BUILD).put("calls", rows);
    }

    /** Shell UserService has no registered application thread; use Android content CLI's lease API. */
    private static final class HistoryProvider implements AutoCloseable {
        private final Object manager;
        private final Class<?> managerAPI = Class.forName("android.app.IActivityManager");
        private final android.os.IBinder token = new android.os.Binder();
        private final Object provider;
        HistoryProvider() throws Exception {
            manager = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
            Object holder = managerAPI.getMethod("getContentProviderExternal", String.class, int.class,
                    android.os.IBinder.class, String.class).invoke(manager, "call_log", 0, token, "gcb-history");
            if (holder == null) throw new IllegalStateException("provider-unavailable");
            provider = holder.getClass().getField("provider").get(holder);
        }
        Cursor query(Uri uri, String[] columns, android.content.AttributionSource source) throws Exception {
            Bundle args = new Bundle();
            args.putString("android:query-arg-sql-sort-order", CallLog.Calls.DATE + " DESC");
            return (Cursor) Class.forName("android.content.IContentProvider").getMethod("query",
                    android.content.AttributionSource.class, Uri.class, String[].class, Bundle.class,
                    Class.forName("android.os.ICancellationSignal")).invoke(provider, source, uri, columns, args, null);
        }
        @Override public void close() throws Exception {
            managerAPI.getMethod("removeContentProviderExternalAsUser", String.class, android.os.IBinder.class,
                    int.class).invoke(manager, "call_log", token, 0);
        }
    }

    private String checkedState() throws Exception {
        String state = backend.state();
        return state.equals("idle") || state.equals("ringing") || state.equals("active") ? state : "unknown";
    }

    private JSONObject snapshot(String state) throws org.json.JSONException {
        JSONObject result = new JSONObject().put("ok", true).put("state", state).put("build", BUILD)
                .put("canDial", state.equals("idle") && backend.canDial()
                        && android.os.SystemClock.elapsedRealtime() >= nextDialAt)
                .put("canAnswer", state.equals("ringing") && backend.canAnswer())
                .put("canEnd", (state.equals("ringing") || state.equals("active")) && backend.canEnd());
        if (state.equals("ringing")) {
            // Read fresh on every poll (no cache): a stale number would name the wrong caller. Never logged.
            String number = null;
            try { number = backend.incomingNumber(); } catch (Throwable unavailable) { /* degrade to null */ }
            result.put("incomingNumber", number == null ? JSONObject.NULL : number);
        }
        return result;
    }

    private static JSONObject failure(String code) {
        try {
            return new JSONObject().put("ok", false).put("error", code).put("state", "unknown")
                    .put("canDial", false).put("canAnswer", false).put("canEnd", false).put("build", BUILD);
        } catch (org.json.JSONException impossible) { throw new AssertionError(impossible); }
    }

    static String normalizeNumber(String raw) {
        if (raw.length() == 0 || raw.length() > 32) return null;
        // trim() alone would silently accept controls around an otherwise valid number.
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (!((c >= '0' && c <= '9') || c == '+' || c == ' ' || c == '(' || c == ')' || c == '-')) return null;
        }
        String trimmed = raw.trim();
        StringBuilder normalized = new StringBuilder();
        int digits = 0;
        for (int i = 0; i < trimmed.length(); i++) {
            char value = trimmed.charAt(i);
            if (value >= '0' && value <= '9') { normalized.append(value); digits++; }
            else if (value == '+' && i == 0) normalized.append(value);
            else if (value != ' ' && value != '(' && value != ')' && value != '-') return null;
        }
        return digits >= 3 && normalized.length() <= 32 ? normalized.toString() : null;
    }

    /** Bounded read of the telephony registry dump; the reader never blocks past the 1.2 s deadline. */
    private static String registryDump() throws Exception {
        android.os.IBinder registry = (android.os.IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "telephony.registry");
        if (registry == null) return null;
        android.os.ParcelFileDescriptor[] pipe = android.os.ParcelFileDescriptor.createPipe();
        final android.os.ParcelFileDescriptor writer = pipe[1];
        final java.util.concurrent.atomic.AtomicBoolean done = new java.util.concurrent.atomic.AtomicBoolean();
        Thread dumper = new Thread(() -> {
            try { registry.dump(writer.getFileDescriptor(), new String[0]); } catch (Throwable ignored) { }
            finally { try { writer.close(); } catch (IOException ignored) { } done.set(true); }
        }, "gcb-registry-dump");
        dumper.setDaemon(true);
        dumper.start();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        long deadline = android.os.SystemClock.elapsedRealtime() + 1200;
        try (InputStream in = new android.os.ParcelFileDescriptor.AutoCloseInputStream(pipe[0])) {
            byte[] buffer = new byte[4096];
            while (out.size() < 262144) {
                int ready = in.available();
                if (ready > 0) {
                    int n = in.read(buffer, 0, Math.min(buffer.length, ready));
                    if (n < 0) break;
                    out.write(buffer, 0, n);
                } else if (done.get()) {
                    if (in.available() == 0) break;
                } else if (android.os.SystemClock.elapsedRealtime() > deadline) break;
                else Thread.sleep(10);
            }
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    private static Throwable rootCause(Throwable error) {
        Throwable result = error;
        for (int i = 0; i < 8 && result.getCause() != null && result.getCause() != result; i++) result = result.getCause();
        return result;
    }

    private static void stageFailure(String stage, Throwable error) {
        Log.i("GCB_CONTROL", "FAIL stage=" + stage + " exception=" + error.getClass().getSimpleName()
                + " cause=" + rootCause(error).getClass().getSimpleName());
    }

    private static void identityMetadata(String stage, Context context) throws Exception {
        int ownerUid = context.getPackageManager().getApplicationInfo(SHELL_PACKAGE, 0).uid;
        android.content.AttributionSource attribution = context.getAttributionSource();
        Log.i("GCB_CONTROL", "IDENTITY stage=" + stage + " processUid=" + Process.myUid()
                + " shellOwnerUid=" + ownerUid + " applicationUid=" + context.getApplicationInfo().uid
                + " contextPackageMatches=" + SHELL_PACKAGE.equals(context.getPackageName())
                + " attributionUid=" + attribution.getUid()
                + " attributionPackageMatches=" + SHELL_PACKAGE.equals(attribution.getPackageName())
                + " applicationContextSame=" + (context.getApplicationContext() == context));
    }

    private static void verifyManagerContext(Object manager, Context expected, String stage) throws Exception {
        java.lang.reflect.Field field = manager.getClass().getDeclaredField("mContext");
        field.setAccessible(true);
        Context actual = (Context) field.get(manager);
        identityMetadata(stage, actual);
        if (actual != expected || actual.getAttributionSource().getUid() != Process.myUid()
                || !SHELL_PACKAGE.equals(actual.getPackageName())
                || !SHELL_PACKAGE.equals(actual.getAttributionSource().getPackageName()))
            throw new SecurityException("manager-identity-mismatch");
    }

    /** Safe startup check: reads identity, permission/API presence, and aggregate state only. */
    public static String selfTest(Context context) throws Exception {
        AndroidBackend backend = new AndroidBackend(context);
        String state = backend.state();
        String result = "build=" + BUILD + " uid=" + Process.myUid() + " package=" + SHELL_PACKAGE
                + " state=" + state + " dial=" + backend.canDial()
                + " answer=" + backend.canAnswer() + " end=" + backend.canEnd() + " commandsInvoked=false";
        Log.i("GCB_CONTROL", "CONFIG_VERIFIED " + result);
        return result;
    }

    interface Backend {
        String state() throws Exception;
        boolean canDial();
        boolean canAnswer();
        boolean canEnd();
        /** Caller number while ringing, or null when unknown. Must not log the value. */
        default String incomingNumber() { return null; }
        void dial(String number) throws Exception;
        void answer() throws Exception;
        boolean end() throws Exception;
    }

    private static final class AndroidBackend implements Backend {
        private final Context shell;
        private final TelecomManager telecom;
        private final TelephonyManager telephony;
        private final Method serviceGetter, getState, placeCall, answerCall, endCall;

        AndroidBackend(Context base) throws Exception {
            // ContextImpl.createPackageContext preserves the creator's op-package attribution.
            // Record that distinction without dumping package names or exception messages.
            try { identityMetadata("PACKAGE_CONTEXT", base.createPackageContext(SHELL_PACKAGE, 0)); }
            catch (Exception diagnosticFailure) { stageFailure("PACKAGE_CONTEXT_DIAGNOSTIC", diagnosticFailure); }
            String stage = "SHELL_CONTEXT";
            try {
                shell = CallAudioBuilders.shellContext(base);
                identityMetadata(stage, shell);
                if (Process.myUid() != 2000
                        || shell.getPackageManager().getApplicationInfo(SHELL_PACKAGE, 0).uid != Process.myUid()
                        || !SHELL_PACKAGE.equals(shell.getPackageName())
                        || shell.getAttributionSource().getUid() != Process.myUid()
                        || !SHELL_PACKAGE.equals(shell.getAttributionSource().getPackageName()))
                    throw new SecurityException("shell-identity-mismatch");
                // ContextWrapper.getSystemService delegates to base and could return its cached
                // manager. Construct each manager with the explicit, verified shell context.
                stage = "TELECOM_CONSTRUCTOR";
                telecom = TelecomManager.class.getDeclaredConstructor(Context.class).newInstance(shell);
                stage = "TELECOM_CONTEXT";
                verifyManagerContext(telecom, shell, stage);
                stage = "TELEPHONY_CONSTRUCTOR";
                telephony = TelephonyManager.class.getDeclaredConstructor(Context.class).newInstance(shell);
                stage = "TELEPHONY_CONTEXT";
                verifyManagerContext(telephony, shell, stage);
                stage = "API_LOOKUP";
                Class<?> api = Class.forName("com.android.internal.telecom.ITelecomService");
                serviceGetter = TelecomManager.class.getDeclaredMethod("getTelecomService");
                serviceGetter.setAccessible(true);
                getState = api.getMethod("getCallStateUsingPackage", String.class, String.class);
                placeCall = api.getMethod("placeCall", Uri.class, Bundle.class, String.class, String.class);
                answerCall = api.getMethod("acceptRingingCallWithVideoState", String.class, int.class);
                endCall = api.getMethod("endCall", String.class);
                TelephonyManager.class.getMethod("isEmergencyNumber", String.class);
                stage = "PERMISSION_CHECK";
                Log.i("GCB_CONTROL", "PERMISSIONS read=" + allowed(Manifest.permission.READ_PHONE_STATE)
                        + " dial=" + canDial() + " answer=" + canAnswer() + " end=" + canEnd());
            } catch (Exception error) {
                stageFailure(stage, error);
                throw error;
            }
        }

        private boolean allowed(String permission) {
            return shell.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
        }

        private Object invoke(String stage, Method method, Object... arguments) throws Exception {
            try {
                Object service = serviceGetter.invoke(telecom);
                if (service == null) throw new IllegalStateException("service-unavailable");
                return method.invoke(service, arguments);
            } catch (Exception failure) {
                stageFailure(stage, failure);
                Throwable cause = rootCause(failure);
                if (cause instanceof Exception) throw (Exception) cause;
                throw failure;
            }
        }

        @Override public String state() throws Exception {
            if (!allowed(Manifest.permission.READ_PHONE_STATE)) {
                SecurityException failure = new SecurityException("state-permission");
                stageFailure("STATE_PERMISSION", failure);
                throw failure;
            }
            int state = (Integer) invoke("STATE_BINDER", getState, SHELL_PACKAGE, null);
            if (state == TelephonyManager.CALL_STATE_IDLE) return "idle";
            if (state == TelephonyManager.CALL_STATE_RINGING) return "ringing";
            if (state == TelephonyManager.CALL_STATE_OFFHOOK) return "active";
            return "unknown";
        }
        @Override public boolean canDial() { return allowed(Manifest.permission.CALL_PHONE); }
        @Override public boolean canAnswer() {
            return allowed(Manifest.permission.ANSWER_PHONE_CALLS) || allowed(Manifest.permission.MODIFY_PHONE_STATE);
        }
        @Override public boolean canEnd() { return canAnswer(); }
        /**
         * Same data as `dumpsys telephony.registry`: shell holds DUMP, and this needs no Context,
         * app thread, or READ_CALL_LOG. Any failure degrades to null.
         */
        @Override public String incomingNumber() {
            try { return IncomingNumber.parse(registryDump()); }
            catch (Throwable unavailable) { return null; }
        }
        @Override public void dial(String number) throws Exception {
            invoke("DIAL_BINDER", placeCall, Uri.fromParts("tel", number, null), new Bundle(), SHELL_PACKAGE, null);
        }
        @Override public void answer() throws Exception {
            // Explicit audio-only answer; accepting a phone call does not opt into camera capture.
            invoke("ANSWER_BINDER", answerCall, SHELL_PACKAGE, 0);
        }
        @Override public boolean end() throws Exception { return Boolean.TRUE.equals(invoke("END_BINDER", endCall, SHELL_PACKAGE)); }
    }
}
