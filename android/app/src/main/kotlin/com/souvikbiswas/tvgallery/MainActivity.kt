package com.souvikbiswas.tvgallery

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "tv_gallery/video",
            VideoPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        MediaIndexChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
}
