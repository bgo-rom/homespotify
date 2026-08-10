package com.homespotify.homespotify_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
                    "packageName" to packageName,
                ),
            )
        }
        registerAppUpdateChannel(flutterEngine)
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

    /**
     * Canal de mise à jour automatique privée.
     *
     * Trois opérations, aucune contournant Android :
     * - `canRequestInstall` : lit `canRequestPackageInstalls()` ;
     * - `openInstallSettings` : ouvre l'écran système « Installer des
     *   applications inconnues » positionné sur HomeSpotify ;
     * - `installApk` : remet l'APK à l'installateur du système, qui affiche sa
     *   propre confirmation. HomeSpotify n'installe jamais rien lui-même.
     */
    private fun registerAppUpdateChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.homespotify/app_update",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestInstall" -> result.success(canRequestPackageInstalls())

                "inspectApk" -> {
                    val path = call.argument<String>("path")
                    val file = path?.let(::File)
                    if (file == null || !isInsideUpdateCache(file) || !file.isFile) {
                        result.error("invalid_path", "Chemin de mise à jour refusé.", null)
                        return@setMethodCallHandler
                    }
                    val inspected = inspectApkArchive(file.absolutePath)
                    if (inspected == null) {
                        result.error("apk_unreadable", "APK illisible.", null)
                    } else {
                        result.success(inspected)
                    }
                }

                "openInstallSettings" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        // Avant Android 8, l'autorisation est globale et n'a pas
                        // d'écran par application : rien à ouvrir.
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    runCatching {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                    }.onSuccess { result.success(true) }
                        .onFailure { result.success(false) }
                }

                "installApk" -> {
                    val path = call.argument<String>("path")
                    val file = path?.let(::File)
                    if (file == null || !isInsideUpdateCache(file)) {
                        // Un chemin hors du cache de mises à jour n'est jamais
                        // remis à l'installateur, quelle qu'en soit l'origine.
                        result.error(
                            "invalid_path",
                            "Chemin de mise à jour refusé.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    if (!file.isFile) {
                        result.error("file_missing", "Fichier de mise à jour absent.", null)
                        return@setMethodCallHandler
                    }
                    if (!canRequestPackageInstalls()) {
                        result.error(
                            "permission_required",
                            "HomeSpotify n'est pas autorisé à installer des applications.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    runCatching {
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.updateprovider",
                            file,
                        )
                        startActivity(
                            Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, APK_MIME_TYPE)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            },
                        )
                    }.onSuccess { result.success(true) }
                        .onFailure {
                            result.error(
                                "installer_unavailable",
                                "L'installateur Android n'a pas pu être ouvert.",
                                null,
                            )
                        }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Lit l'identité d'une APK SANS l'installer : nom de paquet, versionCode et
     * empreinte SHA-256 du certificat de signature. C'est ce qui permet au
     * client de refuser un fichier qui n'est pas la mise à jour attendue avant
     * même d'ouvrir l'installateur.
     */
    private fun inspectApkArchive(absolutePath: String): Map<String, Any>? {
        @Suppress("DEPRECATION")
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val info = runCatching {
            packageManager.getPackageArchiveInfo(absolutePath, flags)
        }.getOrNull() ?: return null

        @Suppress("DEPRECATION")
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }

        @Suppress("DEPRECATION")
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        val digests = (signatures ?: emptyArray()).map { signature ->
            java.security.MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }

        return mapOf(
            "packageName" to (info.packageName ?: ""),
            "versionCode" to versionCode.toString(),
            "versionName" to (info.versionName ?: ""),
            "signingCertSha256" to digests,
        )
    }

    private fun canRequestPackageInstalls(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    /** Seul `cacheDir/app-updates` est installable — cf. homespotify_update_paths.xml. */
    private fun isInsideUpdateCache(file: File): Boolean {
        if (!file.name.endsWith(".apk", ignoreCase = true)) return false
        val root = File(cacheDir, UPDATE_CACHE_DIR).canonicalFile
        val candidate = runCatching { file.canonicalFile }.getOrNull() ?: return false
        return candidate.parentFile == root
    }

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
        const val UPDATE_CACHE_DIR = "app-updates"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
