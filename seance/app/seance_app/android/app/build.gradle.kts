plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Third-party notices for the Maven libraries; see aboutLibraries below.
    id("com.mikepenz.aboutlibraries.plugin.android")
}

android {
    namespace = "ch.lkmc.seance"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ch.lkmc.seance"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Séance is a personal, sideloaded app (no Play Store), and its
        // release keystore is committed — password public by design. What
        // that buys: a STABLE identity, so every build (local or CI) can
        // upgrade an existing install in place; the default debug keystore is
        // per-machine/per-CI-run, which forced an uninstall (wiping local
        // data) on every update. What it deliberately gives up: publisher
        // authenticity — anyone can build an APK this key signs, and Android
        // would install it OVER an existing install if the user sideloads it.
        // The trust anchor is therefore the download source (this repo's
        // releases), not the signature. Use a private key instead if that
        // ever stops being acceptable.
        create("release") {
            storeFile = file("ci-release.jks")
            storePassword = "seance-release"
            keyAlias = "seance"
            keyPassword = "seance-release"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
        exclusionPatterns.add(Regex("io\\.flutter:.*").toPattern())
    }
    license {
        strictMode.set(com.mikepenz.aboutlibraries.plugin.StrictMode.FAIL)
        // BSD-3-Clause: the Protocol Buffers runtime tink-android shades,
        // a bundled entry in config/libraries/.
        allowedLicenses.addAll("Apache-2.0", "BSD-3-Clause")
    }
}

flutter {
    source = "../.."
}
