group = "com.livecatch.lixh_player"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
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
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

fun findRepoRoot(): java.io.File {
    var dir: java.io.File? = project.projectDir
    repeat(12) {
        val cur = dir ?: return project.projectDir
        val marker = java.io.File(cur, "src-tauri/lixh-stream-stack/lixh-player-core/include/lixh_player.h")
        if (marker.exists()) return cur
        dir = cur.parentFile
    }
    return project.projectDir
}

val lixhRepoRoot = findRepoRoot()
val lixhFfmpegLib = java.io.File(lixhRepoRoot, "src-tauri/lixh-stream-stack/sdk/android-arm64/lib")
val lixhRuntimeLib = java.io.File(lixhRepoRoot, "src-tauri/lixh-stream-stack/runtime/android-arm64")
val lixhJniOut = java.io.File(project.projectDir, "src/main/jniLibs/arm64-v8a")

val syncFfmpegJni by tasks.registering(Copy::class) {
    onlyIf {
        lixhFfmpegLib.exists() || java.io.File(lixhFfmpegLib, "arm64-v8a").exists() ||
            lixhRuntimeLib.exists()
    }
    // LiveCatchFfmpeg android runtime ships under arm64-v8a/; sdk under lib/.
    from(lixhFfmpegLib) { include("*.so") }
    from(java.io.File(lixhFfmpegLib, "arm64-v8a")) { include("*.so") }
    from(java.io.File(lixhRuntimeLib, "arm64-v8a")) { include("*.so") }
    from(lixhRuntimeLib) { include("*.so") }
    from(java.io.File(lixhRuntimeLib, "lib")) { include("*.so") }
    from(java.io.File(lixhRuntimeLib, "lib/arm64-v8a")) { include("*.so") }
    into(lixhJniOut)
    duplicatesStrategy = DuplicatesStrategy.INCLUDE
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(syncFfmpegJni)
}

android {
    namespace = "com.livecatch.lixh_player"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 26
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
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
