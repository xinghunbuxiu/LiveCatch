import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun findRepoRoot(start: File): File {
    var dir: File? = start
    while (dir != null) {
        if (File(dir, "src-tauri/lixh-stream-stack").isDirectory) return dir
        dir = dir.parentFile
    }
    return start
}

val lixhRepoRoot = findRepoRoot(rootProject.projectDir)
val lixhResolveLib = File(
    lixhRepoRoot,
    "src-tauri/lixh-stream-stack/target/aarch64-linux-android/release/liblixh_stream_resolver.so",
)
val lixhResolveJniDir = File(project.projectDir, "src/main/jniLibs/arm64-v8a")
val lixhResolveJniSo = File(lixhResolveJniDir, "liblixh_resolve.so")
val lixhResolveJniFfi = File(lixhResolveJniDir, "liblixh_stream_resolver.so")

val syncLixhResolveJni by tasks.registering {
    description = "Stage aarch64 resolve cdylib into jniLibs (JNI only; no Process helper)"
    doLast {
        lixhResolveJniDir.mkdirs()
        var staged = false
        if (lixhResolveLib.isFile) {
            lixhResolveLib.copyTo(lixhResolveJniFfi, overwrite = true)
            logger.lifecycle("Bundled ${lixhResolveJniFfi.absolutePath}")
            staged = true
        } else if (lixhResolveJniFfi.isFile) {
            logger.lifecycle("Using existing ${lixhResolveJniFfi.absolutePath}")
            staged = true
        }
        // Drop legacy Process helper (~9MB) — Dart uses JNI resolveRoom.
        if (lixhResolveJniSo.isFile) {
            lixhResolveJniSo.delete()
            logger.lifecycle("Removed Process helper ${lixhResolveJniSo.absolutePath}")
        }
        if (!staged) {
            throw GradleException(
                "Missing Android liblixh_stream_resolver.so. Build/stage it first:\n" +
                    "  bash flutter_app/android/bundle_lixh_resolve.sh\n" +
                    "  or: pwsh flutter_app/android/bundle_lixh_resolve.ps1",
            )
        }
    }
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(syncLixhResolveJni)
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
        minSdk = maxOf(flutter.minSdkVersion, 26)
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
        }
    }

    packaging {
        jniLibs {
            // Extract .so for System.loadLibrary (FFmpeg + resolve cdylib).
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
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
