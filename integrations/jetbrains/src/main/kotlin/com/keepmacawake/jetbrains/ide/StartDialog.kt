package com.keepmacawake.jetbrains.ide

import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.ui.JBIntSpinner
import com.intellij.ui.components.JBLabel
import com.intellij.util.ui.FormBuilder
import com.intellij.util.ui.UIUtil
import com.keepmacawake.jetbrains.MAX_HOURS
import com.keepmacawake.jetbrains.TRIAL_MAX_HOURS
import javax.swing.JComponent

/** Asks how many hours to keep the Mac awake; shows the trial note above 8 hours. */
class StartDialog(project: Project?, hours: Int) : DialogWrapper(project) {
    private val spinner = JBIntSpinner(hours.coerceIn(1, MAX_HOURS), 1, MAX_HOURS)
    private val trialNote = JBLabel(
        "During the free trial a session lasts at most $TRIAL_MAX_HOURS hours; a longer one needs the full version.",
    ).apply { componentStyle = UIUtil.ComponentStyle.SMALL; foreground = UIUtil.getContextHelpForeground() }

    init {
        title = "Keep Mac Awake"
        setOKButtonText("Start")
        spinner.addChangeListener { updateNote() }
        updateNote()
        init()
    }

    val hours: Int get() = spinner.number

    private fun updateNote() {
        trialNote.isVisible = spinner.number > TRIAL_MAX_HOURS
    }

    override fun getPreferredFocusedComponent(): JComponent = spinner

    override fun createCenterPanel(): JComponent = FormBuilder.createFormBuilder()
        .addComponent(JBLabel("Keep this Mac awake, also with the lid closed, for:"))
        .addLabeledComponent("Hours:", spinner)
        .addComponent(trialNote)
        .addComponent(
            JBLabel("The session ends by itself after these hours, or with Stop.").apply {
                componentStyle = UIUtil.ComponentStyle.SMALL
                foreground = UIUtil.getContextHelpForeground()
            },
        )
        .panel
}
