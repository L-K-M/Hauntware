import java.security.KeyStore
import java.security.MessageDigest
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Third-party notices for the Maven libraries; see aboutLibraries below.
    id("com.mikepenz.aboutlibraries.plugin.android")
}

val ciSigningPropertiesPath = "key.properties"
val ciSigningConfigName = "ciRelease"
val ciKeyStoreType = "JKS"
val ciCertificateDigest = "SHA-256"
val expectedCiCertificateSha256 =
    "09B0C09B3715B035C7EE07E1D2D79EFAFC1D99222EA06A9E8F6CBA48A55BB8B5"

val ciSigningPropertiesFile = rootProject.file(ciSigningPropertiesPath)
check(ciSigningPropertiesFile.isFile) {
    "Missing committed public CI signing properties: $ciSigningPropertiesPath"
}

val ciSigningProperties =
    Properties().apply {
        ciSigningPropertiesFile.inputStream().use(::load)
    }

fun ciSigningProperty(name: String): String =
    ciSigningProperties.getProperty(name)?.trim()?.takeIf(String::isNotEmpty)
        ?: error("Missing Android CI signing property: $name")

val ciKeyStoreFile = file(ciSigningProperty("storeFile"))
check(ciKeyStoreFile.isFile) {
    "Missing committed public CI keystore: ${ciKeyStoreFile.path}"
}

// Pin the public certificate so an accidental key rotation fails every build.
val actualCiCertificateSha256 =
    KeyStore.getInstance(ciKeyStoreType).run {
        ciKeyStoreFile.inputStream().use {
            load(it, ciSigningProperty("storePassword").toCharArray())
        }
        val certificate =
            getCertificate(ciSigningProperty("keyAlias"))
                ?: error("Android CI signing alias is absent from the keystore")
        MessageDigest.getInstance(ciCertificateDigest)
            .digest(certificate.encoded)
            .joinToString("") { byte -> "%02X".format(byte.toInt() and 0xff) }
    }
check(actualCiCertificateSha256 == expectedCiCertificateSha256) {
    "Android CI signing certificate changed: $actualCiCertificateSha256"
}

android {
    namespace = "ch.lkmc.klabautermann"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications (ALR-01) needs library desugaring
        // on every Android version it supports.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Frozen after the first shipped release (04 §12.3): changing
        // applicationId makes new builds install as a separate app instead
        // of upgrading in place.
        applicationId = "ch.lkmc.klabautermann"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // This key is public by design: it provides upgrade continuity only.
        create(ciSigningConfigName) {
            storeFile = ciKeyStoreFile
            storePassword = ciSigningProperty("storePassword")
            keyAlias = ciSigningProperty("keyAlias")
            keyPassword = ciSigningProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(ciSigningConfigName)
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Third-party notices for the Maven libraries the APK compiles in (AndroidX,
// Kotlin, Tink and the rest): res/raw/aboutlibraries.json, from the resolved
// release graph plus config/, offline and reproducible. ghost_licenses shows
// them on the licenses page; Flutter's NOTICES covers the engine and the pub
// packages. The build fails on a library without a license or with one
// outside the allow-list; give a new license its text in config/licenses/.
aboutLibraries {
    offlineMode.set(true)
    collect {
        configPath.set(layout.projectDirectory.dir("config"))
        fetchRemoteLicense.set(false)
        fetchRemoteFunding.set(false)
    }
    library {
        requireLicense.set(true)
        // The Flutter engine's own artifacts carry no POM license; Flutter's
        // NOTICES holds the engine's notices.
        exclusionPatterns.add(java.util.regex.Pattern.compile("io\\.flutter:.*"))
    }
    license {
        strictMode.set(com.mikepenz.aboutlibraries.plugin.StrictMode.FAIL)
        // BSD-3-Clause: the Protocol Buffers runtime tink-android shades,
        // a bundled entry in config/libraries/.
        allowedLicenses.addAll("Apache-2.0", "BSD-3-Clause", "GPL-2.0-only WITH Classpath-exception-2.0")
    }
}

flutter {
    source = "../.."
}

dependencies {
    // No runtime classpath lists it, so its notice is the bundled entry
    // config/libraries/com.android.tools__desugar_jdk_libs.json: keep
    // that version in step.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
