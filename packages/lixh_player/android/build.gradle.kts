import java.io.File

group = "com.livecatch.lixh_player"
version = "1.0-SNAPSHOT"

buildscript {
    repositories {
        maven(url = "https://mirrors.cloud.tencent.com/google/")
        maven(url = "https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        google()
        mavenCentral()
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
val lixhFfmpegLib = File(lixhRepoRoot, "src-tauri/lixh-stream-stack/sdk/android-arm64/lib")
val lixhRuntimeLib = File(lixhRepoRoot, "src-tauri/lixh-stream-stack/runtime/android-arm64")
val lixhJniOut = File(project.projectDir, "src/main/jniLibs/arm64-v8a")

// Only ship libs we link (CMake). avfilter is in the SDK but unused → drop ~135KB.
val lixhFfmpegSoNames = listOf(
    "libavcodec.so",
    "libavformat.so",
    "libavutil.so",
    "libswresample.so",
    "libswscale.so",
)

val syncFfmpegJni by tasks.registering(Copy::class) {
    onlyIf {
        lixhFfmpegLib.exists() || File(lixhFfmpegLib, "arm64-v8a").exists() ||
            lixhRuntimeLib.exists()
    }
    // LiveCatchFfmpeg android runtime ships under arm64-v8a/; sdk under lib/.
    from(lixhFfmpegLib) { include(*lixhFfmpegSoNames.toTypedArray()) }
    from(File(lixhFfmpegLib, "arm64-v8a")) { include(*lixhFfmpegSoNames.toTypedArray()) }
    from(File(lixhRuntimeLib, "arm64-v8a")) { include(*lixhFfmpegSoNames.toTypedArray()) }
    from(lixhRuntimeLib) { include(*lixhFfmpegSoNames.toTypedArray()) }
    from(File(lixhRuntimeLib, "lib")) { include(*lixhFfmpegSoNames.toTypedArray()) }
    from(File(lixhRuntimeLib, "lib/arm64-v8a")) { include(*lixhFfmpegSoNames.toTypedArray()) }
    into(lixhJniOut)
    duplicatesStrategy = DuplicatesStrategy.INCLUDE
    doLast {
        // Remove stale copies from older syncs (e.g. libavfilter.so).
        lixhJniOut.listFiles()?.forEach { f ->
            if (f.isFile && f.name.endsWith(".so") && f.name !in lixhFfmpegSoNames) {
                f.delete()
                logger.lifecycle("Removed unused jniLib ${f.name}")
            }
        }
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
            abiFilters += listOf("arm64-v8a")
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
