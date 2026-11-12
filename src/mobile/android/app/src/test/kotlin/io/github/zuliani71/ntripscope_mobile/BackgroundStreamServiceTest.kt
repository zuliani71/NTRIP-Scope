package io.github.zuliani71.ntripscope_mobile

import android.app.Application
import android.app.Notification
import android.content.Intent
import android.os.PowerManager
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class BackgroundStreamServiceTest {
    @Before fun reset() {
        BackgroundStreamService.requested = false
        BackgroundStreamService.ready = null
        BackgroundStreamService.onStopRequested = null
        BackgroundStreamService.stopped.clear()
    }
    @After fun clear() = reset()
    private fun cpu(service: BackgroundStreamService): PowerManager.WakeLock? =
        service.javaClass.getDeclaredField("cpu").apply { isAccessible = true }.get(service) as PowerManager.WakeLock?

    @Test fun sessionHoldsCpuAndNotificationUntilServiceIsDestroyed() {
        val controller = Robolectric.buildService(BackgroundStreamService::class.java).create()
        val service = controller.get()
        var acknowledged = false
        BackgroundStreamService.requested = true
        BackgroundStreamService.ready = { error -> assertNull(error); acknowledged = true }
        service.onStartCommand(Intent().putExtra("mountpoint", "TEST"), 0, 1)
        val lock = cpu(service)!!
        assertTrue(acknowledged); assertTrue(BackgroundStreamService.running); assertTrue(lock.isHeld)
        val notification = shadowOf(service).lastForegroundNotification
        assertNotNull(notification)
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        var released = false
        BackgroundStreamService.requested = false
        BackgroundStreamService.stopped.add { released = true }
        controller.destroy()
        assertFalse(lock.isHeld); assertFalse(BackgroundStreamService.running); assertTrue(released)
    }
    @Test fun notificationStopReleasesLocksAndRequestsFullSessionShutdown() {
        val controller = Robolectric.buildService(BackgroundStreamService::class.java).create()
        val service = controller.get()
        BackgroundStreamService.requested = true
        service.onStartCommand(Intent(), 0, 1)
        val lock = cpu(service)!!
        var stops = 0
        BackgroundStreamService.onStopRequested = { stops++ }
        service.onStartCommand(Intent().setAction(BackgroundStreamService.STOP), 0, 2)
        assertEquals(1, stops); assertFalse(BackgroundStreamService.running); assertFalse(lock.isHeld)
        controller.destroy(); assertEquals(1, stops)
    }
    @Test fun cancelledStartupDoesNotLeaveWakeLockOrRunningService() {
        val controller = Robolectric.buildService(BackgroundStreamService::class.java).create()
        val service = controller.get()
        var error: String? = null
        BackgroundStreamService.ready = { error = it }
        service.onStartCommand(Intent(), 0, 1)
        assertNotNull(error); assertFalse(BackgroundStreamService.running); assertNull(cpu(service))
        controller.destroy()
    }
    @Test fun taskRemovalAndUnexpectedDestructionRequestShutdown() {
        val controller = Robolectric.buildService(BackgroundStreamService::class.java).create()
        val service = controller.get()
        var stops = 0
        BackgroundStreamService.requested = true
        BackgroundStreamService.onStopRequested = { stops++ }
        service.onStartCommand(Intent(), 0, 1)
        val lock = cpu(service)!!
        service.onTaskRemoved(null)
        assertEquals(1, stops); assertFalse(lock.isHeld)
        controller.destroy(); assertEquals(1, stops)
    }
}
