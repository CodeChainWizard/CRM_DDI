


package ddi.crm.crm_new;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.telephony.TelephonyManager;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import android.os.Bundle;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String EVENT_CHANNEL = "com.example.incoming_call/events";
    private static final String HELPER_CHANNEL = "flutter_helper/helper";
    private static final int PERMISSION_REQUEST_CODE = 100;

    private EventChannel.EventSink eventSink;
    private BroadcastReceiver callReceiver;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        // Method Channel: for getting the phone number
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), HELPER_CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if (call.method.equals("getMyPhoneNumber")) {
                        handleGetMyPhoneNumber(result);
                    } else {
                        result.notImplemented();
                    }
                });

        // Event Channel: for listening to incoming calls
        new EventChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), EVENT_CHANNEL)
                .setStreamHandler(new EventChannel.StreamHandler() {
                    @Override
                    public void onListen(Object arguments, EventChannel.EventSink sink) {
                        eventSink = sink;
                    }

                    @Override
                    public void onCancel(Object arguments) {
                        eventSink = null;
                    }
                });

        checkPermissions();
        registerCallReceiver();
    }

    private void checkPermissions() {
        String[] permissions = {
                Manifest.permission.READ_PHONE_STATE,
                Manifest.permission.READ_PHONE_NUMBERS
        };
        boolean allGranted = true;
        for (String permission : permissions) {
            if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
                allGranted = false;
                break;
            }
        }
        if (!allGranted) {
            ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_CODE);
        }
    }

    private void handleGetMyPhoneNumber(MethodChannel.Result result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_NUMBERS)
                == PackageManager.PERMISSION_GRANTED) {
            try {
                TelephonyManager telephonyManager = (TelephonyManager) getSystemService(Context.TELEPHONY_SERVICE);
                String number = telephonyManager.getLine1Number();
                result.success(number != null ? number : "");
                if (eventSink != null) {
                    eventSink.success("MY_PHONE_NUMBER:" + (number != null ? number : ""));
                }
            } catch (SecurityException e) {
                result.error("PERMISSION_DENIED", "Phone number permission denied", e.getMessage());
            } catch (Exception e) {
                result.error("UNAVAILABLE", "Phone number not available", e.getMessage());
            }
        } else {
            result.error("PERMISSION_DENIED", "Phone number permission not granted", null);
        }
    }

    private void registerCallReceiver() {
        callReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String state = intent.getStringExtra(TelephonyManager.EXTRA_STATE);
                if (TelephonyManager.EXTRA_STATE_RINGING.equals(state)) {
                    String incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER);
                    System.out.println("📞 Incoming call from: " + incomingNumber);
                    if (incomingNumber != null && eventSink != null) {
                        eventSink.success("INCOMING_CALL:" + incomingNumber);
                    }
                } else if (TelephonyManager.EXTRA_STATE_IDLE.equals(state) ||
                        TelephonyManager.EXTRA_STATE_OFFHOOK.equals(state)) {
                    if (eventSink != null) {
                        eventSink.success("INCOMING_CALL:none");
                    }
                }
            }
        };
        IntentFilter filter = new IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED);
        registerReceiver(callReceiver, filter); // ✅ Fixed: lowercase 'registerReceiver'
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (callReceiver != null) {
            unregisterReceiver(callReceiver);
            callReceiver = null;
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == PERMISSION_REQUEST_CODE) {
            boolean allGranted = true;
            for (int result : grantResults) {
                if (result != PackageManager.PERMISSION_GRANTED) {
                    allGranted = false;
                    break;
                }
            }
            if (!allGranted) {
                System.out.println("⚠️ Some permissions were denied");
            }
        }
    }
}
