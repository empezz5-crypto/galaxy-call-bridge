package com.galaxycallbridge.diagnostics;

import android.content.Context;
import android.media.AudioManager;
import android.os.Binder;
import android.os.Parcel;
import android.os.Process;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.AudioManager;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicBoolean;

import java.lang.reflect.Method;

/** Shizuku UserService: read-only UID, permission and API capability diagnostics. */
public final class ProbeService extends Binder {
    private static final int TRANSACTION_DIAGNOSTICS = FIRST_CALL_TRANSACTION;
    private static final String CALL_AUDIO_INTERCEPTION = "android.permission.CALL_AUDIO_INTERCEPTION";
    static final int SERVICE_VERSION = 2026103101;
    static final String BUILD = "20261031-059-r1";
    private final long startedAt = System.currentTimeMillis();
    private final Context context;
    private static void trace(String value) { android.util.Log.i("GCB_PCM", value); }
    private static String failureCode(Throwable error) {
        Throwable cause = error;
        for (int i=0; i<8 && cause.getCause()!=null && cause.getCause()!=cause; i++) cause=cause.getCause();
        return error.getClass().getSimpleName()+":"+cause.getClass().getSimpleName();
    }
    private volatile LocalServerSocket server;
    private volatile Thread serverThread;
    private CallControlServer controlServer;
    private volatile LocalSocket activeClient;
    private final AtomicBoolean running = new AtomicBoolean(false);
    private static final int PORT_START = FIRST_CALL_TRANSACTION + 1, PORT_STOP = FIRST_CALL_TRANSACTION + 2;
    private static final int MAGIC = 0x47434231, MAX = 640;
    private static final int HELLO=1, STATUS=2, SILENCE=0x20, SILENCE_RESULT=0x21, START_DOWN=0x30, DOWN_PCM=0x31, START_UP=0x32, UP_PCM=0x33, STOP=0x34, START_DUPLEX=0x35;

