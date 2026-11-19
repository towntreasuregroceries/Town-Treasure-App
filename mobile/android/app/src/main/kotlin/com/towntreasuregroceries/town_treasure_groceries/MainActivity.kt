package com.towntreasuregroceries.town_treasure_groceries

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var paddleOcrPlugin: PaddleOcrPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val plugin = PaddleOcrPlugin(applicationContext)
        paddleOcrPlugin = plugin
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PaddleOcrPlugin.CHANNEL
        ).setMethodCallHandler(plugin)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        paddleOcrPlugin?.closeSessions()
        paddleOcrPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
