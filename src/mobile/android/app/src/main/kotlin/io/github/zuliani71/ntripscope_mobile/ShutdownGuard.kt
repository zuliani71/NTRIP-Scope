package io.github.zuliani71.ntripscope_mobile

import android.os.PowerManager
import java.util.concurrent.CompletableFuture

/** A bounded CPU lease only while closing receiver, files and the caster session. */
class ShutdownGuard(power: PowerManager) {
    private val wake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NTRIPScope:shutdown").apply {
        setReferenceCounted(false)
        acquire(20000)
    }
    val isHeld: Boolean get() = wake.isHeld
    fun finishWhen(vararg tasks: CompletableFuture<*>): CompletableFuture<Void> {
        val finished = CompletableFuture.allOf(*tasks)
        finished.whenComplete { _, _ -> runCatching { if (wake.isHeld) wake.release() } }
        return finished
    }
}
