import com.android.build.api.instrumentation.AsmClassVisitorFactory
import com.android.build.api.instrumentation.ClassContext
import com.android.build.api.instrumentation.ClassData
import com.android.build.api.instrumentation.FramesComputationMode
import com.android.build.api.instrumentation.InstrumentationParameters
import com.android.build.api.instrumentation.InstrumentationScope
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.commons.ClassRemapper
import org.objectweb.asm.commons.SimpleRemapper

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
    alias(libs.plugins.chaquopy)
}

android {
    namespace = "studio.muse.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "studio.muse.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 5
        versionName = "0.1.4"
        // The live MUSE API (server/api on Railway). Settings → Developer can point the app at another URL
        // (e.g. http://10.0.2.2:8787/ for a local server/api or server/mock from the emulator).
        buildConfigField("String", "DEFAULT_SERVER_URL", "\"https://angelic-elegance-production-c42b.up.railway.app/\"")
        // Demo mode (the in-process fake with the bundled sample studio) is off by default in every build.
        buildConfigField("boolean", "DEFAULT_USE_FAKE", "false")
        // Recreate links are fetched on the phone (platforms block the studio server): Python and yt-dlp ship for
        // 64-bit ARM phones only, to keep the APK small. Other phones fall back to the server's fetch, then the file.
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    // Release signing (WS4): the studio's release key comes from the environment, never from git. Without it the
    // release build is signed with the debug key, so it still installs for testing (but can't update a signed install).
    val releaseKeystore = System.getenv("MUSE_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (releaseKeystore != null) create("museRelease") {
            storeFile = releaseKeystore
            storePassword = System.getenv("MUSE_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("MUSE_KEY_ALIAS") ?: "muse"
            keyPassword = System.getenv("MUSE_KEY_PASSWORD") ?: System.getenv("MUSE_KEYSTORE_PASSWORD")
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeystore != null) signingConfigs.getByName("museRelease") else signingConfigs.getByName("debug")
            // Performance (plans/perf-audit.md "Android"): R8 shrinks and optimises the code and drops unused resources.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
        // The phone's Python (Recreate links) is ~12 MB of native libraries: compressed in the APK, so the download stays smaller.
        jniLibs.useLegacyPackaging = true
    }
    sourceSets["main"].assets.srcDir("../../server/api/assets/lookpack") // the look pack (single copy) → assets/looks/…
    // AI suite: the composer's preview loops and stills (design/previews, rendered in Blender) → assets/previews/…
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/composerPreviews"))
}

// AI suite (workstream 1): copies design/previews (moves, lighting, angles and the Style stills) into a generated assets dir, so the
// files have a single committed copy.
val copyComposerPreviews by tasks.registering(Sync::class) {
    // + the Style tile stills (genres, eras, tempos: workstream 4, design/previews/source/style_stills.py)
    from("../../design/previews") { include("moves/**", "lighting/**", "angles/**", "genres/**", "eras/**", "tempos/**") }
    into(layout.buildDirectory.dir("generated/composerPreviews/previews"))
}
tasks.named("preBuild") { dependsOn(copyComposerPreviews) }

// Recreate links on the phone (WS4): yt-dlp, pinned to the server's version, with no ffmpeg (formats that already
// carry video and sound). Chaquopy (MIT) runs it; app/src/main/python/muse_fetch.py is the entry point.
chaquopy {
    defaultConfig {
        version = "3.13"
        pip { install("yt-dlp==2026.10.26") }
    }
}

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

// Performance: our data classes and Kotlin collections are immutable, so Compose may skip recomposing a screen part whose
// inputs are equal (compose_stability.conf). Set -PcomposeReports=true to write the compiler's stability reports.
composeCompiler {
    stabilityConfigurationFiles.add(rootProject.layout.projectDirectory.file("compose_stability.conf"))
    if (providers.gradleProperty("composeReports").orNull == "true") {
        reportsDestination.set(layout.buildDirectory.dir("compose_compiler"))
        metricsDestination.set(layout.buildDirectory.dir("compose_compiler"))
    }
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

// Edit blend modes (WS8, plans/video-editor.md "Wave 1 additions"): Media3 1.11 draws every multi-layer composite with
// its package-private DefaultCompositorGlProgram and lets no app replace it (Transformer can't even take a custom video
// graph). The app ships androidx.media3.effect.MuseCompositorGlProgram (app/src/main/java/androidx/media3/effect/), a
// copy that also blends layers by mode, and this instrumentation rewrites Media3's references to the library class to
// it (DefaultVideoCompositor, the frame processors), so the preview player and the export both use it.
abstract class MuseCompositorRemap : AsmClassVisitorFactory<InstrumentationParameters.None> {
    override fun createClassVisitor(classContext: ClassContext, nextClassVisitor: ClassVisitor): ClassVisitor =
        ClassRemapper(nextClassVisitor, SimpleRemapper("androidx/media3/effect/DefaultCompositorGlProgram", "androidx/media3/effect/MuseCompositorGlProgram"))
    override fun isInstrumentable(classData: ClassData): Boolean =
        classData.className.startsWith("androidx.media3.effect.") && !classData.className.startsWith("androidx.media3.effect.Muse")
}
androidComponents {
    onVariants { variant ->
        variant.instrumentation.transformClassesWith(MuseCompositorRemap::class.java, InstrumentationScope.ALL) {}
        variant.instrumentation.setAsmFramesComputationMode(FramesComputationMode.COPY_FRAMES)
    }
}
