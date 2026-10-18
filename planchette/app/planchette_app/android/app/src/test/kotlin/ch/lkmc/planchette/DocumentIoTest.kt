package ch.lkmc.planchette

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DocumentIoTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun createRequestsPreserveConfigExtensionsAndIdentifyHtml() {
        for (name in listOf("config.json", "settings.conf", "script.sh", "Makefile", "Untitled")) {
            assertEquals("application/octet-stream", documentCreationMimeType(name))
        }
        assertEquals("text/html", documentCreationMimeType("report.html"))
        assertEquals("text/html", documentCreationMimeType("report.HTML"))
    }

    @Test fun boundedReadsRejectOversizedProviders() {
        val limit = ByteArray(DocumentIo.MAXIMUM_BYTES)
        assertArrayEquals(limit, DocumentIo.read(ByteArrayInputStream(limit)))
        assertThrows(IOException::class.java) {
            DocumentIo.read(ByteArrayInputStream(ByteArray(DocumentIo.MAXIMUM_BYTES + 1)))
        }
    }

    @Test fun changedDocumentsAreNeverOpenedForWriting() {
        val recovery = temporary.newFolder()
        var openedForWrite = false
        assertThrows(IOException::class.java) {
            DocumentIo(recovery).write("new".toByteArray(), DocumentIo.digest("old".toByteArray()), "file.txt",
                { ByteArrayInputStream("external change".toByteArray()) },
                { openedForWrite = true; ByteArrayOutputStream() })
        }
        assertFalse(openedForWrite)
        assertTrue(recovery.listFiles()!!.isEmpty())
    }

    @Test fun successfulWritesReadBackAndRetireTheirBackup() {
        val recovery = temporary.newFolder()
        var provider = "old".toByteArray()
        val replacement = "replacement".toByteArray()
        DocumentIo(recovery).write(replacement, DocumentIo.digest(provider), "file.txt",
            { ByteArrayInputStream(provider) },
            { object : ByteArrayOutputStream() {
                override fun close() { provider = toByteArray() }
            } })
        assertArrayEquals(replacement, provider)
        assertTrue(recovery.listFiles()!!.isEmpty())
    }

    @Test fun failedWritesRetainTheCompleteOriginal() {
        val recovery = temporary.newFolder()
        val original = "original contents".toByteArray()
        val error = assertThrows(IOException::class.java) {
            DocumentIo(recovery).write("replacement".toByteArray(), DocumentIo.digest(original), "file.txt",
                { ByteArrayInputStream(original) },
                { object : OutputStream() {
                    override fun write(value: Int) { throw IOException("Provider disconnected") }
                } })
        }
        assertTrue(error.message!!.contains("Restart Planchette"))
        assertArrayEquals(original, recovery.listFiles()!!.single().readBytes())
    }

    @Test fun discardedProviderWritesAreFailuresWithRecovery() {
        val recovery = temporary.newFolder()
        val original = "original".toByteArray()
        assertThrows(IOException::class.java) {
            DocumentIo(recovery).write("replacement".toByteArray(), DocumentIo.digest(original), "file.txt",
                { ByteArrayInputStream(original) }, { ByteArrayOutputStream() })
        }
        assertArrayEquals(original, recovery.listFiles()!!.single().readBytes())
    }
}
