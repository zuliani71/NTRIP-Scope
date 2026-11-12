package io.github.zuliani71.ntripscope_mobile

import android.app.Application
import android.os.PowerManager
import java.util.concurrent.CompletableFuture
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34, 36], application = Application::class)
class ShutdownGuardTest {
    @Test fun cpuStaysAwakeUntilReceiverAndCasterHaveBothClosed() {
        val guard = ShutdownGuard(RuntimeEnvironment.getApplication().getSystemService(PowerManager::class.java))
        val receiver = CompletableFuture<Void>();val caster = CompletableFuture<Void>()
        val done = guard.finishWhen(receiver,caster)
        assertTrue(guard.isHeld)
        receiver.complete(null);assertTrue(guard.isHeld);assertFalse(done.isDone)
        caster.complete(null);assertTrue(done.isDone);assertFalse(guard.isHeld)
    }
    @Test fun failedFileCloseStillWaitsForCasterAndReleasesTheCpu() {
        val guard = ShutdownGuard(RuntimeEnvironment.getApplication().getSystemService(PowerManager::class.java))
        val file = CompletableFuture<Void>();val caster = CompletableFuture<Void>()
        val done = guard.finishWhen(file,caster)
        file.completeExceptionally(IllegalStateException("file closed"));assertTrue(guard.isHeld)
        caster.complete(null);assertTrue(done.isCompletedExceptionally);assertFalse(guard.isHeld)
    }
}
