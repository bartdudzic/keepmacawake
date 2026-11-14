package com.keepmacawake.jetbrains.ide

import com.intellij.ide.AppLifecycleListener
import com.intellij.ide.BrowserUtil
import com.intellij.notification.Notification
import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.Disposable
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.service
import com.intellij.openapi.diagnostic.thisLogger
import com.intellij.openapi.util.SystemInfo
import com.intellij.util.concurrency.AppExecutorUtil
import com.keepmacawake.jetbrains.KeepMacAwakeCli
import com.keepmacawake.jetbrains.KeepMacAwakeController
import com.keepmacawake.jetbrains.Note
import com.keepmacawake.jetbrains.NoteAction
import com.keepmacawake.jetbrains.WEBSITE_URL
import com.keepmacawake.jetbrains.resolveCliPath
import java.util.concurrent.TimeUnit

/**
 * Holds the controller for this IDE process and runs every command on one
 * background thread, in order, so the IDE never waits for the keepmacawake command.
 */
@Service(Service.Level.APP)
class KeepMacAwakeService : Disposable {
    private val executor = AppExecutorUtil.createBoundedApplicationPoolExecutor("Keep Mac Awake", 1)
    private val controller = KeepMacAwakeController(
        cli = KeepMacAwakeCli(resolveCliPath()),
        isMac = SystemInfo.isMac,
        notify = ::show,
    )

    fun submit(work: (KeepMacAwakeController) -> Unit) {
        executor.execute {
            try {
                work(controller)
            } catch (e: Exception) {
                thisLogger().warn("Keep Mac Awake command failed", e)
            }
        }
    }

    fun start(hours: Int, batteryConfirmed: Boolean = false) = submit { it.start(hours, batteryConfirmed) }

    fun stop() = submit { it.stop() }

    fun showStatus() {
        val options = KeepMacAwakeSettings.getInstance().state
        submit { it.showStatus(options.holdDuringRuns, options.holdHours) }
    }

    fun runStarted(run: Any, capHours: Int) = submit { it.runStarted(run, capHours) }

    fun runEnded(run: Any) = submit { it.runEnded(run) }

    /** On quit, ends a session the run hold started for a run that is still going, waiting a few seconds at most. */
    fun ideClosing() {
        try {
            executor.submit { controller.ideClosing() }.get(10, TimeUnit.SECONDS)
        } catch (_: Exception) {
        }
    }

    private fun show(note: Note) {
        val notification = NotificationGroupManager.getInstance()
            .getNotificationGroup(NOTIFICATION_GROUP)
            .createNotification(
                "Keep Mac Awake",
                note.text,
                if (note.warning) NotificationType.WARNING else NotificationType.INFORMATION,
            )
        note.actions.forEach { notification.addAction(toAction(it)) }
        notification.notify(null)
    }

    private fun toAction(action: NoteAction): NotificationAction = when (action) {
        NoteAction.OpenWebsite -> NotificationAction.createSimple("Get Keep Mac Awake") {
            BrowserUtil.browse(WEBSITE_URL)
        }
        is NoteAction.StartHours -> NotificationAction.createSimpleExpiring(
            if (action.hours == 1) "Start 1 hour" else "Start ${action.hours} hours",
        ) {
            start(action.hours, action.batteryConfirmed)
        }
    }

    override fun dispose() {
        executor.shutdown()
    }

    companion object {
        const val NOTIFICATION_GROUP = "Keep Mac Awake"

        fun getInstance(): KeepMacAwakeService = service()
    }
}

/** Ends a run hold's session when the IDE quits during a run. */
class KeepMacAwakeLifecycle : AppLifecycleListener {
    override fun appWillBeClosed(isRestart: Boolean) {
        KeepMacAwakeService.getInstance().ideClosing()
    }
}
