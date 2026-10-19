package ch.lkmc.planchette

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

internal class DocumentRecoveryException(message: String, cause: Exception) : IOException(message, cause)

/** Provider streams cannot be renamed atomically. Keep the original until a
 * read-back proves the write, and retain it for recovery on failure or a crash. */
internal class DocumentIo(private val recoveryDirectory: File) {
    companion object {
        // The cross-language document limit, matching planchette_core.
        const val MAXIMUM_BYTES = 4 * 1024 * 1024

        fun digest(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }

        fun read(input: InputStream): ByteArray = input.use {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                if (output.size() + count > MAXIMUM_BYTES) {
                    throw IOException("The built-in editor supports text files up to 4 MB.")
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    fun write(
        bytes: ByteArray,
        expectedSha256: String,
        name: String,
        openInput: () -> InputStream,
        openOutput: () -> OutputStream,
    ) {
        require(bytes.size <= MAXIMUM_BYTES) { "The edited file exceeds the 4 MB limit." }
        val original = read(openInput())
        if (digest(original) != expectedSha256) {
            throw IOException("The document changed in another app. Reload it before saving.")
        }
        check(recoveryDirectory.isDirectory || recoveryDirectory.mkdirs()) {
            "Could not create the document recovery directory."
        }
        val backup = File.createTempFile("recovery-", "-${File(name).name.takeLast(50)}", recoveryDirectory)
        try {
            FileOutputStream(backup).use {
                it.write(original)
                it.fd.sync()
            }
        } catch (error: Exception) {
            backup.delete()
            throw error
        }
        try {
            openOutput().use { it.write(bytes) }
            if (!read(openInput()).contentEquals(bytes)) {
                throw IOException("The document provider did not retain the saved bytes.")
            }
        } catch (error: Exception) {
            throw DocumentRecoveryException(
                "Could not save the document. Its previous contents are preserved. " +
                    "Restart Planchette to open the recovery copy, then use Save As. " +
                    (error.message ?: error.javaClass.simpleName),
                error,
            )
        }
        backup.delete()
    }
}
