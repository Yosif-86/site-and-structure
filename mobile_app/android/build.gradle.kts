allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (file_picker) compile Kotlin for JVM 1.8 while their Java
// targets 11, which newer Gradle rejects. Align every plugin's Kotlin target
// with its Java target.
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        val javaTarget = project.extensions
            .findByType(com.android.build.gradle.BaseExtension::class.java)
            ?.compileOptions?.targetCompatibility?.toString() ?: "11"
        compilerOptions.jvmTarget.set(
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(javaTarget))
    }
}

// file_picker still compiles against SDK 34; its dependencies need 35+.
subprojects {
    val raiseCompileSdk = {
        project.extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.let { ext ->
            val current = ext.compileSdkVersion?.removePrefix("android-")?.toIntOrNull() ?: 0
            if (current in 1..35) ext.compileSdkVersion(36)
        }
    }
    if (project.state.executed) raiseCompileSdk() else project.afterEvaluate { raiseCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
