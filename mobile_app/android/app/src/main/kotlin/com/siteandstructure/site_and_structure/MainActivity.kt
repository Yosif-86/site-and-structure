package com.siteandstructure.site_and_structure

import android.app.Activity
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native replacement for the broken screen_protector plugin's Android half.
 *
 * FLAG_SECURE is set once here, permanently, for the whole app rather than
 * toggled per-screen via the method channel (which the Dart side --
 * lib/services/screen_security.dart -- used to call around just the video
 * screen). That per-screen toggle had a real bug: Android captures the
 * recents/task-switcher thumbnail essentially at the `paused` lifecycle
 * transition, before Flutter's own app-backgrounded cover (PrivacyOverlay)
 * can even render a frame -- so the thumbnail showed real course content
 * instead of the branded cover. Setting FLAG_SECURE app-wide and always-on
 * makes Android blank that thumbnail itself, unconditionally, with no
 * Flutter-timing race possible. Trade-off: screenshots are now blocked
 * everywhere in the app, not just on the video screen -- acceptable here
 * since protecting the paid course content is the point.
 *
 * The method channel is kept (Dart's enableSecure/disableSecure calls
 * become harmless no-ops on Android) so the iOS side -- which has no
 * FLAG_SECURE equivalent and instead detects a capture after the fact --
 * doesn't need its own call sites touched.
 *
 * FLAG_SECURE only blocks the video half of a screen recording -- Android's
 * AudioPlaybackCapture API (what most screen recorders use since Android 10
 * to grab an app's audio output) is a separate mechanism the flag doesn't
 * touch, so a lecture's audio was still coming through on an otherwise-blank
 * recording. That's opted out app-wide via
 * android:allowAudioPlaybackCapture="false" in AndroidManifest.xml.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "site_and_structure/screen_security"
    private var channel: MethodChannel? = null

    // Screenshot attempts (Android 14+) and screen recording starting
    // (Android 15+) are reported to Dart, which logs them for the admin.
    // FLAG_SECURE still blanks the capture itself; this only says it happened.
    private val screenshotCallback: Any? =
        if (Build.VERSION.SDK_INT >= 34) Activity.ScreenCaptureCallback {
            android.util.Log.i("ArcSecurity", "screenshot detected")
            channel?.invokeMethod("onCapture", mapOf("type" to "screenshot"))
        } else null

    private val recordingCallback: Any? =
        if (Build.VERSION.SDK_INT >= 35) java.util.function.Consumer<Int> { state ->
            android.util.Log.i("ArcSecurity", "recording state $state")
            if (state == WindowManager.SCREEN_RECORDING_STATE_VISIBLE) {
                channel?.invokeMethod("onCapture", mapOf("type" to "recording"))
            }
        } else null

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= 34) {
            registerScreenCaptureCallback(mainExecutor,
                screenshotCallback as Activity.ScreenCaptureCallback)
        }
        if (Build.VERSION.SDK_INT >= 35) {
            @Suppress("UNCHECKED_CAST")
            val state = windowManager.addScreenRecordingCallback(mainExecutor,
                recordingCallback as java.util.function.Consumer<Int>)
            if (state == WindowManager.SCREEN_RECORDING_STATE_VISIBLE) {
                channel?.invokeMethod("onCapture", mapOf("type" to "recording"))
            }
        }
    }

    override fun onStop() {
        if (Build.VERSION.SDK_INT >= 34) {
            unregisterScreenCaptureCallback(
                screenshotCallback as Activity.ScreenCaptureCallback)
        }
        if (Build.VERSION.SDK_INT >= 35) {
            @Suppress("UNCHECKED_CAST")
            windowManager.removeScreenRecordingCallback(
                recordingCallback as java.util.function.Consumer<Int>)
        }
        super.onStop()
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Skipped only for debuggable builds (`flutter run` / `flutter build
        // apk --debug`), which are never distributed -- so the app's own UI
        // can be screenshotted and visually verified during development.
        // Release and profile builds are never debuggable, so every build a
        // student can actually install keeps FLAG_SECURE on.
        val debuggable =
            (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> result.success(null) // no-op on Android now -- see class doc
                else -> result.notImplemented()
            }
        }
    }
}
