# MUSE release (R8). The libraries bring their own rules (Retrofit, OkHttp, kotlinx.serialization, Coil, Media3, Compose);
# these cover what is specific to the app.

# The demo studio and suite read JSON bundled as Java resources at absolute paths ("/prompt_library.json"): kept by name.
-keepnames class studio.muse.app.data.FakePromptLibrary
-keepnames class studio.muse.app.data.FakePromptScripts
-keepnames class studio.muse.app.data.FakeSuite

# kotlinx.serialization: keep the generated serializers of our @Serializable models (Retrofit's converter looks them up by type).
-keepattributes *Annotation*, InnerClasses, Signature, Exceptions
-keepclassmembers @kotlinx.serialization.Serializable class studio.muse.** {
    *** Companion;
    *** INSTANCE;
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclasseswithmembers class studio.muse.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class studio.muse.**$$serializer { *; }

# Retrofit: the service interface and its suspend functions' generic signatures.
-keep,allowobfuscation interface studio.muse.app.data.MuseService
-keep,allowobfuscation,allowshrinking class kotlin.coroutines.Continuation
-keep,allowobfuscation,allowshrinking class retrofit2.Response

# Readable crash traces in Play Console / logcat (mapping.txt is in app/build/outputs/mapping/release).
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile
