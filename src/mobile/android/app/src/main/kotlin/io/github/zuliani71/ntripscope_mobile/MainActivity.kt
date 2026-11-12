package io.github.zuliani71.ntripscope_mobile

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicInteger
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val resourcesEpoch = AtomicInteger()
    private val fileEpoch = AtomicInteger()
    private val bluetoothEpoch = AtomicInteger()
    private val receiverLock = Any()
    private val receiverClose = ReceiverCloseBarrier()
    private var bluetoothReader: Thread? = null
    private var shutdownPending: CompletableFuture<Void>? = null
    @Volatile private var visible = true
    private var lifecycleChannel: MethodChannel? = null
    private var backgroundPermission: MethodChannel.Result? = null
    private var batteryPermission: MethodChannel.Result? = null
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF && !BackgroundStreamService.running &&
                !getSystemService(PowerManager::class.java).isInteractive) suspendResources()
        }
    }
    private val worker = Executors.newSingleThreadExecutor()
    private var file: OutputStream? = null
    @Volatile private var bluetooth: BluetoothSocket? = null
    @Volatile private var lastBluetoothRead = 0L
    private var bluetoothEvents: EventChannel.EventSink? = null
    private var configPicker: MethodChannel.Result? = null
    private val configurationDocuments by lazy { ConfigurationDocuments(contentResolver) }
    private val configWorker = Executors.newSingleThreadExecutor()
    private var filePicker: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null
    private val adapter get() = getSystemService(BluetoothManager::class.java)?.adapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(screenReceiver, filter)
    }
    override fun onResume() { super.onResume(); visible = true }
    override fun onPause() {
        val locked = getSystemService(KeyguardManager::class.java).isKeyguardLocked
        if (!BackgroundStreamService.running && (!getSystemService(PowerManager::class.java).isInteractive || locked)) suspendResources()
        super.onPause()
    }
    override fun onStop() {
        visible = false
        if (!BackgroundStreamService.running) suspendResources()
        super.onStop()
    }
    private data class ReceiverRelease(val generation: Int, val done: CompletableFuture<Unit>)
    private fun detachBluetooth(expected: BluetoothSocket? = null): ReceiverRelease = synchronized(receiverLock) {
        check(expected == null || bluetooth === expected) { "Bluetooth connection cancelled" }
        val generation = bluetoothEpoch.incrementAndGet()
        val socket = bluetooth
        val reader = bluetoothReader
        bluetooth = null
        bluetoothReader = null
        ReceiverRelease(generation, receiverClose.close(socket, reader))
    }
    private fun suspendResources(method: String = "suspend") {
        if (shutdownPending?.isDone == false) return
        // Keep the CPU awake briefly while Dart closes the caster and native I/O drains.
        val guard = runCatching { ShutdownGuard(getSystemService(PowerManager::class.java)) }.getOrNull()
        resourcesEpoch.incrementAndGet()
        val receiver = detachBluetooth().done
        val files = if (!worker.isShutdown) CompletableFuture.runAsync({
            val output = file; file = null; output?.close()
        }, worker) else CompletableFuture.completedFuture(null)
        val caster = CompletableFuture<Void>()
        shutdownPending = guard?.finishWhen(receiver, files, caster)
            ?: CompletableFuture.allOf(receiver, files, caster)
        val channel = lifecycleChannel
        if (channel == null) caster.complete(null)
        val timeout = Runnable { caster.complete(null) }
        val handler = Handler(Looper.getMainLooper())
        handler.postDelayed(timeout, 12000)
        caster.whenComplete { _, _ -> handler.removeCallbacks(timeout) }
        if (channel != null) channel.invokeMethod(method, null, object : MethodChannel.Result {
            override fun success(result: Any?) { caster.complete(null) }
            override fun error(code: String, message: String?, details: Any?) { caster.complete(null) }
            override fun notImplemented() { caster.complete(null) }
        })
    }
    private fun allowed(epoch: Int): Boolean = resourcesEpoch.get() == epoch && (visible || BackgroundStreamService.running)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        lifecycleChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ntripscope/lifecycle")
        BackgroundStreamService.onStopRequested = { suspendResources("stop") }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ntripscope/background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        if (backgroundPermission != null || batteryPermission != null) result.error("busy", "A background permission request is already open", null)
                        else if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            backgroundPermission = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 803)
                        } else prepareBattery(result)
                    }
                    "batterySettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                            result.success(null)
                        } catch (error: Exception) { result.error("battery", error.localizedMessage, null) }
                    }
                    "start" -> {
                        if (!visible) result.error("background", "Start streaming while NTRIP Scope is visible", null)
                        else if (BackgroundStreamService.ready != null) result.error("busy", "Screen-off streaming is starting", null)
                        else {
                            BackgroundStreamService.requested = true
                            BackgroundStreamService.ready = { error ->
                                if (error == null) result.success(null) else result.error("background", error, null)
                            }
                            try {
                                val intent = Intent(this, BackgroundStreamService::class.java)
                                    .putExtra("mountpoint", call.argument<String>("mountpoint"))
                                if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                            } catch (error: Exception) {
                                BackgroundStreamService.requested = false
                                BackgroundStreamService.ready = null
                                result.error("background", error.localizedMessage, null)
                            }
                        }
                    }
                    "stop" -> {
                        BackgroundStreamService.requested = false
                        val completed = { result.success(null) }
                        BackgroundStreamService.stopped.add(completed)
                        if (!stopService(Intent(this, BackgroundStreamService::class.java))) {
                            BackgroundStreamService.stopped.remove(completed)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ntripscope/configuration")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "chooseExisting" -> {
                        if (configPicker != null) result.error("busy", "A configuration picker is already open", null)
                        else {
                            configPicker = result
                            try {
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "*/*"
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                                }, 805)
                            } catch (error: Exception) {
                                configPicker = null
                                result.error("configuration", error.localizedMessage, null)
                            }
                        }
                    }
                    "replace" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) result.error("configuration", "Select a configuration file first", null)
                        else configWorker.execute {
                            try {
                                configurationDocuments.replace(uri,
                                    call.argument<String>("name") ?: "",
                                    call.argument<Boolean>("confirmedOverwrite") == true,
                                    call.argument<ByteArray>("bytes") ?: error("Configuration data is missing"))
                                runOnUiThread { result.success(null) }
                            } catch (error: Exception) { runOnUiThread { result.error("configuration", error.localizedMessage, null) } }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "ntripscope/bluetooth")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    bluetoothEvents = events
                }
                override fun onCancel(arguments: Any?) { bluetoothEvents = null }
            })
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
                    "openFile" -> {
                        val epoch = resourcesEpoch.get()
                        val generation = fileEpoch.get()
                        work(result) {
                            check(allowed(epoch) && fileEpoch.get() == generation) { "Session was closed in standby" }
                            file?.close()
                            val output = contentResolver.openOutputStream(Uri.parse(call.argument<String>("uri")!!), "wt")
                                ?: error("Cannot open the selected RTCM file")
                            if (!allowed(epoch) || fileEpoch.get() != generation) { output.close(); error("Session was closed in standby") }
                            file = output
                        }
                    }
                    "writeFile" -> {
                        val destination = file
                        work(result) {
                            check(destination != null && file === destination) { "RTCM file is closed" }
                            destination.write(call.arguments as ByteArray)
                        }
                    }
                    "closeFile" -> {
                        fileEpoch.incrementAndGet()
                        work(result) {
                            val output = file
                            file = null
                            output?.close()
                        }
                    }
                    "openBluetooth" -> {
                      val epoch = resourcesEpoch.get()
                      var generation = bluetoothEpoch.incrementAndGet()
                      work(result) {
                        receiverClose.awaitReady()
                        shutdownPending?.handle { _, _ -> null }?.get(15, TimeUnit.SECONDS)
                        check(allowed(epoch) && bluetoothEpoch.get() == generation) { "Bluetooth connection cancelled" }
                        val device = adapter?.getRemoteDevice(call.argument<String>("address")!!)
                            ?: error("Bluetooth is unavailable")
                        val existing = bluetooth
                        if (existing?.isConnected == true && existing.remoteDevice.address == device.address &&
                            android.os.SystemClock.elapsedRealtime() - lastBluetoothRead < 15000) return@work
                        if (existing != null) {
                            val release = detachBluetooth(existing)
                            generation = release.generation
                            receiverClose.awaitReady()
                            check(allowed(epoch) && bluetoothEpoch.get() == generation) { "Bluetooth connection cancelled" }
                        }
                        if (Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED) {
                            adapter?.cancelDiscovery()
                        }
                        val socket = device.createRfcommSocketToServiceRecord(
                            UUID.fromString("00001101-0000-1000-8000-00805F9B34FB"))
                        var published = false
                        try {
                            synchronized(receiverLock) {
                                check(allowed(epoch) && bluetoothEpoch.get() == generation) { "Bluetooth connection cancelled" }
                                bluetooth = socket
                                published = true
                            }
                            socket.connect()
                            check(bluetooth === socket && allowed(epoch) && bluetoothEpoch.get() == generation) { "Bluetooth connection cancelled" }
                            lastBluetoothRead = android.os.SystemClock.elapsedRealtime()
                            val reader = Thread {
                                val buffer = ByteArray(1024)
                                try {
                                    while (bluetooth === socket) {
                                        val count = socket.inputStream.read(buffer)
                                        if (count < 0) break
                                        lastBluetoothRead = android.os.SystemClock.elapsedRealtime()
                                        val data = buffer.copyOf(count)
                                        runOnUiThread {
                                            if (bluetooth === socket) bluetoothEvents?.success(data)
                                        }
                                    }
                                } catch (_: Exception) {
                                    // EOF and read failures both close this session's receiver.
                                } finally {
                                    runOnUiThread {
                                        if (bluetooth === socket) {
                                            val release = detachBluetooth(socket)
                                            release.done.whenComplete { _, _ -> runOnUiThread {
                                                if (bluetooth == null && bluetoothEpoch.get() == release.generation)
                                                    bluetoothEvents?.success(mapOf("disconnected" to true))
                                            } }
                                        }
                                    }
                                }
                            }
                            synchronized(receiverLock) {
                                check(bluetooth === socket && bluetoothEpoch.get() == generation) { "Bluetooth connection cancelled" }
                                bluetoothReader = reader
                                reader.start()
                            }
                        } catch (error: Exception) {
                            synchronized(receiverLock) {
                                if (bluetooth === socket) detachBluetooth(socket)
                                else if (!published) receiverClose.close(socket, null)
                            }
                            throw error
                        }
                    }
                    }
                    "writeBluetooth" -> {
                        val destination = bluetooth
                        work(result) {
                            check(destination != null && bluetooth === destination) { "Bluetooth is disconnected" }
                            destination.outputStream.write(call.arguments as ByteArray)
                        }
                    }
                    "closeBluetooth" -> {
                        // Closing from another thread releases a pending RFCOMM connect or write.
                        val pending = detachBluetooth().done
                        pending.whenComplete { _, error -> runOnUiThread {
                            if (error == null) result.success(null)
                            else result.error("bluetooth_close", error.cause?.message ?: error.message, null)
                        } }
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
        if (requestCode == 805) {
            val result = configPicker; configPicker = null
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) result?.success(null)
            else configWorker.execute {
                try {
                    val writable = checkUriPermission(uri, android.os.Process.myPid(), android.os.Process.myUid(), Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED
                    val name = configurationDocuments.select(uri)
                    runOnUiThread { result?.success(mapOf("uri" to uri.toString(), "name" to name, "writable" to writable)) }
                } catch (error: Exception) { runOnUiThread { result?.error("configuration", error.localizedMessage, null) } }
            }
            return
        }
        if (requestCode == 804) {
            val result = batteryPermission; batteryPermission = null
            result?.success(backgroundPermissions())
            return
        }
        if (requestCode != 801) return
        val result = filePicker
        filePicker = null
        result?.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 803) {
            val result = backgroundPermission; backgroundPermission = null
            if (result != null) prepareBattery(result)
            return
        }
        if (requestCode != 802) return
        val result = permissionResult ?: return
        permissionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) listPaired(result)
        else result.error("permission", "Allow access to nearby devices to use Bluetooth", null)
    }

    private fun backgroundPermissions(): Map<String, Boolean> = mapOf(
        "batteryExempt" to getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName),
        "notifications" to (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED))
    private fun prepareBattery(result: MethodChannel.Result) {
        if (getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)) {
            result.success(backgroundPermissions()); return
        }
        batteryPermission = result
        try {
            startActivityForResult(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")), 804)
        } catch (_: Exception) {
            batteryPermission = null
            result.success(backgroundPermissions())
        }
    }
    override fun onDestroy() {
        runCatching { unregisterReceiver(screenReceiver) }
        BackgroundStreamService.requested = false
        BackgroundStreamService.onStopRequested = null
        stopService(Intent(this, BackgroundStreamService::class.java))
        suspendResources("stop")
        lifecycleChannel = null
        worker.shutdown()
        receiverClose.shutdown()
        configWorker.shutdown()
        super.onDestroy()
    }
}
