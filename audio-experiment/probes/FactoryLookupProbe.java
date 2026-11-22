import android.media.AudioManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.AudioTrack;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

/** Read-only reflection: never invokes a factory or opens an audio endpoint. */
public final class FactoryLookupProbe {
    public static void main(String[] args) throws Exception {
        verify("getCallDownlinkExtractionAudioRecord", AudioRecord.class);
        verify("getCallUplinkInjectionAudioTrack", AudioTrack.class);
    }
    private static void verify(String name, Class<?> result) throws Exception {
        Method m=AudioManager.class.getDeclaredMethod(name,AudioFormat.class);
        if(m.getReturnType()!=result || Modifier.isStatic(m.getModifiers())) throw new AssertionError("Unexpected signature");
        System.out.println("PASS owner="+m.getDeclaringClass().getName()+" method="+name+" argument=AudioFormat result="+result.getSimpleName()+" instance=true invoked=false");
    }
}
