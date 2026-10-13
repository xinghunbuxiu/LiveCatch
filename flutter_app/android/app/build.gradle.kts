import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Room resolve runs on the server — strip any leftover local resolver jniLibs.
val lixhResolveJniDir = File(project.projectDir, "src/main/jniLibs/arm64-v8a")
val stripLocalResolveJni by tasks.registering {
    description = "Remove local lixh resolve .so (remote HTTP resolve)"
    doLast {
        listOf("liblixh_resolve.so", "liblixh_stream_resolver.so").forEach { name ->
            val f = File(lixhResolveJniDir, name)
            if (f.isFile) {
                f.delete()
                logger.lifecycle("Removed local resolve native ${f.absolutePath}")
            }
        }
    }
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(stripLocalResolveJni)
}

android {
    namespace = "com.example.livecatch_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.livecatch_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 7.0+ (API 24). Audio: OpenSL <26, AAudio ≥26 (USAGE ≥28).
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            // Extract .so for System.loadLibrary (FFmpeg player natives).
            useLegacyPackaging = true
            // Keep APK arm64-only even if Flutter/AndroidX merge other ABIs
            // (bare `flutter build apk` without --target-platform used to inflate ~19→33MB).
            excludes += setOf(
                "**/armeabi/**",
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
