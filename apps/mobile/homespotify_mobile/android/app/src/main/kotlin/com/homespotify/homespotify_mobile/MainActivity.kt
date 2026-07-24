package com.homespotify.homespotify_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity requise par local_auth, avec le FlutterEngine partagé
// d'audio_service pour préserver lecture en arrière-plan et notification.
class MainActivity : AudioServiceFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE,
            )
        }
    }

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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.homespotify/app_info",
        ).setMethodCallHandler { call, result ->
            if (call.method != "get") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            @Suppress("DEPRECATION")
            val packageInfo = packageManager.getPackageInfo(packageName, 0)
            @Suppress("DEPRECATION")
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.longVersionCode
            } else {
                packageInfo.versionCode.toLong()
            }
            result.success(
                mapOf(
                    "version" to (packageInfo.versionName ?: ""),
                    "buildNumber" to versionCode.toString(),
                ),
            )
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.homespotify/storage",
        ).setMethodCallHandler { call, result ->
            if (call.method != "freeBytes") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            runCatching {
                StatFs(filesDir.absolutePath).availableBytes
            }.onSuccess {
                result.success(it)
            }.onFailure {
                result.error("storage_unavailable", "Espace disque illisible.", null)
            }
        }
    }

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
    }
}
