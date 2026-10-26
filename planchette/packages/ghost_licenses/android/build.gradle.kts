// Java rather than Kotlin, as ghost_apk_update: the apps set
// android.builtInKotlin=false, so a Kotlin plugin would have to apply the
// Kotlin Gradle plugin itself.
plugins {
    id("com.android.library")
}

android {
    namespace = "ch.lkmc.ghost.licenses"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = flutter.minSdkVersion
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
