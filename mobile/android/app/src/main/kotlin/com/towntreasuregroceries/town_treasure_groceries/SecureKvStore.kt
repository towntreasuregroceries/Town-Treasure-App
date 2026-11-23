package com.towntreasuregroceries.town_treasure_groceries

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Self-healing Android Keystore AES-256-GCM key-value store that avoids the
 * deprecated Jetpack EncryptedSharedPreferences / Tink stack.
 */
class SecureKvStore(context: Context) {
    companion object {
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "ttg_secure_vault_aes_v2"
        private const val PREFS_NAME = "ttg_secure_vault_v2"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }

    private val prefs = context.applicationContext.getSharedPreferences(
        PREFS_NAME,
        Context.MODE_PRIVATE
    )
    private val lock = Any()

    fun read(key: String): String? = synchronized(lock) {
        val encoded = prefs.getString(key, null) ?: return null
        return try {
            decrypt(encoded)
        } catch (_: Throwable) {
            prefs.edit().remove(key).apply()
            null
        }
    }

    fun write(key: String, value: String) = synchronized(lock) {
        val encoded = try {
            encrypt(value)
        } catch (_: Throwable) {
            resetKeystoreAndPrefs()
            encrypt(value)
        }
        prefs.edit().putString(key, encoded).apply()
    }

    fun delete(key: String) = synchronized(lock) {
        prefs.edit().remove(key).apply()
    }

    private fun getOrCreateKey(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val existing = ks.getKey(KEY_ALIAS, null)
        if (existing is SecretKey) {
            return existing
        }
        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            KEYSTORE_PROVIDER
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    private fun resetKeystoreAndPrefs() {
        runCatching {
            val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
            if (ks.containsAlias(KEY_ALIAS)) {
                ks.deleteEntry(KEY_ALIAS)
            }
        }
        prefs.edit().clear().apply()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val cipherBytes = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(1 + iv.size + cipherBytes.size)
        combined[0] = iv.size.toByte()
        System.arraycopy(iv, 0, combined, 1, iv.size)
        System.arraycopy(cipherBytes, 0, combined, 1 + iv.size, cipherBytes.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val raw = Base64.decode(encoded, Base64.NO_WRAP)
        if (raw.size < 2) {
            throw IllegalArgumentException("Corrupted secure entry")
        }
        val ivLen = raw[0].toInt() and 0xFF
        if (ivLen <= 0 || raw.size <= 1 + ivLen) {
            throw IllegalArgumentException("Invalid IV length")
        }
        val iv = raw.copyOfRange(1, 1 + ivLen)
        val cipherBytes = raw.copyOfRange(1 + ivLen, raw.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateKey(),
            GCMParameterSpec(GCM_TAG_BITS, iv)
        )
        return String(cipher.doFinal(cipherBytes), Charsets.UTF_8)
    }
}
