import android.content.Context;
import android.media.*;
import java.lang.reflect.Field;
import com.galaxycallbridge.diagnostics.CallAudioBuilders;

/** Validates the production builders on-device; NEVER calls AudioRecord/Track build(). */
public final class BuilderContractProbe {
    static Object field(Object object,String name) throws Exception {
        Field f=object.getClass().getDeclaredField(name); f.setAccessible(true); return f.get(object);
    }
    static void check(Object builder,boolean input) throws Exception {
        Context c=(Context)field(builder,"mContext");
        if(c.getAttributionSource().getUid()!=android.os.Process.myUid()
                || !"com.android.shell".equals(c.getAttributionSource().getPackageName())) throw new AssertionError("identity");
        AudioAttributes a=(AudioAttributes)field(builder,"mAttributes");
        int actual=(Integer)AudioAttributes.class.getDeclaredMethod(input?"getCapturePreset":"getSystemUsage").invoke(a);
        int expected=input?MediaRecorder.AudioSource.VOICE_DOWNLINK:AudioAttributes.class.getDeclaredField("USAGE_CALL_ASSISTANT").getInt(null);
        if(actual!=expected) throw new AssertionError("attributes");
        if(!field(builder,"mCallRedirectionMode").equals(AudioManager.class.getDeclaredField("CALL_REDIRECT_PSTN").get(null))) throw new AssertionError("redirection");
        AudioFormat f=(AudioFormat)field(builder,"mFormat");
        if(f.getSampleRate()!=16000 || f.getEncoding()!=AudioFormat.ENCODING_PCM_16BIT || f.getChannelMask()!=(input?AudioFormat.CHANNEL_IN_MONO:AudioFormat.CHANNEL_OUT_MONO)) throw new AssertionError("format");
        System.out.println("PASS "+(input?"downlink":"uplink")+" uid=2000 package=com.android.shell attributes="+actual+" PSTN=true PCM16=16000Hz mono=true endpointBuilt=false");
    }
    public static void main(String[] args) throws Exception {
        Class<?> at=Class.forName("android.app.ActivityThread");
        Object thread=at.getDeclaredMethod("systemMain").invoke(null);
        Context context=(Context)at.getDeclaredMethod("getSystemContext").invoke(thread);
        AudioFormat in=new AudioFormat.Builder().setSampleRate(16000).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build();
        AudioFormat out=new AudioFormat.Builder().setSampleRate(16000).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build();
        check(CallAudioBuilders.downlink(context,in),true);
        check(CallAudioBuilders.uplink(context,out),false);
        System.exit(0);
    }
}
