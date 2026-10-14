group = "com.obumnwabude.channel_bridge"
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

android {
    namespace = "com.obumnwabude.channel_bridge"

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
        minSdk = 24
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
    // LiteRT (formerly TensorFlow Lite) interpreter. 1.4.2 is the version the
    // flutter_litert package 3.9.4 pins for its Interpreter on Android:
    //   https://github.com/hugocornellier/flutter_litert/blob/main/android/build.gradle.kts
    //   (`val litert = "1.4.2"`; its CHANGELOG 3.9.1: "The Interpreter stays on LiteRT 1.4.2").
    // Keep the two equal: Gradle then ships one libtensorflowlite_jni.so, so the
    // channel path and the FFI path run the same runtime build. The Java API of
    // this line is still `org.tensorflow.lite.Interpreter`. It lives on Google's
    // Maven (google()), not Maven Central.
    implementation("com.google.ai.edge.litert:litert:1.4.2")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
