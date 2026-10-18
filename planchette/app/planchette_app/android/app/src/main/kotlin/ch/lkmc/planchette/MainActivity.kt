package ch.lkmc.planchette

import android.app.Activity
import android.content.ClipDescription
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.Executors

// text/plain makes Android append .txt to configuration and script names.
internal fun documentCreationMimeType(name: String?): String =
    if (name?.endsWith(".html", ignoreCase = true) == true ||
        name?.endsWith(".htm", ignoreCase = true) == true) ClipDescription.MIMETYPE_TEXT_HTML
    else ClipDescription.MIMETYPE_UNKNOWN

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "planchette/documents"
        const val OPEN_DOCUMENT = 1
        const val CREATE_DOCUMENT = 2
        const val ERROR_DOCUMENT = "document_error"
        const val ERROR_RECOVERY = "document_recovery"
    }

    private val documents = mutableMapOf<String, Uri>()
    private val created = mutableMapOf<String, String>()
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var picker: MethodChannel.Result? = null
    private val recoveryDirectory get() = File(filesDir, "recovery")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> pick(Intent.ACTION_OPEN_DOCUMENT, OPEN_DOCUMENT, null, result)
                    "create" -> pick(Intent.ACTION_CREATE_DOCUMENT, CREATE_DOCUMENT,
                        call.argument<String>("name"), result)
                    else -> work(result) { handle(call) }
                }
            }
    }

    private fun handle(call: MethodCall): Any? {
        if (call.method == "settingsPath") return File(filesDir, "settings.json").path
        if (call.method == "recoveries") {
            return recoveryDirectory.listFiles()?.filter { it.isFile }
                ?.sortedBy { it.name }?.map { register(Uri.fromFile(it)) } ?: emptyList<String>()
        }
        val path = requireNotNull(call.argument<String>("path")) { "Missing document identity." }
        val uri = requireNotNull(documents[path]) { "Choose the document again with Open or Save As." }
        when (call.method) {
            "read" -> return read(uri)
            "stat" -> return stat(uri)
            "readOnly" -> return uri.scheme == "file" || !writable(uri)
            "digest" -> {
                // ACTION_CREATE_DOCUMENT has already created an empty document.
                // Keep it a new save target, guarded by its picker-time digest.
                if (created.containsKey(path)) return null
                return try { DocumentIo.digest(read(uri)) } catch (_: FileNotFoundException) { null }
            }
            "write" -> {
                require(uri.scheme == "content") { "Use Save As to save a recovery copy." }
                val bytes = requireNotNull(call.argument<ByteArray>("bytes")) { "Missing document bytes." }
                val expected = call.argument<String>("expectedSha256") ?: created[path]
                    ?: throw IOException("The document no longer exists. Use Save As.")
                DocumentIo(recoveryDirectory).write(bytes, expected, File(path).name,
                    openInput = { input(uri) },
                    openOutput = { contentResolver.openOutputStream(uri, "wt")
                        ?: throw IOException("The document provider refused the write.") })
                created.remove(path)
                return null
            }
            else -> throw IllegalArgumentException("Unknown document operation: ${call.method}")
        }
    }

    private fun input(uri: Uri) = contentResolver.openInputStream(uri)
        ?: throw FileNotFoundException("The document is unavailable. Choose it again with Open.")

    private fun read(uri: Uri) = DocumentIo.read(input(uri))

    private fun register(uri: Uri): String {
        documents.entries.find { it.value == uri }?.let { return it.key }
        if (uri.scheme == "file") {
            val path = requireNotNull(uri.path)
            documents[path] = uri
            return path
        }
        require(uri.scheme == "content") { "The picker did not return an Android document." }
        var name = "Untitled.txt"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) name = it.getString(0)
        }
        name = name.replace(Regex("[/\\\\\\x00-\\x1f]"), "_").take(128)
        if (name.isBlank() || name == "." || name == "..") name = "Untitled.txt"
        // Paths are opaque identities to Dart, never URI spellings or cache copies.
        val key = DocumentIo.digest(uri.toString().toByteArray(Charsets.UTF_8))
        val path = File(filesDir, "documents/$key/$name").path
        documents[path] = uri
        return path
    }

    private fun stat(uri: Uri): Map<String, Any?>? {
        if (uri.scheme == "file") {
            val file = File(requireNotNull(uri.path))
            return if (file.isFile) mapOf("size" to file.length(), "modified" to file.lastModified()) else null
        }
        contentResolver.query(uri, null, null, null, null)?.use {
            if (!it.moveToFirst()) return null
            fun column(name: String): Long? {
                val index = it.getColumnIndex(name)
                return if (index < 0 || it.isNull(index)) null else it.getLong(index)
            }
            return mapOf("size" to column(OpenableColumns.SIZE),
                "modified" to column(DocumentsContract.Document.COLUMN_LAST_MODIFIED)?.takeIf { value -> value > 0 })
        }
        return null
    }

    private fun writable(uri: Uri): Boolean {
        contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use {
            if (it.moveToFirst()) {
                return it.getInt(0) and DocumentsContract.Document.FLAG_SUPPORTS_WRITE != 0
            }
        }
        return false
    }

    private fun pick(action: String, request: Int, name: String?, result: MethodChannel.Result) {
        if (picker != null) {
            result.error(ERROR_DOCUMENT, "A document picker is already open.", null)
            return
        }
        val intent = Intent(action).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (request == CREATE_DOCUMENT) documentCreationMimeType(name) else "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (request == OPEN_DOCUMENT) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            if (name != null) putExtra(Intent.EXTRA_TITLE, File(name).name)
        }
        picker = result
        try {
            startActivityForResult(intent, request)
        } catch (error: Exception) {
            picker = null
            result.error(ERROR_DOCUMENT, "Could not open the system document picker: ${error.message}", null)
        }
    }

    @Deprecated("FlutterActivity uses the activity result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != OPEN_DOCUMENT && requestCode != CREATE_DOCUMENT) return
        val result = picker ?: return
        picker = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(if (requestCode == OPEN_DOCUMENT) emptyList<String>() else null)
            return
        }
        work(result) {
            val uris = linkedSetOf<Uri>()
            data.data?.let { uris.add(it) }
            data.clipData?.let { clip ->
                for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
            }
            val paths = uris.map { uri ->
                val path = register(uri)
                if (requestCode == CREATE_DOCUMENT) created[path] = DocumentIo.digest(read(uri))
                path
            }
            if (requestCode == OPEN_DOCUMENT) paths else paths.singleOrNull()
        }
    }

    private fun work(result: MethodChannel.Result, operation: () -> Any?) {
        // Cloud providers may block. Serialize I/O off the Android UI thread.
        io.execute {
            try {
                val value = operation()
                main.post { result.success(value) }
            } catch (error: Exception) {
                val code = if (error is DocumentRecoveryException) ERROR_RECOVERY else ERROR_DOCUMENT
                main.post { result.error(code, error.message ?: "Document access failed.", null) }
            }
        }
    }

    override fun onDestroy() {
        picker?.error(ERROR_DOCUMENT, "The document picker was interrupted. Try again.", null)
        picker = null
        io.shutdown()
        super.onDestroy()
    }
}
