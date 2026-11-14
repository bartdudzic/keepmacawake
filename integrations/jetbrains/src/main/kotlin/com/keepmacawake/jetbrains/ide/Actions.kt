package com.keepmacawake.jetbrains.ide

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.util.SystemInfo

/** Tools | Keep Mac Awake | Start...: asks for hours (8 by default) and starts a session. */
class StartAction : DumbAwareAction() {
    override fun getActionUpdateThread() = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val options = KeepMacAwakeSettings.getInstance().state
        // On Windows and Linux the controller only explains that the plugin is for Macs.
        if (!SystemInfo.isMac) return KeepMacAwakeService.getInstance().start(options.startHours)
        val dialog = StartDialog(e.project, options.startHours)
        if (!dialog.showAndGet()) return
        options.startHours = dialog.hours
        KeepMacAwakeService.getInstance().start(dialog.hours)
    }
}

/** Tools | Keep Mac Awake | Stop: ends the session only when this IDE started it. */
class StopAction : DumbAwareAction() {
    override fun getActionUpdateThread() = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) = KeepMacAwakeService.getInstance().stop()
}

/** Tools | Keep Mac Awake | Status: whether a session runs, its time left and the free trial. */
class StatusAction : DumbAwareAction() {
    override fun getActionUpdateThread() = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) = KeepMacAwakeService.getInstance().showStatus()
}
