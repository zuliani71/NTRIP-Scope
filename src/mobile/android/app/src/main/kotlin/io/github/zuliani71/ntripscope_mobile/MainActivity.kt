package io.github.zuliani71.ntripscope_mobile

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var file: OutputStream? = null
    @Volatile private var bluetooth: BluetoothSocket? = null
    private var filePicker: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null
    private val adapter get() = getSystemService(BluetoothManager::class.java)?.adapter

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ntripscope/outputs")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "chooseFile" -> {
                        if (filePicker != null) {
                            result.error("busy", "A file picker is already open", null)
                        } else {
                            filePicker = result
                            try {
                                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "application/octet-stream"
                                    putExtra(Intent.EXTRA_TITLE, "corrections.rtcm")
                                }, 801)
                            } catch (error: Exception) {
                                filePicker = null
                                result.error("file", error.localizedMessage, null)
                            }
                        }
                    }
                    "pairedDevices" -> {
                        if (Build.VERSION.SDK_INT >= 31 &&
                            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                            if (permissionResult != null) {
                                result.error("busy", "Bluetooth permission is already being requested", null)
                            } else {
                                permissionResult = result
                                requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 802)
                            }
                        } else {
                            listPaired(result)
                        }
                    }
                    "openFile" -> work(result) {
                        file?.close()
                        file = contentResolver.openOutputStream(Uri.parse(call.argument<String>("uri")!!), "wt")
                            ?: error("Cannot open the selected RTCM file")
                    }
                    "writeFile" -> work(result) {
                        (file ?: error("RTCM file is closed")).write(call.arguments as ByteArray)
                    }
                    "closeFile" -> work(result) {
                        val output = file
                        file = null
                        output?.close()
                    }
                    "openBluetooth" -> work(result) {
                        val device = adapter?.getRemoteDevice(call.argument<String>("address")!!)
                            ?: error("Bluetooth is unavailable")
                        val socket = device.createRfcommSocketToServiceRecord(
                            UUID.fromString("00001101-0000-1000-8000-00805F9B34FB"))
                        bluetooth = socket
                        try {
                            socket.connect()
                        } catch (error: Exception) {
                            bluetooth = null
                            socket.close()
                            throw error
                        }
                    }
                    "writeBluetooth" -> work(result) {
                        (bluetooth ?: error("Bluetooth is disconnected")).outputStream.write(call.arguments as ByteArray)
                    }
                    "closeBluetooth" -> {
                        // Closing from another thread releases a pending RFCOMM connect or write.
                        val socket = bluetooth
                        bluetooth = null
                        Thread {
                            runCatching { socket?.close() }
                            runOnUiThread { result.success(null) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun work(result: MethodChannel.Result, action: () -> Unit) {
        worker.execute {
            try {
                action()
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread { result.error("output", error.localizedMessage, null) }
            }
        }
    }

    private fun listPaired(result: MethodChannel.Result) {
        try {
            val radio = adapter ?: error("This device has no Bluetooth adapter")
            check(radio.isEnabled) { "Enable Bluetooth in Android settings" }
            result.success(radio.bondedDevices.map {
                mapOf("name" to (it.name ?: it.address), "address" to it.address)
            }.sortedBy { it["name"] })
        } catch (error: Exception) {
            result.error("bluetooth", error.localizedMessage, null)
        }
    }

    @Deprecated("FlutterActivity receives the picker result here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 801) return
        val result = filePicker
        filePicker = null
        result?.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 802) return
        val result = permissionResult ?: return
        permissionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) listPaired(result)
        else result.error("permission", "Allow access to nearby devices to use Bluetooth", null)
    }

    override fun onDestroy() {
        runCatching { bluetooth?.close() }
        worker.execute { runCatching { file?.close() } }
        worker.shutdown()
        super.onDestroy()
    }
}
