// Java rather than Kotlin: the apps set android.builtInKotlin=false, so a
// Kotlin plugin would have to apply the Kotlin Gradle plugin itself and
// break again whenever that flag flips (see the apps' file_picker
// workaround in android/build.gradle.kts).
plugins {
    id("com.android.library")
}

android {
    namespace = "ch.lkmc.ghost.apkupdate"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = flutter.minSdkVersion
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // FileProvider; the version url_launcher_android already resolves.
    implementation("androidx.core:core:1.17.0")
}
