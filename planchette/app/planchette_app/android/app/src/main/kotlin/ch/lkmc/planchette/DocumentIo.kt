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

        // The largest generated page a write accepts, matching
        // planchette_core's htmlExportMaximumBytes. A page is never edited,
        // so the document limit does not apply to it.
        const val EXPORT_MAXIMUM_BYTES = 32 * 1024 * 1024

        fun digest(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

        /** Hashes a provider stream of any size without holding it, so the
         * digest of an existing save target never trips a read limit. */
        fun digest(input: InputStream): String = input.use {
            val sha256 = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                sha256.update(buffer, 0, count)
            }
            hex(sha256.digest())
        }

        private fun hex(digest: ByteArray): String = digest.joinToString("") { "%02x".format(it) }

        fun read(input: InputStream, maximumBytes: Int = MAXIMUM_BYTES): ByteArray = input.use {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                if (output.size() + count > maximumBytes) {
                    throw IOException("The built-in editor supports text files up to ${maximumBytes / (1024 * 1024)} MB.")
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    /** [maximumBytes] bounds both the new bytes and the original they
     * replace: the document limit, or up to [EXPORT_MAXIMUM_BYTES] for a
     * generated page. */
    fun write(
        bytes: ByteArray,
        expectedSha256: String,
        name: String,
        openInput: () -> InputStream,
        openOutput: () -> OutputStream,
        maximumBytes: Int = MAXIMUM_BYTES,
    ) {
        require(maximumBytes in 0..EXPORT_MAXIMUM_BYTES) { "Unsupported write limit: $maximumBytes bytes." }
        require(bytes.size <= maximumBytes) { "The edited file exceeds the ${maximumBytes / (1024 * 1024)} MB limit." }
        val original = read(openInput(), maximumBytes)
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
            if (!read(openInput(), maximumBytes).contentEquals(bytes)) {
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

    /** Deletes a recovery copy once the user has saved its text elsewhere.
     * Only a regular file directly inside the recovery directory qualifies,
     * so an identity passed in from Dart can never name another app file. */
    fun discard(file: File) {
        val candidate = file.canonicalFile
        require(candidate.parentFile == recoveryDirectory.canonicalFile && candidate.isFile) {
            "Only recovery copies can be discarded."
        }
        if (!candidate.delete()) throw IOException("Could not delete the recovery copy.")
    }
}
