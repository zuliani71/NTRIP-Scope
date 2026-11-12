package io.github.zuliani71.ntripscope_mobile

import java.io.Closeable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class ReceiverCloseBarrierTest {
    @Test fun repeatedCloseDoesNotAcknowledgeUntilTheRealSocketCloseCompletes() {
        val barrier = ReceiverCloseBarrier(0)
        val closing = CountDownLatch(1); val release = CountDownLatch(1); val calls = AtomicInteger()
        try {
            val first = barrier.close(Closeable { calls.incrementAndGet(); closing.countDown(); release.await(2, TimeUnit.SECONDS) }, null)
            assertTrue(closing.await(1, TimeUnit.SECONDS))
            val second = barrier.close(null, null)
            assertSame(first, second); assertFalse(second.isDone)
            val executor = Executors.newSingleThreadExecutor()
            try {
                val reconnect = CompletableFuture.runAsync({ barrier.awaitReady() }, executor)
                assertFalse(reconnect.isDone)
                release.countDown(); reconnect.get(2, TimeUnit.SECONDS)
                assertEquals(1, calls.get())
            } finally { executor.shutdownNow() }
        } finally { release.countDown(); barrier.shutdown() }
    }
    @Test fun reopenWaitsForReaderExitAndReceiverQuietPeriod() {
        val barrier = ReceiverCloseBarrier(60)
        val readReleased = CountDownLatch(1); val readerExited = CountDownLatch(1)
        val reader = Thread { readReleased.await(); Thread.sleep(30); readerExited.countDown() }.apply { start() }
        try {
            val began = System.nanoTime()
            barrier.close(Closeable { readReleased.countDown() }, reader)
            barrier.awaitReady()
            assertFalse(reader.isAlive); assertEquals(0L, readerExited.count)
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-began) >= 80)
        } finally { readReleased.countDown(); barrier.shutdown() }
    }
    @Test fun queuedClosuresRemainOrderedAndNullCloseWaitsForTheLatest() {
        val barrier = ReceiverCloseBarrier(0)
        val release = CountDownLatch(1); val secondClosed = AtomicInteger()
        try {
            barrier.close(Closeable { release.await(2, TimeUnit.SECONDS) }, null)
            val second = barrier.close(Closeable { secondClosed.incrementAndGet() }, null)
            assertSame(second,barrier.close(null,null)); assertEquals(0,secondClosed.get())
            release.countDown();barrier.awaitReady();assertEquals(1,secondClosed.get())
        } finally { release.countDown();barrier.shutdown() }
    }
}
