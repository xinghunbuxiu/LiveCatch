import java.io.File

group = "com.livecatch.lixh_player"
version = "1.0-SNAPSHOT"

buildscript {
    repositories {
        maven(url = "https://mirrors.cloud.tencent.com/google/")
        maven(url = "https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
    }
    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
    }
}

allprojects {
    repositories {
        maven(url = "https://mirrors.cloud.tencent.com/google/")
        maven(url = "https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

fun findRepoRoot(): File {
    var dir: File? = project.projectDir
    repeat(12) {
        val cur = dir ?: return project.projectDir
        val marker = File(cur, "src-tauri/lixh-stream-stack/lixh-player-core/include/lixh_player.h")
        if (marker.exists()) return cur
        dir = cur.parentFile
    }
    return project.projectDir
}

val lixhRepoRoot = findRepoRoot()

// Only ship libs we link (CMake). avfilter is in the SDK but unused → drop ~135KB.
val lixhFfmpegSoNames = listOf(
    "libavcodec.so",
    "libavformat.so",
    "libavutil.so",
    "libswresample.so",
    "libswscale.so",
)

data class LixhAbi(
    val jniAbi: String,
    val platform: String,
)

val lixhAbisAll = listOf(
    LixhAbi("arm64-v8a", "android-arm64"),
    LixhAbi("armeabi-v7a", "android-armv7"),
)

/** Only ABIs with a fetched FFmpeg SDK (headers under sdk/<platform>/include). */
val lixhAbis = lixhAbisAll.filter { abi ->
    File(lixhRepoRoot, "src-tauri/lixh-stream-stack/sdk/${abi.platform}/include/libavcodec/avcodec.h")
        .isFile
}

fun syncAbiFfmpeg(abi: LixhAbi) {
    val ffmpegLib = File(lixhRepoRoot, "src-tauri/lixh-stream-stack/sdk/${abi.platform}/lib")
    val runtimeLib = File(lixhRepoRoot, "src-tauri/lixh-stream-stack/runtime/${abi.platform}")
    val jniOut = File(project.projectDir, "src/main/jniLibs/${abi.jniAbi}")
    if (!ffmpegLib.exists() && !File(ffmpegLib, abi.jniAbi).exists() && !runtimeLib.exists()) {
        logger.lifecycle("Skip FFmpeg jni sync for ${abi.jniAbi}: sdk/runtime ${abi.platform} missing")
        return
    }
    jniOut.mkdirs()
    val sources = listOf(
        ffmpegLib,
        File(ffmpegLib, abi.jniAbi),
        File(runtimeLib, abi.jniAbi),
        runtimeLib,
        File(runtimeLib, "lib"),
        File(runtimeLib, "lib/${abi.jniAbi}"),
    )
    for (name in lixhFfmpegSoNames) {
        val src = sources.firstOrNull { File(it, name).isFile }?.let { File(it, name) }
        if (src != null) {
            src.copyTo(File(jniOut, name), overwrite = true)
        }
    }
    jniOut.listFiles()?.forEach { f ->
        if (f.isFile && f.name.endsWith(".so") && f.name !in lixhFfmpegSoNames) {
            f.delete()
            logger.lifecycle("Removed unused jniLib ${abi.jniAbi}/${f.name}")
        }
    }
}

val syncFfmpegJni by tasks.registering {
    description = "Stage FFmpeg .so into jniLibs for arm64-v8a and armeabi-v7a"
    doLast {
        lixhAbis.forEach { syncAbiFfmpeg(it) }
    }
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(syncFfmpegJni)
}

android {
    namespace = "com.livecatch.lixh_player"

    compileSdk = 36
    // Match Flutter stable / CI NDK so externalNativeBuild does not pick a missing toolset.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.setSrcDirs(listOf("src/main/kotlin"))
        }
        getByName("test") {
            java.setSrcDirs(listOf("src/test/kotlin"))
        }
    }

    defaultConfig {
        minSdk = 24
        ndk {
            if (lixhAbis.isEmpty()) {
                throw GradleException(
                    "No FFmpeg Android SDK found under src-tauri/lixh-stream-stack/sdk/. " +
                        "Fetch android-arm64 (and optionally android-armv7).",
                )
            }
            abiFilters += lixhAbis.map { it.jniAbi }
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    // Static STL avoids shipping a separate libc++_shared.so (~400KB APK).
                    "-DANDROID_STL=c++_static",
                    "-DANDROID_ARM_NEON=TRUE",
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    packaging {
        jniLibs {
            // Allow AGP to strip unneeded local symbols from our JNI .so.
            // Prebuilt FFmpeg libs are already stripped upstream.
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
