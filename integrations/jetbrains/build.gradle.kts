import org.jetbrains.intellij.platform.gradle.IntelliJPlatformType
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    id("org.jetbrains.kotlin.jvm") version "2.3.21"
    id("org.jetbrains.intellij.platform") version "2.20.0"
}

group = "com.keepmacawake"
version = providers.gradleProperty("pluginVersion").get()

// The plugin is built against IntelliJ Platform 2025.3 (Java 21), the oldest
// version it supports, and verified against that and the current release.
kotlin {
    jvmToolchain(21)
    compilerOptions {
        // The IDE provides the Kotlin standard library; stay within the one 2025.3 ships.
        apiVersion.set(KotlinVersion.KOTLIN_2_2)
        languageVersion.set(KotlinVersion.KOTLIN_2_2)
    }
}

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        intellijIdea("2025.3")
        pluginVerifier()
        zipSigner()
    }
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.13.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    // The IntelliJ Platform test runtime loads JUnit 4 classes even for JUnit 5 tests.
    testRuntimeOnly("junit:junit:4.13.2")
}

intellijPlatform {
    buildSearchableOptions = false
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "253"
            untilBuild = provider { null }
        }
        changeNotes = "First release: Start, Stop and Status actions, and an optional hold while a run configuration runs. " +
            "Reads the battery default of Keep Mac Awake 1.0.11: Start asks before a session that may run on battery."
    }
    pluginVerification {
        ides {
            create(IntelliJPlatformType.IntellijIdea, "2025.3")
            create(IntelliJPlatformType.IntellijIdea, "2026.3")
        }
    }
    publishing {
        // Only for the maintainer's release; never read in tests or builds.
        token = providers.environmentVariable("JETBRAINS_MARKETPLACE_TOKEN")
    }
}

tasks.test {
    useJUnitPlatform()
}
