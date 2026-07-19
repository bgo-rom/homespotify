package com.homespotify.homespotify_mobile

import android.content.Intent
import android.net.Uri
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity requise par local_auth, avec le FlutterEngine partagé
// d'audio_service pour préserver lecture en arrière-plan et notification.
class MainActivity : AudioServiceFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.homespotify/external_url",
        ).setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val url = call.argument<String>("url")
            val uri = url?.let(Uri::parse)
            if (uri == null || (uri.scheme != "http" && uri.scheme != "https")) {
                result.success(false)
                return@setMethodCallHandler
            }
            runCatching {
                startActivity(Intent(Intent.ACTION_VIEW, uri))
            }.onSuccess {
                result.success(true)
            }.onFailure {
                result.success(false)
            }
        }
    }
}
