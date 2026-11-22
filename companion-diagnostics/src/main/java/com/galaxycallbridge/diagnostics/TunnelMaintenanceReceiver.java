package com.galaxycallbridge.diagnostics;

import android.content.*;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.os.*;
import rikka.shizuku.Shizuku;

/** Shell-only, non-capture maintenance without bringing an Activity to the foreground. */
public final class TunnelMaintenanceReceiver extends BroadcastReceiver {
    private static ServiceConnection connection;
    @Override public void onReceive(Context context, Intent intent) {
        if (!"com.galaxycallbridge.diagnostics.PREPARE_TUNNEL".equals(intent.getAction())) return;
        if (((AudioManager)context.getSystemService(Context.AUDIO_SERVICE)).getMode()!=AudioManager.MODE_NORMAL) {
            android.util.Log.i("GCB_PCM","MAINTENANCE blocked=not-idle"); return;
        }
        PendingResult pending=goAsync();
        Handler handler=new Handler(Looper.getMainLooper());
        java.util.concurrent.atomic.AtomicBoolean finished=new java.util.concurrent.atomic.AtomicBoolean();
        Runnable finish=() -> { if(finished.compareAndSet(false,true)) pending.finish(); };
        handler.postDelayed(finish,8000);
        Shizuku.OnBinderReceivedListener listener=new Shizuku.OnBinderReceivedListener() {
            @Override public void onBinderReceived() {
                Shizuku.removeBinderReceivedListener(this);
                if(finished.get()) return;
                try {
                    if(Shizuku.checkSelfPermission()!=PackageManager.PERMISSION_GRANTED) { finish.run(); return; }
                    connection=new ServiceConnection() {
                        public void onServiceDisconnected(ComponentName name) {}
                        public void onServiceConnected(ComponentName name,IBinder binder) {
                            if(finished.get()) return;
                            Parcel data=Parcel.obtain(), reply=Parcel.obtain();
                            try {
                                data.writeInterfaceToken("com.galaxycallbridge.diagnostics.PROBE");
                                binder.transact(IBinder.FIRST_CALL_TRANSACTION+1,data,reply,0);
                                reply.readException();
                                android.util.Log.i("GCB_PCM","MAINTENANCE ready build="+ProbeService.BUILD);
                            } catch(Throwable e) { android.util.Log.i("GCB_PCM","MAINTENANCE error="+e.getClass().getSimpleName()); }
                            finally { data.recycle(); reply.recycle(); finish.run(); }
                        }
                    };
                    Shizuku.bindUserService(new Shizuku.UserServiceArgs(new ComponentName(context,ProbeService.class))
                        .tag("galaxy-call-bridge-read-only-diagnostics").version(ProbeService.SERVICE_VERSION)
                        .processNameSuffix("probe").daemon(true),connection);
                } catch(Throwable e) { android.util.Log.i("GCB_PCM","MAINTENANCE error="+e.getClass().getSimpleName()); finish.run(); }
            }
        };
        Shizuku.addBinderReceivedListenerSticky(listener);
        handler.postDelayed(() -> Shizuku.removeBinderReceivedListener(listener),8000);
    }
}
