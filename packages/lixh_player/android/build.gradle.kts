import java.io.File

group = "com.livecatch.lixh_player"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        maven(url = "https://mirrors.cloud.tencent.com/google/")
        maven(url = "https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
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

val syncFfmpegJni by tasks.registering(Copy::class) {
    onlyIf {
        lixhFfmpegLib.exists() || File(lixhFfmpegLib, "arm64-v8a").exists() ||
            lixhRuntimeLib.exists()
    }
    // LiveCatchFfmpeg android runtime ships under arm64-v8a/; sdk under lib/.
    from(lixhFfmpegLib) { include("*.so") }
    from(File(lixhFfmpegLib, "arm64-v8a")) { include("*.so") }
    from(File(lixhRuntimeLib, "arm64-v8a")) { include("*.so") }
    from(lixhRuntimeLib) { include("*.so") }
    from(File(lixhRuntimeLib, "lib")) { include("*.so") }
    from(File(lixhRuntimeLib, "lib/arm64-v8a")) { include("*.so") }
    into(lixhJniOut)
    duplicatesStrategy = DuplicatesStrategy.INCLUDE
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
        minSdk = 26
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
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
            // Keep prebuilt FFmpeg SONAMEs; do not strip for runtime dlopen.
            keepDebugSymbols += "**/*.so"
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
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
