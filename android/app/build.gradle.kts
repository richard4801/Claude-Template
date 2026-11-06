plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
}

android {
    namespace = "studio.muse.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "studio.muse.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // The live MUSE API (server/api on Railway). Settings → Developer can point the app at another URL
        // (e.g. http://10.0.2.2:8787/ for a local server/api or server/mock from the emulator).
        buildConfigField("String", "DEFAULT_SERVER_URL", "\"https://angelic-elegance-production-c42b.up.railway.app/\"")
        // Demo mode (the in-process fake with the bundled sample studio) is off by default in every build.
        buildConfigField("boolean", "DEFAULT_USE_FAKE", "false")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.systemProperty("robolectric.pixelCopyRenderMode", "hardware")
                // Robolectric fetches android-all jars; use the Maven Central mirror.
                it.systemProperty("robolectric.dependency.repo.url", "https://maven-central.storage-download.googleapis.com/maven2/")
                it.maxHeapSize = "3g"
            }
        }
    }
    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/LICENSE*", "/META-INF/NOTICE*")
    }
    sourceSets["main"].assets.srcDir("../../server/api/assets/lookpack") // the look pack (single copy) → assets/looks/…
    // AI suite: the composer's preview loops and stills (design/previews, rendered in Blender) → assets/previews/…
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/composerPreviews"))
}

// AI suite (workstream 1): copies design/previews (moves, lighting, angles only) into a generated assets dir, so the
// files have a single committed copy.
val copyComposerPreviews by tasks.registering(Sync::class) {
    from("../../design/previews") { include("moves/**", "lighting/**", "angles/**") }
    into(layout.buildDirectory.dir("generated/composerPreviews/previews"))
}
tasks.named("preBuild") { dependsOn(copyComposerPreviews) }

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

roborazzi {
    outputDir.set(file("src/test/screenshots"))
}

dependencies {
    implementation(project(":core"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.okhttp.sse)
    implementation(libs.retrofit)
    implementation(libs.retrofit.kotlinx.serialization)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui)
    // The on-device video editor (plans/video-editor.md): export with Transformer, frame-rate effects.
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)
}
