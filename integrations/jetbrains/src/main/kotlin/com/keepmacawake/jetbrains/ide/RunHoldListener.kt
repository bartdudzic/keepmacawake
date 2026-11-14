package com.keepmacawake.jetbrains.ide

import com.intellij.execution.ExecutionListener
import com.intellij.execution.process.ProcessHandler
import com.intellij.execution.runners.ExecutionEnvironment

/**
 * The optional run hold: with "Keep this Mac awake while a run configuration
 * runs" on, a starting run or debug process starts a timed session when none
 * is running, and the end of the last such process ends it (only when the
 * plugin started it and it is still the same session).
 */
class RunHoldListener : ExecutionListener {
    override fun processStarted(executorId: String, env: ExecutionEnvironment, handler: ProcessHandler) {
        val options = KeepMacAwakeSettings.getInstance().state
        if (!options.holdDuringRuns) return
        KeepMacAwakeService.getInstance().runStarted(handler, options.holdHours)
    }

    override fun processTerminated(executorId: String, env: ExecutionEnvironment, handler: ProcessHandler, exitCode: Int) {
        KeepMacAwakeService.getInstance().runEnded(handler)
    }
}
