plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Third-party notices for the Maven libraries; see aboutLibraries below.
    id("com.mikepenz.aboutlibraries.plugin.android")
}

android {
    namespace = "ch.lkmc.planchette"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ch.lkmc.planchette"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Public sideload key, matching the suite's trust model. A stable
        // signature permits upgrades without uninstalling and losing settings.
        create("release") {
            storeFile = file("ci-release.jks")
            storePassword = "planchette-release"
            keyAlias = "planchette"
            keyPassword = "planchette-release"
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

dependencies {
    testImplementation("junit:junit:4.13.2")
}
