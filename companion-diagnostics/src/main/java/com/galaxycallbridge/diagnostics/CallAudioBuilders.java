package com.galaxycallbridge.diagnostics;

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.Process;

/** Same PSTN attributes as AudioManager factories, with explicit actual-shell attribution.
 * Preparing builders never allocates an audio endpoint; build() remains behind the Start gate.
 */
public final class CallAudioBuilders {
    static Context shellContext(Context base) throws Exception {
        if (Process.myUid()!=2000 || base.getPackageManager().getApplicationInfo("com.android.shell",0).uid!=Process.myUid())
            throw new SecurityException("shell-identity-mismatch");
        final AttributionSource source=new AttributionSource.Builder(Process.myUid())
                .setPackageName("com.android.shell").build();
        return new ContextWrapper(base) {
            @Override public String getPackageName() { return "com.android.shell"; }
            public String getOpPackageName() { return "com.android.shell"; }
            @Override public AttributionSource getAttributionSource() { return source; }
            @Override public Context getApplicationContext() { return this; }
        };
    }
    static int pstnMode() throws Exception {
        return AudioManager.class.getDeclaredField("CALL_REDIRECT_PSTN").getInt(null);
    }
    public static AudioRecord.Builder downlink(Context context, AudioFormat format) throws Exception {
        AudioAttributes.Builder attributes=new AudioAttributes.Builder();
        AudioAttributes.Builder.class.getDeclaredMethod("setInternalCapturePreset",int.class)
                .invoke(attributes,MediaRecorder.AudioSource.VOICE_DOWNLINK);
        AudioRecord.Builder builder=new AudioRecord.Builder().setContext(shellContext(context)).setAudioFormat(format);
        AudioRecord.Builder.class.getDeclaredMethod("setAudioAttributes",AudioAttributes.class).invoke(builder,attributes.build());
        AudioRecord.Builder.class.getDeclaredMethod("setCallRedirectionMode",int.class).invoke(builder,pstnMode());
        return builder;
    }
    public static AudioTrack.Builder uplink(Context context, AudioFormat format) throws Exception {
        int usage=AudioAttributes.class.getDeclaredField("USAGE_CALL_ASSISTANT").getInt(null);
        AudioAttributes.Builder attributes=new AudioAttributes.Builder().setContentType(AudioAttributes.CONTENT_TYPE_SPEECH);
        AudioAttributes.Builder.class.getDeclaredMethod("setSystemUsage",int.class).invoke(attributes,usage);
        AudioTrack.Builder builder=new AudioTrack.Builder().setContext(shellContext(context))
                .setAudioAttributes(attributes.build()).setAudioFormat(format);
        AudioTrack.Builder.class.getDeclaredMethod("setCallRedirectionMode",int.class).invoke(builder,pstnMode());
        return builder;
    }
    /** Non-capture contract check on the actual Shizuku context; no endpoint build(). */
    public static void verifyConfiguration(Context context) throws Exception {
        for(boolean input:new boolean[]{true,false}) {
            AudioFormat format=new AudioFormat.Builder().setSampleRate(16000)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(input?AudioFormat.CHANNEL_IN_MONO:AudioFormat.CHANNEL_OUT_MONO).build();
            Object builder=input?downlink(context,format):uplink(context,format);
            Context actual=(Context)field(builder,"mContext");
            if(actual.getAttributionSource().getUid()!=Process.myUid()
                    || !"com.android.shell".equals(actual.getAttributionSource().getPackageName()))
                throw new SecurityException("builder-attribution-mismatch");
            AudioAttributes attributes=(AudioAttributes)field(builder,"mAttributes");
            int value=(Integer)AudioAttributes.class.getDeclaredMethod(input?"getCapturePreset":"getSystemUsage").invoke(attributes);
            int expected=input?MediaRecorder.AudioSource.VOICE_DOWNLINK:AudioAttributes.class.getDeclaredField("USAGE_CALL_ASSISTANT").getInt(null);
            if(value!=expected || !field(builder,"mCallRedirectionMode").equals(pstnMode()))
                throw new IllegalStateException("builder-routing-mismatch");
            AudioFormat actualFormat=(AudioFormat)field(builder,"mFormat");
            if(actualFormat.getSampleRate()!=16000 || actualFormat.getEncoding()!=AudioFormat.ENCODING_PCM_16BIT
                    || actualFormat.getChannelMask()!=format.getChannelMask()) throw new IllegalStateException("builder-format-mismatch");
            android.util.Log.i("GCB_PCM","CONFIG_VERIFIED direction="+(input?"downlink":"uplink")
                    +" uid="+Process.myUid()+" package=com.android.shell attributes="+value+" pstn=true endpointBuilt=false");
        }
    }
    private static Object field(Object object,String name) throws Exception {
        java.lang.reflect.Field field=object.getClass().getDeclaredField(name);
        field.setAccessible(true); return field.get(object);
    }

}
