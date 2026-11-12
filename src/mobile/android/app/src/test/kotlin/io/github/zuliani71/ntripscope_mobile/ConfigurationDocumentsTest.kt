package io.github.zuliani71.ntripscope_mobile

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

class TestConfigProvider : ContentProvider() {
    companion object { lateinit var file: File; var displayName = "rover.ini"; var opens = 0 }
    override fun onCreate() = true
    override fun getType(uri: Uri) = "text/plain"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor =
        MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf(displayName)) }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        opens++
        return ParcelFileDescriptor.open(file,ParcelFileDescriptor.parseMode(mode))
    }
    override fun insert(uri: Uri,values: ContentValues?): Uri? = null
    override fun update(uri: Uri,values: ContentValues?,selection: String?,args: Array<out String>?): Int = 0
    override fun delete(uri: Uri,selection: String?,args: Array<out String>?): Int = 0
}
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class ConfigurationDocumentsTest {
    @Test fun confirmationIsRequiredBeforeAnyTruncation() {
        val context=RuntimeEnvironment.getApplication()
        TestConfigProvider.file=File(context.cacheDir,"original.ini").apply { writeText("original-long-configuration") }
        TestConfigProvider.displayName="rover.ini";TestConfigProvider.opens=0
        Robolectric.buildContentProvider(TestConfigProvider::class.java).create("test.config")
        val documents=ConfigurationDocuments(context.contentResolver)
        val uri=Uri.parse("content://test.config/item")
        assertEquals("rover.ini",documents.select(uri))
        assertEquals(0,TestConfigProvider.opens)
        try { documents.replace(uri,"rover.ini",false,"new".toByteArray());fail("Confirmation missing") }
        catch (_: IllegalStateException) {}
        assertEquals("original-long-configuration",TestConfigProvider.file.readText())
        assertEquals(0,TestConfigProvider.opens)
        documents.replace(uri,"rover.ini",true,"new".toByteArray())
        assertEquals("new",TestConfigProvider.file.readText())
    }
    @Test fun renamedOrDifferentDocumentIsRejectedBeforeOpeningOutput() {
        val context=RuntimeEnvironment.getApplication()
        TestConfigProvider.file=File(context.cacheDir,"original.ini").apply{writeText("original")}
        TestConfigProvider.displayName="rover.ini";TestConfigProvider.opens=0
        Robolectric.buildContentProvider(TestConfigProvider::class.java).create("test.config")
        val documents=ConfigurationDocuments(context.contentResolver)
        val uri=Uri.parse("content://test.config/item");documents.select(uri)
        TestConfigProvider.displayName="renamed.ini"
        try {documents.replace(uri,"rover.ini",true,byteArrayOf());fail("File name changed") }catch(_:IllegalStateException){}
        try {documents.replace(Uri.parse("content://test.config/other"),"renamed.ini",true,byteArrayOf());fail("Different file") }catch(_:IllegalStateException){}
        assertEquals(0,TestConfigProvider.opens);assertEquals("original",TestConfigProvider.file.readText())
    }
}
