package ddi.crm.crm_new;

import android.app.*;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.media.*;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.ParcelFileDescriptor;
import android.net.Uri;
import android.os.IBinder;
import android.provider.MediaStore;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

public class AudioCaptureService extends Service {
    private boolean isCapturing = false;
    private MediaProjection mediaProjection;
    private AudioRecord playbackRecorder;
    private AudioRecord micRecorder;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Intent projectionData = intent.getParcelableExtra("mediaProjectionData");
        MediaProjectionManager mgr = (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        mediaProjection = mgr.getMediaProjection(Activity.RESULT_OK, projectionData);

        startForeground(1, buildNotification());
        startAudioCapture();
        return START_STICKY;
    }

    private OutputStream getAppDataOutputStream() {
        try {
            String fileName = "call_recording_" + System.currentTimeMillis() + ".pcm";
            File file = new File(getExternalFilesDir(null), fileName);

            // ✅ Print the full file path
            System.out.println("Recording file saved at: " + file.getAbsolutePath());
            Log.d("CallRecorder", "Recording file saved at: " + file.getAbsolutePath());

            return new FileOutputStream(file);
        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }


    private void startAudioCapture() {
        AudioPlaybackCaptureConfiguration config =
                new AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                        .addMatchingUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                        .build();

        AudioFormat format = new AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(44100)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build();

        int bufferSize = AudioRecord.getMinBufferSize(44100,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);

        playbackRecorder = new AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize)
                .build();

        micRecorder = new AudioRecord(MediaRecorder.AudioSource.MIC,
                44100,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize);

        playbackRecorder.startRecording();
        micRecorder.startRecording();
        isCapturing = true;

        new Thread(() -> {
            try (OutputStream out = getAppDataOutputStream()) {
                byte[] buffer = new byte[2048];
                while (isCapturing) {
                    int micBytes = micRecorder.read(buffer, 0, buffer.length);
                    int pbBytes = playbackRecorder.read(buffer, 0, buffer.length);
                    int size = Math.max(micBytes, pbBytes);
                    out.write(buffer, 0, size);
                }
            } catch (Exception e) {
                e.printStackTrace();
            }
        }).start();
    }

    private OutputStream getDownloadOutputStream() {
        ContentResolver resolver = getContentResolver();
        ContentValues values = new ContentValues();
        String fileName = "call_recording_" + System.currentTimeMillis() + ".pcm";

        values.put(MediaStore.Downloads.DISPLAY_NAME, fileName);
        values.put(MediaStore.Downloads.MIME_TYPE, "audio/pcm");
        values.put(MediaStore.Downloads.IS_PENDING, 1);

        Uri collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY);
        Uri itemUri = resolver.insert(collection, values);

        try {
            ParcelFileDescriptor pfd = resolver.openFileDescriptor(itemUri, "w");
            FileOutputStream out = new FileOutputStream(pfd.getFileDescriptor());
            values.clear();
            values.put(MediaStore.Downloads.IS_PENDING, 0);
            resolver.update(itemUri, values, null, null);
            return out;
        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }

    private Notification buildNotification() {
        NotificationChannel chan = new NotificationChannel("recording", "Call Recording",
                NotificationManager.IMPORTANCE_LOW);
        NotificationManager mgr = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        mgr.createNotificationChannel(chan);

        return new NotificationCompat.Builder(this, "recording")
                .setContentTitle("Recording Call")
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .build();
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        isCapturing = false;
        playbackRecorder.stop();
        micRecorder.stop();
        mediaProjection.stop();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
