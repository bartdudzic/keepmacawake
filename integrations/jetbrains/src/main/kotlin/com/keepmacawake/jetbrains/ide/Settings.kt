package com.keepmacawake.jetbrains.ide

import com.intellij.openapi.components.BaseState
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.SimplePersistentStateComponent
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.components.service
import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.ui.DialogPanel
import com.intellij.openapi.util.SystemInfo
import com.intellij.ui.dsl.builder.bindIntValue
import com.intellij.ui.dsl.builder.bindSelected
import com.intellij.ui.dsl.builder.panel
import com.keepmacawake.jetbrains.DEFAULT_HOURS
import com.keepmacawake.jetbrains.KeepMacAwakeController
import com.keepmacawake.jetbrains.MAX_HOURS
import com.keepmacawake.jetbrains.TRIAL_MAX_HOURS

/** The plugin's settings, saved in keepmacawake.xml in the IDE's options folder. */
@Service(Service.Level.APP)
@State(name = "KeepMacAwakeSettings", storages = [Storage("keepmacawake.xml")])
class KeepMacAwakeSettings : SimplePersistentStateComponent<KeepMacAwakeSettings.Options>(Options()) {
    class Options : BaseState() {
        /** Off by default: a run configuration starts no session unless the user turns this on. */
        var holdDuringRuns by property(false)
        var holdHours by property(DEFAULT_HOURS)
        var startHours by property(DEFAULT_HOURS)
    }

    companion object {
        fun getInstance(): KeepMacAwakeSettings = service()
    }
}

/** Settings | Tools | Keep Mac Awake. */
class KeepMacAwakeConfigurable : BoundConfigurable("Keep Mac Awake") {
    override fun createPanel(): DialogPanel {
        val options = KeepMacAwakeSettings.getInstance().state
        return panel {
            if (!SystemInfo.isMac) {
                row { comment(KeepMacAwakeController.NOT_MAC) }
            }
            row {
                checkBox("Keep this Mac awake while a run configuration runs")
                    .bindSelected(options::holdDuringRuns)
                    .comment(
                        "When a run or debug configuration starts and no Keep Mac Awake session is running, the " +
                            "plugin starts a timed one, also for a closed lid. When the last run ends, it ends that " +
                            "session, only if the plugin started it and it is still the same session. A session " +
                            "started anywhere else is left alone. The first session on a Mac, which starts the free " +
                            "trial, is always yours to start.",
                    )
            }
            row("Longest session for a run:") {
                spinner(1..MAX_HOURS).bindIntValue(options::holdHours)
                label("hours")
            }.rowComment("During the free trial a session lasts at most $TRIAL_MAX_HOURS hours.")
        }
    }
}