    public ProbeService(Context context) {
        this.context = context;
        trace("SERVICE build="+BUILD+" pid="+Process.myPid()+" started="+startedAt);
    }

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
        if (code == 16777115) {
            // Shizuku requires this reserved transaction to actually terminate a UserService.
            stopAllServers(); System.exit(0); return true;
        }
        if (code == PORT_START || code == PORT_STOP) {
            try { data.enforceInterface("com.galaxycallbridge.diagnostics.PROBE");
                if (code == PORT_START) {
                    // A PCM configuration failure must not disable metadata/call controls.
                    try { startControlServer(); }
                    catch (Throwable failure) { trace("CONTROL_START_ERROR:"+failureCode(failure)); }
                    CallAudioBuilders.verifyConfiguration(context);
                    startServer();
                } else stopAllServers();
                reply.writeNoException(); reply.writeString(code == PORT_START ? "로컬 오디오 터널 서버 시작" : "로컬 오디오 터널 서버 중지"); return true;
            } catch (Throwable e) { reply.writeException(e instanceof Exception ? (Exception)e : new RuntimeException(e)); return true; }
        }
        if (code != TRANSACTION_DIAGNOSTICS) return false;
        try {
            data.enforceInterface("com.galaxycallbridge.diagnostics.PROBE");
            boolean runCapabilityQuery = data.readInt() != 0;
            int uid = Process.myUid();
            int permission = context.checkSelfPermission(CALL_AUDIO_INTERCEPTION);
            boolean methodPresent = false;
            String query = "미실행";
            try {
                Method method = AudioManager.class.getDeclaredMethod("isPstnCallAudioInterceptable");
                methodPresent = true;
                if (runCapabilityQuery) {
                    AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
                    Object value = method.invoke(audio);
                    query = String.valueOf(value);
                }
            } catch (NoSuchMethodException e) {
                query = runCapabilityQuery ? "API 없음" : "확인 불가";
            } catch (Throwable e) {
                query = "질의 오류: " + e.getClass().getSimpleName();
            }
            String result = "실행 UID: " + uid
                    + "\\n예상 shell UID(2000): " + (uid == 2000 ? "일치" : "불일치")
                    + "\\nCALL_AUDIO_INTERCEPTION 보유: " + (permission == android.content.pm.PackageManager.PERMISSION_GRANTED ? "예" : "아니오")
                    + "\\nAudioManager 질의 API 존재: " + (methodPresent ? "예" : "아니오")
                    + "\\n비캡처 가능 여부 질의: " + query
                    + "\\n\\n이 검사는 PCM을 열거나 읽거나 쓰지 않습니다.";
            reply.writeNoException();
            reply.writeString(result);
            return true;
        } catch (Throwable e) {
            reply.writeException(e instanceof Exception ? (Exception) e : new RuntimeException(e));
            return true;
        }
    }

    private synchronized void startControlServer() throws Exception {
        if (controlServer == null) {
            CallControlServer.selfTest(context);
            controlServer = new CallControlServer(context);
        }
        controlServer.start();
    }
    private synchronized void stopAllServers() {
        if (controlServer != null) { controlServer.stop(); controlServer=null; }
        stopServer();
    }
    private synchronized void startServer() throws IOException {
        if (running.get()) return;
        final LocalServerSocket listener = new LocalServerSocket("gcb_audio_v1");
        server=listener; running.set(true);
        serverThread=new Thread(() -> {
            while(running.get() && server==listener) {
                try {
                    LocalSocket socket=listener.accept();
                    synchronized(ProbeService.this) {
                        if(!running.get() || server!=listener || activeClient!=null) { socket.close(); continue; }
                        activeClient=socket;
                    }
                    new Thread(() -> serve(socket),"gcb-audio-client").start();
                } catch(IOException failure) {
                    synchronized(ProbeService.this) { if(server==listener) stopServer(); }
                }
            }
        },"gcb-audio-listener");
        serverThread.start();
    }
    private synchronized void stopServer() {
        running.set(false);
        try { if(server!=null) server.close(); } catch(Exception ignored) {}
        server=null;
        try { if(activeClient!=null) activeClient.close(); } catch(Exception ignored) {}
        // Keep the reservation until serve() has stopped and released both endpoints.
    }
    private void serve(LocalSocket socket) {
        AudioRecord record=null; AudioTrack track=null;
        AtomicBoolean active=new AtomicBoolean(false);
        final String session=Long.toHexString(android.os.SystemClock.elapsedRealtimeNanos());
        String stage="HELLO", closeReason="peer-eof";
        long uplinkFrames=0, uplinkBytes=0;
        DataOutputStream out=null;
        Thread reader=null, watchdog=null;
        try {
            DataInputStream in=new DataInputStream(socket.getInputStream());
            out=new DataOutputStream(socket.getOutputStream());
            frameLocked(out, HELLO, ("GCB1_ANDROID_PCM_V1;build="+BUILD+";pid="+Process.myPid()+";started="+startedAt+";session="+session).getBytes("UTF-8"));
            trace("OPEN session="+session);
            while(running.get()) {
                stage="COMMAND_READ";
                int magic=in.readInt(), type=in.readUnsignedShort(), length=in.readUnsignedShort();
                if(magic!=MAGIC || length>MAX) throw new IOException("invalid-frame");
                byte[] payload=new byte[length]; in.readFully(payload);
                if(type!=UP_PCM) trace("RX session="+session+" kind="+type+" bytes="+length);
                if(type==SILENCE) frameLocked(out,SILENCE_RESULT,payload);
                else if(type==START_DOWN || type==START_UP || type==START_DUPLEX) {
                    stage="PREFLIGHT";
                    if(length!=0 || active.get() || record!=null || track!=null || !canRun()) { frameLocked(out,STATUS,"BLOCKED:call-permission-capability".getBytes("UTF-8")); continue; }
                    try {
                        // Create exactly the explicitly selected endpoints, with independent channel masks.
                        if(type==START_DOWN || type==START_DUPLEX) {
                            stage="DOWNLINK_FORMAT";
                            AudioFormat f=new AudioFormat.Builder().setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build();
                            stage="DOWNLINK_ATTRIBUTION_AND_BUILDER";
                            AudioRecord.Builder builder=CallAudioBuilders.downlink(context,f);
                            stage="RECORD_BUILD"; record=builder.build();
                        }
                        if(type==START_UP || type==START_DUPLEX) {
                            stage="UPLINK_FORMAT";
                            AudioFormat f=new AudioFormat.Builder().setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build();
                            stage="UPLINK_ATTRIBUTION_AND_BUILDER";
                            AudioTrack.Builder builder=CallAudioBuilders.uplink(context,f);
                            stage="TRACK_BUILD"; track=builder.build();
                        }
                        stage="START_PREFLIGHT";
                        if(!running.get() || !canRun()) throw new IllegalStateException("call-no-longer-active");
                        if(record!=null) {
                            stage="RECORD_START"; record.startRecording();
                            if(record.getRecordingState()!=AudioRecord.RECORDSTATE_RECORDING) throw new IllegalStateException("record-not-started");
                        }
                        if(track!=null) {
                            stage="TRACK_PLAY"; track.play();
                            if(track.getPlayState()!=AudioTrack.PLAYSTATE_PLAYING) throw new IllegalStateException("track-not-started");
                        }
                        active.set(true);
                    } catch(Throwable failure) {
                        String result="ERROR:START:"+stage+":"+failureCode(failure);
                        trace("FAIL session="+session+" "+result);
                        closeReason=result;
                        terminalAndClose(out,result,socket); break;
                    }
                    stage="STARTED_WRITE";
                    frameLocked(out,STATUS,"STARTED".getBytes("UTF-8"));
                    final DataOutputStream output=out;
                    // A separate watchdog also covers blocked AudioRecord reads and a stalled uplink.
                    watchdog=new Thread(() -> {
                        long end=(type==START_DOWN || type==START_DUPLEX) ? Long.MAX_VALUE : android.os.SystemClock.elapsedRealtime()+60000;
                        try {
                            while(active.get()) {
                                Thread.sleep(250);
                                if(active.get() && (android.os.SystemClock.elapsedRealtime()>=end || !canRun())) {
                                    if(active.getAndSet(false)) {
                                        trace("CLOSE session="+session+" owner=watchdog reason=call-or-timeout");
                                        terminalAndClose(output,"STOPPED:call-or-timeout",socket);
                                    }
                                }
                            }
                        } catch(InterruptedException expected) { }
                        catch(Throwable failure) { trace("WATCHDOG session="+session+" "+failureCode(failure)); try { socket.close(); } catch(IOException ignored) {} }
                    },"gcb-watchdog");
                    watchdog.start();
                    if(record!=null) {
                        AudioRecord r=record;
                        reader=new Thread(() -> readDownlink(r,output,active,socket,session),"gcb-downlink"); reader.start();
                    }
                } else if(type==UP_PCM && track!=null && active.get()) {
                    stage="TRACK_WRITE";
                    if(payload.length==0 || payload.length%2!=0) throw new IOException("invalid-pcm-length");
                    int written=writeUplink(track,payload,active);
                    if(written!=payload.length) {
                        closeReason="ERROR:WRITE_RESULT:"+written;
                        terminalAndClose(out,closeReason,socket); break;
                    }
                    uplinkFrames++; uplinkBytes+=written;
                } else if(type==UP_PCM) {
                    closeReason="ERROR:PROTOCOL:UPLINK_NOT_STARTED";
                    terminalAndClose(out,closeReason,socket); break;
                } else if(type==STOP) {
                    active.set(false);
                    closeReason="host-stop";
                    terminalAndClose(out,"STOPPED",socket); break;
                } else if(type==0x22 && !active.get()) {
                    // Non-capture diagnostic: exercise the same error frame and close path.
                    closeReason="ERROR:SELFTEST:IOException";
                    terminalAndClose(out,closeReason,socket); break;
                }
            }
        } catch(java.io.EOFException end) { closeReason="peer-eof:"+stage; }
        catch(Throwable failure) {
            closeReason="ERROR:SESSION:"+stage+":"+failureCode(failure);
            if(out!=null) try { terminalAndClose(out,closeReason,socket); } catch(Throwable sendFailure) { trace("ERROR_DELIVERY_FAILED session="+session+" "+failureCode(sendFailure)); }
        } finally {
            active.set(false);
            if(watchdog!=null) watchdog.interrupt();
            try { socket.close(); } catch(IOException ignored) {}
            stopEndpoints(record,track);
            if(reader!=null) try { reader.join(500); } catch(InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            release(record,track);
            trace("CLOSE session="+session+" reason="+closeReason+" uplinkFrames="+uplinkFrames+" uplinkBytes="+uplinkBytes);
            synchronized(this) { if(activeClient==socket) activeClient=null; }
        }
    }
    private boolean canRun() {
        if (context.checkSelfPermission(CALL_AUDIO_INTERCEPTION)!=android.content.pm.PackageManager.PERMISSION_GRANTED) return false;
        AudioManager a=(AudioManager)context.getSystemService(Context.AUDIO_SERVICE);
        if(a.getMode()!=AudioManager.MODE_IN_CALL) return false;
        try { Method m=AudioManager.class.getDeclaredMethod("isPstnCallAudioInterceptable"); m.setAccessible(true); return Boolean.TRUE.equals(m.invoke(a)); } catch(Throwable e) { return false; }
    }
    private void readDownlink(AudioRecord r,DataOutputStream out,AtomicBoolean active,LocalSocket socket,String session) {
        byte[] b=new byte[MAX]; long frames=0, bytes=0;
        String result="STOPPED:reader-ended";
        String stage="RECORD_READ";
        try {
            while(active.get() && running.get()) {
                stage="RECORD_READ";
                int n=r.read(b,0,b.length);
                if(!active.get()) return;
                if(n<=0) { result="ERROR:READ_RESULT:"+n; break; }
                stage="SOCKET_WRITE";
                synchronized(out) {
                    if(!active.get()) return;
                    frame(out,DOWN_PCM,java.util.Arrays.copyOf(b,n));
                }
                frames++; bytes+=n;
            }
        } catch(Throwable failure) { result="ERROR:READ:"+stage+":"+failureCode(failure); }
        finally {
            trace("READER session="+session+" frames="+frames+" bytes="+bytes+" result="+result);
            if(active.getAndSet(false)) {
                try { terminalAndClose(out,result,socket); }
                catch(Throwable failure) { trace("ERROR_DELIVERY_FAILED session="+session+" "+failureCode(failure)); }
                try { socket.close(); } catch(IOException ignored) {}
            }
        }
    }
    private static void terminalAndClose(DataOutputStream out,String status,LocalSocket socket) throws IOException {
        // A stalled peer can hold the frame lock. Closing from another thread bounds shutdown.
        Thread closer=new Thread(() -> {
            try { Thread.sleep(250); socket.close(); }
            catch(InterruptedException expected) {} catch(IOException ignored) {}
        },"gcb-close-guard");
        closer.start();
        try { frameLocked(out,STATUS,status.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
        finally { try { socket.close(); } finally { closer.interrupt(); } }
    }
    private static int writeUplink(AudioTrack track,byte[] payload,AtomicBoolean active) throws InterruptedException {
        int offset=0;
        long deadline=android.os.SystemClock.elapsedRealtime()+250;
        while(active.get() && offset<payload.length) {
            int count=track.write(payload,offset,payload.length-offset,AudioTrack.WRITE_NON_BLOCKING);
            if(count<0) return count;
            offset+=count;
            if(offset==payload.length) break;
            if(android.os.SystemClock.elapsedRealtime()>=deadline) break;
            if(count==0) Thread.sleep(5);
        }
        return offset;
    }
    private static void stopEndpoints(AudioRecord r,AudioTrack t) {
        if(r!=null) try { r.stop(); } catch(Throwable ignored) {}
        if(t!=null) try { t.pause(); t.flush(); t.stop(); } catch(Throwable ignored) {}
    }
    private static void release(AudioRecord r,AudioTrack t) {
        if(r!=null) try { r.release(); } catch(Throwable failure) { trace("RELEASE record "+failureCode(failure)); }
        if(t!=null) try { t.release(); } catch(Throwable failure) { trace("RELEASE track "+failureCode(failure)); }
    }
    private static void frameLocked(DataOutputStream o,int type,byte[] b) throws IOException { synchronized(o) { frame(o,type,b); } }
    private static void frame(DataOutputStream o,int type,byte[] b) throws IOException {
        o.writeInt(MAGIC);o.writeShort(type);o.writeShort(b.length);o.write(b);o.flush();
        if(type==STATUS) trace("TX status="+new String(b,java.nio.charset.StandardCharsets.UTF_8));
    }
}
