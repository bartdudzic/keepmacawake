package com.keepmacawake.jetbrains

import kotlin.math.abs

const val DEFAULT_HOURS = 8
const val MAX_HOURS = 168
const val TRIAL_MAX_HOURS = 8
const val WEBSITE_URL =
    "https://keepmacawake.com/?utm_source=jetbrains-marketplace&utm_medium=referral&utm_campaign=integrations&utm_content=not-installed"

/** What a notification offers besides its text. */
sealed interface NoteAction {
    /** Opens the Keep Mac Awake website. */
    data object OpenWebsite : NoteAction

    /**
     * Starts a session of [hours] hours, as the Start action would. [batteryConfirmed] is the
     * user's yes to a session that may run on battery while Run on battery turned itself on.
     */
    data class StartHours(val hours: Int, val batteryConfirmed: Boolean = false) : NoteAction
}

data class Note(val text: String, val warning: Boolean = false, val actions: List<NoteAction> = emptyList())

/**
 * Everything the plugin does, without the IDE: the IDE layer calls these
 * methods on one background thread, one at a time, and shows the notes.
 *
 * Ownership. The keepmacawake command has no session id, so the plugin
 * remembers the session it started in this IDE process (its hours and the time
 * it ends) and treats a running session as its own only while both still match
 * (the end time within [endToleranceSeconds]). Stop ends only such a session;
 * any other session (started from the menu bar, a terminal, an agent or another
 * IDE, or one that replaced the plugin's) is left running, and the user is told
 * to stop it from the menu bar. The run hold ends only a session the hold
 * itself started.
 *
 * Battery. Since Keep Mac Awake 1.0.11, Run on battery turns itself on at 20% on a
 * MacBook on battery unless the user set it (`config.battery_chosen` false). The
 * plugin never changes that setting, and it never starts a session that may run on
 * battery that way without the user's yes: Start asks first, and the run hold starts
 * nothing until the user has said yes once in this IDE process (or set the setting).
 */
