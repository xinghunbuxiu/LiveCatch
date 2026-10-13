# Flutter embedding / plugins (also merged from flutter_proguard_rules.pro).
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**
-dontwarn io.flutter.plugin.**
-dontwarn android.**

# App + player JNI
-keep class com.livecatch.lixh_player.** { *; }
-keep class com.example.livecatch_app.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

-if class * implements io.flutter.embedding.engine.plugins.FlutterPlugin
-keep,allowshrinking,allowobfuscation class <1>
