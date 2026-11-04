// Pure Kotlin module: the layered prompt engine and the pricing math. No Android dependencies.
plugins {
    alias(libs.plugins.kotlin.jvm)
}
kotlin { jvmToolchain(21) }
java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}
dependencies {
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.serialization.json)
}
