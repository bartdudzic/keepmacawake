package com.keepmacawake.jetbrains

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Where the Keep Mac Awake installer links its command. */
const val DEFAULT_CLI_PATH = "/usr/local/bin/keepmacawake"

/**
 * The command to run: the path in KEEPMACAWAKE_CLI when that variable is set
 * (also when empty, which means "none"), otherwise [DEFAULT_CLI_PATH]. The
 * plugin never searches PATH. The tests always pass their own fake command.
 */
fun resolveCliPath(env: Map<String, String> = System.getenv()): String? =
    if (env.containsKey("KEEPMACAWAKE_CLI")) env["KEEPMACAWAKE_CLI"]?.trim()?.takeIf { it.isNotEmpty() }
    else DEFAULT_CLI_PATH

/** One run of the command: [missing] when it is not there, otherwise its exit code and JSON answer. */
data class CliResult(val missing: Boolean, val exitCode: Int, val reply: Map<String, Any?>?) {
    companion object {
        val MISSING = CliResult(missing = true, exitCode = -1, reply = null)
    }
}

/**
 * Runs `keepmacawake <args> --json --no-input` at an explicit path and reads
 * its one-line JSON answer. Exit codes are the command's own (0 ok, 2 invalid
 * arguments, 4 the user is needed, 5 conflict, 6 service or app missing, 7 no
 * answer in time); 7 also when this plugin stopped waiting.
 */
class KeepMacAwakeCli(private val path: String?, private val waitSeconds: Long = 30) {
    fun run(vararg args: String): CliResult {
        val cli = path?.takeIf { it.isNotBlank() } ?: return CliResult.MISSING
        val file = File(cli)
        if (!file.isFile || !file.canExecute()) return CliResult.MISSING
        val command = listOf(cli) + args + listOf("--json", "--no-input")
        val process = try {
            ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD).start()
        } catch (_: IOException) {
            return CliResult.MISSING
        }
        process.outputStream.close()
        val output = StringBuilder()
        val reader = Thread({
            try {
                process.inputStream.bufferedReader().use { input ->
                    val buffer = CharArray(4096)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.length < MAX_OUTPUT) output.append(buffer, 0, count)
                    }
                }
            } catch (_: IOException) {
            }
        }, "keepmacawake-cli-output").apply { isDaemon = true; start() }
        if (!process.waitFor(waitSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            return CliResult(missing = false, exitCode = 7, reply = null)
        }
        reader.join(2000)
        return CliResult(missing = false, exitCode = process.exitValue(), reply = parseReply(output.toString()))
    }

    companion object {
        private const val MAX_OUTPUT = 1024 * 1024

        /** The last line of stdout as a JSON object, or null. */
        @Suppress("UNCHECKED_CAST")
        fun parseReply(stdout: String): Map<String, Any?>? {
            val line = stdout.trim().lines().lastOrNull()?.trim().orEmpty()
            if (line.isEmpty()) return null
            return Json.parse(line) as? Map<String, Any?>
        }
    }
}

/** The few fields of an answer the plugin uses. */
data class KmaState(
    val phase: String?,
    val live: Boolean,
    val unlimited: Boolean,
    val hours: Int?,
    val remainingSeconds: Long?,
    val accessState: String?,
    val trialStarted: Boolean?,
    val trialSecondsLeft: Long?,
    val maxHours: Int?,
    val batteryAvailable: Boolean,
    val batteryAllowed: Boolean = false,
    val batteryChosen: Boolean? = null,
    val minBatteryPercent: Int? = null,
    val sessionMinBatteryPercent: Int? = null,
) {
    val running: Boolean get() = live && phase in RUNNING_PHASES
    val problem: Boolean get() = phase == "failed" || phase == "unavailable"

    /**
     * Run on battery is on for the next session, but the user has not chosen it: since
     * Keep Mac Awake 1.0.11 it turns itself on for a MacBook on battery (`config.battery_chosen`
     * false). A session started now may run on battery, so the plugin asks the user first. An
     * answer without `battery_chosen` comes from an older app, where battery use was always the
     * user's choice.
     */
    val batteryNotChosen: Boolean get() = batteryAvailable && batteryAllowed && batteryChosen == false

    /** The battery level a session started now would run down to, 20% unless the app says otherwise. */
    val batteryFloor: Int get() = minBatteryPercent ?: 20

    companion object {
        val RUNNING_PHASES = setOf("starting", "active", "waitingForAC")

        fun from(reply: Map<String, Any?>?): KmaState {
            val session = reply.child("session")
            val access = reply.child("access")
            val config = reply.child("config")
            return KmaState(
                phase = session["phase"] as? String,
                live = session["live"] == true,
                unlimited = session["unlimited"] == true,
                hours = wholeNumber(session["hours"])?.toInt(),
                remainingSeconds = wholeNumber(session["remaining_seconds"]),
                accessState = access["state"] as? String,
                trialStarted = access["trial_started"] as? Boolean,
                trialSecondsLeft = wholeNumber(access["trial_seconds_left"]),
                maxHours = wholeNumber(access["max_hours"])?.toInt()?.takeIf { it > 0 },
                batteryAvailable = config["battery_available"] == true,
                batteryAllowed = config["battery"] == "allowed",
                batteryChosen = config["battery_chosen"] as? Boolean,
                minBatteryPercent = wholeNumber(config["min_battery_percent"])?.toInt()?.takeIf { it in 1..100 },
                sessionMinBatteryPercent = wholeNumber(session["min_battery_percent"])?.toInt()?.takeIf { it in 1..100 },
            )
        }

        private fun wholeNumber(value: Any?): Long? = (value as? Long)?.takeIf { it >= 0 }
    }
}

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>?.child(key: String): Map<String, Any?> =
    (this?.get(key) as? Map<String, Any?>) ?: emptyMap()

/** `error.<key>` of an answer, when it is a string. */
internal fun errorField(reply: Map<String, Any?>?, key: String): String? = reply.child("error")[key] as? String

/** The app's own error message on one line, at most 300 characters, or null. */
internal fun appMessage(reply: Map<String, Any?>?): String? =
    errorField(reply, "message")
        ?.replace(Regex("[\\u0000-\\u001f\\u007f]+"), " ")
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.take(300)
