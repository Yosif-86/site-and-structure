package com.siteandstructure.site_and_structure

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native replacement for the broken screen_protector plugin's Android half.
 * Exposes a single method channel the Dart side (lib/services/screen_security.dart)
 * calls to toggle FLAG_SECURE, which blocks screenshots and screen recording
 * system-wide for as long as it's set — real, OS-level blocking (unlike iOS,
 * which can only detect a capture after the fact).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "site_and_structure/screen_security"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    val secure = call.argument<Boolean>("secure") ?: false
                    if (secure) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
