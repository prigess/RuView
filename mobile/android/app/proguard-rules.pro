# Add project specific ProGuard rules here.

# OkHttp — keep platform class names
-dontwarn okhttp3.**
-dontwarn okio.**
-keepnames class okhttp3.internal.publicsuffix.PublicSuffixDatabase

# kotlinx.serialization — keep @Serializable annotated classes
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep all @Serializable data classes in our package
-keep @kotlinx.serialization.Serializable class com.ruview.data.** { *; }

# Kotlin coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-dontwarn kotlinx.coroutines.**

# Jetpack Compose — reflection used by tooling
-keep class androidx.compose.** { *; }

# Keep our ViewModel subclasses
-keep class com.ruview.ui.viewmodel.** { *; }
