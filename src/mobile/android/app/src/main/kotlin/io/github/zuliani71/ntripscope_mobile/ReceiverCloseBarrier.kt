package io.github.zuliani71.ntripscope_mobile

import java.io.Closeable
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Detaching a receiver does not mean its RFCOMM close has finished. */
class ReceiverCloseBarrier(private val settleMillis: Long = 1000) {
    private val closer = Executors.newSingleThreadExecutor { task -> Thread(task, "NTRIP receiver close") }
    private var latest = CompletableFuture.completedFuture(Unit)

    @Synchronized fun close(socket: Closeable?, reader: Thread?): CompletableFuture<Unit> {
        if (socket == null && reader == null) return latest
        val done = CompletableFuture<Unit>()
        latest = done
        closer.execute {
            try {
                socket?.close()
                if (reader != null && reader !== Thread.currentThread()) {
                    reader.join(1500)
                    if (reader.isAlive) throw IOException("Receiver reader is still closing; wait before reconnecting")
                }
                // Legacy SPP modules need a brief quiet interval after the link is released.
                if (socket != null && settleMillis > 0) Thread.sleep(settleMillis)
                done.complete(Unit)
            } catch (error: Exception) { done.completeExceptionally(error) }
        }
        return done
    }
    fun awaitReady() {
        val pending = synchronized(this) { latest }
        try { pending.get(8, TimeUnit.SECONDS) }
        catch (error: Exception) { throw IOException("Previous Bluetooth shutdown has not finished: ${error.cause?.message ?: error.message}", error) }
    }
    fun shutdown() { closer.shutdown() }
}
