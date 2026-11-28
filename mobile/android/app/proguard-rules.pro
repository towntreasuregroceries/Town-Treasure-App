# Keep ML Kit Latin text recognition and Google Play Services classes intact under R8 minification
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.dynamite.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class com.google_mlkit_document_scanner.** { *; }
-keep class com.google.mlkit.vision.documentscanner.** { *; }
-keepclassmembers class com.google.mlkit.** { *; }

# Keep ONNX Runtime JNI and PaddleOCR channel classes intact under R8
-keep class ai.onnxruntime.** { *; }
-keep class com.towntreasuregroceries.town_treasure_groceries.** { *; }
-keep class dev.fluttercommunity.workmanager.** { *; }
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# Keep FlutterSecureStorage, Jetpack EncryptedSharedPreferences, and Tink crypto classes intact under R8
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class androidx.security.crypto.** { *; }
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# Suppress R8 missing-class warnings for unused optional non-Latin ML Kit script modules
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
