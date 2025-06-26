package ddi.crm.crm_new;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.telephony.TelephonyManager;
import android.util.Log;

public class CallReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String state = intent.getStringExtra(TelephonyManager.EXTRA_STATE);
        if (TelephonyManager.EXTRA_STATE_RINGING.equals(state)) {
            Log.d("CallReceiver", "Incoming call ringing");
        } else if (TelephonyManager.EXTRA_STATE_OFFHOOK.equals(state)) {
            Log.d("CallReceiver", "Call started");
        } else if (TelephonyManager.EXTRA_STATE_IDLE.equals(state)) {
            Log.d("CallReceiver", "Call ended");
        }
    }
}