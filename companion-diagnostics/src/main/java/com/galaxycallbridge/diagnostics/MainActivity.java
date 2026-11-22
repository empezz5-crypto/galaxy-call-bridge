package com.galaxycallbridge.diagnostics;

import android.app.Activity;
import android.content.ComponentName;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import rikka.shizuku.Shizuku;

public final class MainActivity extends Activity {
    private static final int REQUEST_SHIZUKU = 5317;
    private static final int TRANSACTION_DIAGNOSTICS = IBinder.FIRST_CALL_TRANSACTION;
    private static final int TRANSACTION_TUNNEL_START = IBinder.FIRST_CALL_TRANSACTION + 1;
    private static final int TRANSACTION_TUNNEL_STOP = IBinder.FIRST_CALL_TRANSACTION + 2;
    private static final String DESCRIPTOR = "com.galaxycallbridge.diagnostics.PROBE";
    private TextView status;
    private IBinder service;
    private boolean binding;
    private final Shizuku.OnBinderReceivedListener binderReceived = () -> runOnUiThread(() -> {
        status.setText("Shizuku binder 수신됨 (API " + Shizuku.getVersion() + "). 이 앱만 권한을 요청할 수 있습니다.");
        try {
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) bindProbe();
        } catch (Throwable denied) {
            status.setText("이 진단 앱의 Shizuku 권한이 필요합니다.");
        }
    });
    private final Shizuku.OnBinderDeadListener binderDead = () -> runOnUiThread(() -> {
        status.setText("Shizuku binder 연결이 끊겼습니다.");
    });
    private final Shizuku.OnRequestPermissionResultListener permissionListener = (requestCode, grantResult) -> {
        if (requestCode == REQUEST_SHIZUKU) {
            status.setText(grantResult == PackageManager.PERMISSION_GRANTED
                    ? "이 진단 앱의 Shizuku 접근이 허용되었습니다. 아래에서 UID/권한 검사 또는 비캡처 질의를 실행하세요."
                    : "Shizuku 접근이 거부되었습니다.");
            if (grantResult == PackageManager.PERMISSION_GRANTED) bindProbe();
        }
    };
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            binding = false;
            service = binder;
            status.setText("Shizuku UserService 연결됨. 아직 오디오 캡처/재생은 실행되지 않았습니다.");
            tunnel(true);
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            binding = false;
            service = null;
            status.setText("Shizuku UserService 연결 해제됨.");
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Shizuku.addRequestPermissionResultListener(permissionListener);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (20 * getResources().getDisplayMetrics().density);
        content.setPadding(pad, pad, pad, pad);
        TextView title = new TextView(this);
        title.setText("GalaxyCallBridge 동반 진단");
        title.setTextSize(24);
        content.addView(title);
        TextView explanation = new TextView(this);
        explanation.setText("통화가 연결되기 전에는 오디오를 열지 않습니다. 허용된 Shizuku가 있으면 자동 연결하고, Mac이 최근 통화목록을 요청할 때만 필요한 정보를 전달합니다. 원시 음성은 저장하지 않습니다.");
        content.addView(explanation);
        status = new TextView(this);
        status.setText("상태: Shizuku 연결 및 권한은 아직 확인되지 않았습니다.");
        status.setTextSize(16);
        content.addView(status);
        addButton(content, "이 진단 앱에만 Shizuku 권한 요청", v -> requestShizuku());
        addButton(content, "UID / 권한 / API 존재 확인", v -> runDiagnostics(false));
        addButton(content, "비캡처 통화 오디오 가능 여부 질의", v -> runDiagnostics(true));
        addButton(content, "로컬 PCM 터널 서버 시작", v -> tunnel(true));
        addButton(content, "로컬 PCM 터널 서버 중지", v -> tunnel(false));
        ScrollView scroll = new ScrollView(this);
        scroll.addView(content);
        setContentView(scroll);
        Shizuku.addBinderReceivedListenerSticky(binderReceived);
        Shizuku.addBinderDeadListener(binderDead);
        if (Shizuku.pingBinder()) binderReceived.onBinderReceived();
    }

    private void addButton(LinearLayout parent, String label, View.OnClickListener listener) {
        Button button = new Button(this);
        button.setText(label);
        button.setOnClickListener(listener);
        parent.addView(button);
    }

    private void requestShizuku() {
        try {
            if (Shizuku.isPreV11()) { status.setText("Shizuku v11 이상이 필요합니다."); return; }
            if (!Shizuku.pingBinder()) {
                status.setText("Shizuku binder를 아직 받지 못했습니다. Shizuku 서비스 실행 상태를 확인하세요.");
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                status.setText("이 진단 앱의 Shizuku 권한은 이미 허용되어 있습니다.");
                bindProbe();
            } else {
                Shizuku.requestPermission(REQUEST_SHIZUKU);
            }
        } catch (Throwable e) {
            status.setText("Shizuku 상태 확인 실패: " + e.getClass().getSimpleName() + " — " + String.valueOf(e.getMessage()));
        }
    }

    private void bindProbe() {
        if (binding || service != null) return;
        binding = true;
        try {
            Shizuku.bindUserService(new Shizuku.UserServiceArgs(
                    new ComponentName(getPackageName(), ProbeService.class.getName()))
                    .tag("galaxy-call-bridge-read-only-diagnostics")
                    .version(ProbeService.SERVICE_VERSION).processNameSuffix("probe").daemon(true), connection);
        } catch (Throwable e) {
            binding = false;
            status.setText("Shizuku UserService 시작 실패: " + e.getClass().getSimpleName());
        }
    }

    private void runDiagnostics(boolean runCapabilityQuery) {
        IBinder target = service;
        if (target == null) { status.setText("먼저 위 버튼으로 이 앱의 Shizuku 권한을 요청하고 UserService를 연결하세요."); return; }
        new Thread(() -> {
            Parcel data = Parcel.obtain();
            Parcel reply = Parcel.obtain();
            try {
                data.writeInterfaceToken(DESCRIPTOR);
                data.writeInt(runCapabilityQuery ? 1 : 0);
                target.transact(TRANSACTION_DIAGNOSTICS, data, reply, 0);
                reply.readException();
                String text = reply.readString();
                runOnUiThread(() -> status.setText(text));
            } catch (Throwable e) {
                runOnUiThread(() -> status.setText("진단 실패: " + e.getClass().getSimpleName()));
            } finally {
                data.recycle();
                reply.recycle();
            }
        }).start();
    }

    private void tunnel(boolean start) {
        IBinder target=service; if(target==null){status.setText("먼저 Shizuku UserService를 연결하세요.");return;}
        new Thread(() -> { Parcel d=Parcel.obtain(), r=Parcel.obtain(); try { d.writeInterfaceToken(DESCRIPTOR); target.transact(start?TRANSACTION_TUNNEL_START:TRANSACTION_TUNNEL_STOP,d,r,0); r.readException(); String msg=r.readString(); runOnUiThread(()->status.setText(msg+" · PCM은 Mac의 명시적 시작 전까지 열리지 않습니다.")); } catch(Throwable e){runOnUiThread(()->status.setText("터널 제어 실패: "+e.getClass().getSimpleName()));} finally{d.recycle();r.recycle();} }).start();
    }

    @Override protected void onDestroy() {
        Shizuku.removeRequestPermissionResultListener(permissionListener);
        Shizuku.removeBinderReceivedListener(binderReceived);
        Shizuku.removeBinderDeadListener(binderDead);
        if (service != null) {
            try { Shizuku.unbindUserService(new Shizuku.UserServiceArgs(
                    new ComponentName(getPackageName(), ProbeService.class.getName()))
                    .tag("galaxy-call-bridge-read-only-diagnostics")
                    .version(ProbeService.SERVICE_VERSION).processNameSuffix("probe").daemon(true), connection, false); }
            catch (Throwable ignored) { }
        }
        super.onDestroy();
    }
}