class KeepMacAwakeController(
    private val cli: KeepMacAwakeCli,
    private val isMac: Boolean,
    private val clock: () -> Long = { System.currentTimeMillis() / 1000 },
    private val notify: (Note) -> Unit,
    private val endToleranceSeconds: Long = 60,
) {
    enum class Origin { START_ACTION, RUN_HOLD }

    data class Claim(val hours: Int, val endsAt: Long, val origin: Origin)

    @Volatile
    var claim: Claim? = null
        private set

    /** The user said yes to a session on battery while Run on battery turned itself on; kept until the IDE quits. */
    @Volatile
    var batteryAgreed = false
        private set

    private val activeRuns = LinkedHashSet<Any>()
    private val saidOnce = HashSet<String>()

    // Notes

    private fun tell(text: String, warning: Boolean = false, actions: List<NoteAction> = emptyList(), onceKey: String? = null) {
        if (onceKey != null && !saidOnce.add(onceKey)) return
        notify(Note(text, warning, actions))
    }

    private fun notMac() = tell(NOT_MAC)

    private fun notInstalled(onceKey: String? = null) =
        tell(NOT_INSTALLED, warning = true, actions = listOf(NoteAction.OpenWebsite), onceKey = onceKey)

    /** Explains why a command did not work. */
    private fun explain(run: CliResult, action: String, onceKey: String? = null, batteryConfirmed: Boolean = false) {
        if (run.missing) return notInstalled(onceKey?.let { "missing" })
        val code = errorField(run.reply, "code")
        val key = onceKey?.let { "$it-${run.exitCode}-$code" }
        when {
            run.exitCode == 4 && code == "purchase_required" &&
                errorField(run.reply, "reason") == "trial_session_limit" -> {
                val max = KmaState.from(run.reply).maxHours ?: TRIAL_MAX_HOURS
                tell(
                    "During the free trial a Keep Mac Awake session lasts at most $max hours.",
                    warning = true,
                    actions = listOf(NoteAction.StartHours(max, batteryConfirmed)),
                    onceKey = key,
                )
            }
            run.exitCode == 4 && code == "purchase_required" -> tell(TRIAL_ENDED, warning = true, onceKey = key)
            run.exitCode == 4 && code == "run_as_user" -> tell(SUDO, warning = true, onceKey = key)
            run.exitCode == 4 -> {
                val said = appMessage(run.reply)
                val battery = if (KmaState.from(run.reply).batteryAvailable) {
                    " Battery use is your choice in the Keep Mac Awake menu bar panel."
                } else ""
                tell(
                    "Keep Mac Awake needs you before it can keep this Mac awake${if (said != null) ": \"$said\"" else "."}$battery",
                    warning = true,
                    onceKey = key,
                )
            }
            run.exitCode == 6 && code == "not_installed" -> notInstalled(onceKey?.let { "missing" })
            run.exitCode == 6 -> tell(SERVICE_DOWN, warning = true, onceKey = key)
            run.exitCode == 7 -> tell(TIMEOUT, warning = true, onceKey = key)
            else -> tell("Keep Mac Awake could not $action (exit code ${run.exitCode}).", warning = true, onceKey = key)
        }
    }

    // Ownership

    private fun remember(state: KmaState, hours: Int, origin: Origin) {
        val remaining = state.remainingSeconds ?: hours * 3600L
        claim = Claim(hours, clock() + remaining, origin)
    }

    /** True when [state] shows the session this plugin started; otherwise the claim is dropped. */
    private fun owns(state: KmaState): Boolean {
        val held = claim ?: return false
        val remaining = state.remainingSeconds
        val matches = state.running && !state.unlimited && state.hours == held.hours &&
            remaining != null && abs(clock() + remaining - held.endsAt) <= endToleranceSeconds
        if (!matches) claim = null
        return matches
    }

    // Commands

    private fun status(onceKey: String? = null): KmaState? {
        val run = cli.run("status")
        if (run.missing || run.exitCode != 0 || run.reply == null) {
            explain(run, "read its status", onceKey)
            return null
        }
        return KmaState.from(run.reply)
    }

    /**
     * The Start action: a session of [hours] hours now, also with the lid closed. When Run on
     * battery turned itself on and the user has not chosen it, it asks first (a notification
     * with a Start anyway button) unless [batteryConfirmed] carries that yes.
     */
    fun start(hours: Int, batteryConfirmed: Boolean = false) {
        if (!isMac) return notMac()
        if (hours !in 1..MAX_HOURS) return tell("Give whole hours from 1 to $MAX_HOURS.", warning = true)
        val state = status() ?: return
        if (state.running) return tell(ALREADY_RUNNING)
        val needsYes = state.batteryNotChosen
        if (needsYes && !batteryConfirmed && !batteryAgreed) {
            return tell(
                batteryQuestion(state.batteryFloor),
                warning = true,
                actions = listOf(NoteAction.StartHours(hours, batteryConfirmed = true)),
            )
        }
        val run = cli.run("start", "--hours", hours.toString())
        if (!run.missing && run.exitCode == 0) {
            val started = KmaState.from(run.reply)
            if (needsYes) batteryAgreed = true
            remember(started, hours, Origin.START_ACTION)
            if (started.phase == "waitingForAC") return tell(WAITING_FOR_AC, warning = true)
            val battery = started.sessionMinBatteryPercent?.let {
                " When this Mac is unplugged, it runs on battery down to $it%."
            }.orEmpty()
            tell(
                "Keep Mac Awake keeps this Mac awake for $hours ${plural(hours)}, also with the lid closed.$battery " +
                    "It ends by itself after that, or with Stop.",
            )
            return tell(VENTILATION, onceKey = "ventilation")
        }
        if (!run.missing && run.exitCode == 5) return tell(ALREADY_RUNNING)
        explain(run, "start a session", batteryConfirmed = batteryConfirmed)
    }

    /** The Stop action: ends the session only when this plugin started it. */
    fun stop() {
        if (!isMac) return notMac()
        val state = status() ?: return
        if (!state.running) {
            claim = null
            return tell(NOT_RUNNING)
        }
        if (!owns(state)) return tell(NOT_OURS)
        val run = cli.run("stop")
        // A failed or timed-out stop may leave the session running: the claim stays, and the
        // next status drops it if the session has ended or was replaced.
        when {
            !run.missing && run.exitCode == 0 -> { claim = null; tell(ENDED) }
            !run.missing && run.exitCode == 5 -> { claim = null; tell(NOT_RUNNING) }
            else -> explain(run, "end the session")
        }
    }

    /** The Status action. [holdDuringRuns] adds a line about the run hold. */
    fun showStatus(holdDuringRuns: Boolean, holdHours: Int) {
        if (!isMac) return notMac()
        val state = status() ?: return
        val session = when {
            state.problem -> PROBLEM
            !state.running -> NOT_RUNNING
            state.phase == "waitingForAC" -> "A Keep Mac Awake session is waiting for AC power."
            state.unlimited -> "A Keep Mac Awake session is running without a time limit."
            state.remainingSeconds != null -> "A Keep Mac Awake session is running, ${formatDuration(state.remainingSeconds)} left."
            else -> "A Keep Mac Awake session is running."
        }
        val owner = when {
            !state.running -> ""
            owns(state) -> " This IDE started it, so Stop can end it."
            else -> " It was not started from this IDE: stop it from the Keep Mac Awake menu bar panel."
        }
        val trial = when {
            state.accessState == "trialEnded" -> " The free trial on this Mac has ended."
            state.accessState != "trial" -> ""
            state.trialStarted == true && state.trialSecondsLeft != null ->
                " Free trial: ${formatDuration(state.trialSecondsLeft)} left."
            else -> " The free trial starts with the first session."
        }
        val battery = if (!state.running && state.batteryNotChosen) {
            " Run on battery turned itself on in Keep Mac Awake, and you have not chosen it: when this Mac is " +
                "unplugged, a session would run on battery down to ${state.batteryFloor}%, so Start asks you first."
        } else ""
        val hold = if (holdDuringRuns) {
            " While a run configuration runs, this IDE keeps the Mac awake for up to $holdHours ${plural(holdHours)}."
        } else ""
        tell(session + owner + trial + battery + hold, warning = state.problem)
    }

    // The run hold

    /** A run configuration started. Starts a session of [capHours] at most when none is running. */
    fun runStarted(run: Any, capHours: Int) {
        if (!isMac) return
        val first = activeRuns.isEmpty()
        activeRuns.add(run)
        if (!first) return
        val state = status(onceKey = "hold") ?: return
        if (state.running) {
            owns(state) // keeps the claim only while it still matches
            return
        }
        if (state.problem) return tell(PROBLEM, warning = true, onceKey = "hold-problem")
        if (state.accessState == "trialEnded") return tell(TRIAL_ENDED, warning = true, onceKey = "hold-trial-ended")
        // The first session on a Mac starts the free trial: that step is the user's.
        if (state.accessState == "trial" && state.trialStarted == false) {
            return tell(FIRST_SESSION, onceKey = "hold-first-session")
        }
        // Battery use needs the user's yes; the app's battery default is not one. A yes in Start is.
        if (state.batteryNotChosen && !batteryAgreed) {
            return tell(batteryHold(state.batteryFloor), onceKey = "hold-battery")
        }
        val hours = minOf(capHours.coerceIn(1, MAX_HOURS), state.maxHours ?: MAX_HOURS)
        val started = cli.run("start", "--hours", hours.toString())
        if (!started.missing && started.exitCode == 0) {
            val now = KmaState.from(started.reply)
            remember(now, hours, Origin.RUN_HOLD)
            if (now.phase == "waitingForAC") return tell(WAITING_FOR_AC, warning = true, onceKey = "hold-ac")
            return tell(
                "Keep Mac Awake keeps this Mac awake while the run goes on, also with the lid closed, for up to " +
                    "$hours ${plural(hours)}. The session ends when the run ends. $VENTILATION",
                onceKey = "hold-first",
            )
        }
        if (!started.missing && started.exitCode == 5) return // started elsewhere a moment ago: not ours
        explain(started, "start a session", onceKey = "hold")
    }

    /** A run configuration ended. When no run is left, ends the session the hold started, if it is still that one. */
    fun runEnded(run: Any) {
        if (!activeRuns.remove(run) || activeRuns.isNotEmpty()) return
        if (claim?.origin != Origin.RUN_HOLD || !isMac) return
        val state = status(onceKey = "hold") ?: return
        if (!state.running) {
            claim = null
            return
        }
        if (!owns(state)) return // replaced or started elsewhere: left running
        val stopped = cli.run("stop")
        if (!stopped.missing && (stopped.exitCode == 0 || stopped.exitCode == 5)) {
            claim = null
        } else {
            // The session may still run: the claim stays, so Stop can end it later.
            explain(stopped, "end the session", onceKey = "hold")
        }
    }

    /** The IDE is closing: a session the hold started for a run still going on ends with it. */
    fun ideClosing() {
        if (activeRuns.isEmpty()) return
        activeRuns.clear()
        if (claim?.origin != Origin.RUN_HOLD || !isMac) return
        val state = KmaState.from(cli.run("status").reply)
        if (state.running && owns(state)) cli.run("stop")
        claim = null
    }

    val runsInProgress: Int get() = activeRuns.size

    companion object {
        const val NOT_MAC =
            "Keep Mac Awake works only on a Mac with Apple silicon and macOS 26 or later, through the Keep Mac Awake " +
                "app. This plugin does nothing on this computer."
        const val NOT_INSTALLED =
            "Keep Mac Awake is not installed: this plugin needs the Keep Mac Awake app (any Mac with Apple silicon, " +
                "macOS 26 or later; free trial) and its keepmacawake command. The plugin never installs anything itself."
        const val TRIAL_ENDED =
            "The Keep Mac Awake free trial on this Mac has ended. The full version is in the Keep Mac Awake menu bar panel."
        const val FIRST_SESSION =
            "Keep Mac Awake is installed, but no session has run on this Mac yet, and the first one starts its free " +
                "trial. The plugin leaves that step to you: use Start, or start a session from the menu bar panel. " +
                "After that, runs keep this Mac awake."
        const val NOT_OURS =
            "This Keep Mac Awake session was not started from this IDE, so the plugin leaves it running. Stop it " +
                "from the Keep Mac Awake menu bar panel."
        const val VENTILATION = "Keep a closed Mac ventilated: never in a bag or on a soft surface."
        const val WAITING_FOR_AC = "Keep Mac Awake waits for AC power: plug in this Mac to keep it awake."
        const val SERVICE_DOWN =
            "Keep Mac Awake is installed, but its background service did not answer. Open Keep Mac Awake from Applications."
        const val TIMEOUT = "Keep Mac Awake did not answer in time. Status shows whether the request went through."
        const val PROBLEM = "Keep Mac Awake reports a problem. Open its menu bar panel."
        const val SUDO = "The keepmacawake command must run as the logged-in user, never with sudo."
        const val NOT_RUNNING = "No Keep Mac Awake session is running; this Mac sleeps as usual."
        const val ENDED = "The Keep Mac Awake session has ended, and normal sleep returns."
        const val ALREADY_RUNNING = "A Keep Mac Awake session is already running. Status shows its time left."

        /** Start asks before a session that may run on battery while Run on battery turned itself on. */
        fun batteryQuestion(floor: Int) =
            "Run on battery in Keep Mac Awake turned itself on, and you have not chosen it yet: when this Mac is " +
                "unplugged, this session would run on battery down to $floor%. Start it anyway, or plug in first. " +
                BATTERY_HOW_TO

        /** The run hold starts nothing while Run on battery turned itself on and the user has not said yes. */
        fun batteryHold(floor: Int) =
            "Run on battery in Keep Mac Awake turned itself on, and you have not chosen it yet, so runs start no " +
                "session: when this Mac is unplugged, a session would run on battery down to $floor%. Use Start to " +
                "start one anyway; runs then keep this Mac awake until the IDE quits. " + BATTERY_HOW_TO

        private const val BATTERY_HOW_TO =
            "To decide for good, set it yourself: keepmacawake config set --battery allowed in Terminal keeps " +
                "battery use, and turning Run on battery off in the Keep Mac Awake menu bar panel keeps sessions on " +
                "AC power. The plugin never changes this setting."

        fun plural(hours: Int) = if (hours == 1) "hour" else "hours"

        /** Seconds as "2 d 5 h", "3 h 10 min" or "40 min". */
        fun formatDuration(seconds: Long): String {
            val minutes = maxOf(0L, Math.round(seconds / 60.0))
            val days = minutes / 1440
            val hours = (minutes % 1440) / 60
            val rest = minutes % 60
            return when {
                days > 0 -> "$days d $hours h"
                hours > 0 -> "$hours h $rest min"
                else -> "$rest min"
            }
        }
    }
}
