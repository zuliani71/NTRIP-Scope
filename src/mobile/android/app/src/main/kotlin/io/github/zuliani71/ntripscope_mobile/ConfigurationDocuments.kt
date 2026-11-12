package io.github.zuliani71.ntripscope_mobile

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns

/** Never truncate a document before explicit selection, confirmation and name validation. */
class ConfigurationDocuments(private val resolver: ContentResolver) {
    private var selected: Uri? = null
    fun name(uri: Uri): String {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        error("The selected file name is unavailable")
    }
    fun select(uri: Uri): String {
        val name = name(uri)
        selected = uri
        return name
    }
    fun replace(uri: Uri, expectedName: String, confirmed: Boolean, bytes: ByteArray) {
        check(selected == uri && confirmed) { "Select a configuration file and confirm replacement first" }
        check(name(uri) == expectedName) { "The file name changed. Select it again before replacing." }
        require(bytes.size <= 1024 * 1024) { "Configuration is too large" }
        val output = resolver.openOutputStream(uri, "rwt") ?: error("Cannot write to the selected file")
        output.use { it.write(bytes); it.flush() }
    }
}
