plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties

val homeSpotifyStretchEngine = providers
    .environmentVariable("HOMESPOTIFY_STRETCH_ENGINE")
    .orElse(providers.gradleProperty("HOMESPOTIFY_STRETCH_ENGINE"))
    .getOrElse("signalsmith")
    .lowercase()
require(homeSpotifyStretchEngine in setOf("signalsmith", "media3")) {
    "HOMESPOTIFY_STRETCH_ENGINE must be 'signalsmith' or 'media3'."
}

// --- Signature release HomeSpotify -----------------------------------------
// L'IDENTITÉ DE SIGNATURE EST UN INVARIANT DU PROJET : Android refuse
// d'installer une mise à jour par-dessus une application signée avec un autre
// certificat. Le keystore vit hors de tout arbre Git ; seul son CHEMIN est
// résolu ici, jamais son contenu.
//
// Ordre de résolution :
//   1. HOMESPOTIFY_ANDROID_KEY_PROPERTIES (variable d'environnement ou
//      propriété Gradle) — utilisé par scripts/publish_android_update.ps1 ;
//   2. android/key.properties du module (ignoré par Git).
//
// Aucun des deux : la build release retombe sur la clé debug, exactement comme
// avant. C'est volontaire — `flutter run --release` doit rester possible sur
// une machine sans secret. La garantie d'identité n'est PAS ici : le script de
// publication compare l'empreinte du certificat de l'APK produite à la valeur
// attendue et refuse de publier en cas d'écart (fail-closed).
val homeSpotifyKeyPropertiesPath: String? = providers
    .environmentVariable("HOMESPOTIFY_ANDROID_KEY_PROPERTIES")
    .orElse(providers.gradleProperty("HOMESPOTIFY_ANDROID_KEY_PROPERTIES"))
    .orNull

val homeSpotifyKeystoreProperties: Properties? = run {
    val candidate = homeSpotifyKeyPropertiesPath
        ?.let { file(it) }
        ?: rootProject.file("key.properties")
    if (!candidate.isFile) {
        if (homeSpotifyKeyPropertiesPath != null) {
            throw GradleException(
                "HOMESPOTIFY_ANDROID_KEY_PROPERTIES pointe vers un fichier absent : $candidate",
            )
        }
        null
    } else {
        Properties().apply { candidate.inputStream().use(::load) }
    }
}

android {
    namespace = "com.homespotify.homespotify_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.homespotify.homespotify_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["homespotifyStretchEngine"] = homeSpotifyStretchEngine
    }

    signingConfigs {
        if (homeSpotifyKeystoreProperties != null) {
            create("homespotifyRelease") {
                val properties = homeSpotifyKeystoreProperties
                storeFile = file(
                    properties.getProperty("storeFile")
                        ?: throw GradleException("key.properties : storeFile manquant"),
                )
                storePassword = properties.getProperty("storePassword")
                    ?: throw GradleException("key.properties : storePassword manquant")
                keyAlias = properties.getProperty("keyAlias")
                    ?: throw GradleException("key.properties : keyAlias manquant")
                keyPassword = properties.getProperty("keyPassword")
                    ?: throw GradleException("key.properties : keyPassword manquant")
                // Les schémas de signature ne sont PAS forcés ici : on laisse
                // AGP appliquer exactement les mêmes défauts (minSdk 24 → v2)
                // que ceux qui ont produit l'APK déjà installée. Ce chantier
                // ajoute l'auto-update, il ne change pas la façon de signer.
            }
        }
    }

    buildTypes {
        release {
            // Clé release HomeSpotify si le secret local est présent, sinon la
            // clé debug — cf. le bloc de résolution en tête de fichier.
            signingConfig = signingConfigs.findByName("homespotifyRelease")
                ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.media:media:1.6.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
}
