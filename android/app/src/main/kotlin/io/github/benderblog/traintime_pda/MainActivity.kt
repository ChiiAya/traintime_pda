package io.github.benderblog.traintime_pda

import android.content.Intent
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.benderblog.traintime_pda.liveupdate.LiveUpdateBridge
import io.github.benderblog.traintime_pda.liveupdate.LiveUpdatePublisher


class MainActivity : FlutterActivity() {
    private var liveUpdateBridge: LiveUpdateBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Enable edge-to-edge display
        WindowCompat.enableEdgeToEdge(window)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val bridge = LiveUpdateBridge(applicationContext)
        bridge.attach(flutterEngine.dartExecutor.binaryMessenger)
        liveUpdateBridge = bridge

        // Cold start caused by tapping a course Live Update. Dart has not registered its handler yet
        // at this point, so markOpened() only records the event; Dart collects it with
        // consumePendingOpen once it is ready.
        if (isLiveUpdateOpenIntent(intent)) bridge.markOpened()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (isLiveUpdateOpenIntent(intent)) liveUpdateBridge?.markOpened()
    }

    private fun isLiveUpdateOpenIntent(intent: Intent?): Boolean =
        intent?.action == LiveUpdatePublisher.ACTION_OPEN_LIVE_UPDATE
}
