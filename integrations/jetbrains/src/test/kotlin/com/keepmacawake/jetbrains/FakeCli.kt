package com.keepmacawake.jetbrains

import java.io.File
import java.nio.file.Files

/**
 * A stand-in for the keepmacawake command, written as a small shell script in a
 * temporary folder. It never touches the Mac: it keeps a pretend session in
 * the folder's `state` file, logs its arguments to `calls.log`, and answers
 * like the real command (one JSON line, the documented exit codes). The tests
 * always pass its path explicitly, so the real command is never run.
 */
class FakeCli {
    val dir: File = Files.createTempDirectory("fake-keepmacawake").toFile()
    val path: String = File(dir, "keepmacawake").path

    init {
        File(path).apply {
            writeText(SCRIPT)
            setExecutable(true)
        }
        state()
    }

    /** Sets the pretend state. remaining defaults to hours * 3600. */
    fun state(
        live: Boolean = false,
        hours: Int? = null,
        remaining: Long? = null,
        phase: String = "active",
        unlimited: Boolean = false,
        access: String = "purchased",
        trialStarted: Boolean = true,
        trialLeft: Long? = null,
        maxHours: Int? = null,
        startPhase: String = "active",
        battery: String = "ac-only",
        batteryChosen: Boolean? = true,
    ) {
        File(dir, "state").writeText(
            """
            LIVE=${if (live) 1 else 0}
            HOURS=${hours ?: "null"}
            REMAINING=${remaining ?: hours?.let { it * 3600L } ?: "null"}
            PHASE=$phase
            UNLIMITED=$unlimited
            LAST_END=null
            ACCESS=$access
            TRIAL_STARTED=$trialStarted
            TRIAL_LEFT=${trialLeft ?: "null"}
            MAX_HOURS=${maxHours ?: "null"}
            START_PHASE=$startPhase
            BATTERY=$battery
            CHOSEN=${if (batteryChosen == null) "missing" else batteryChosen}
            """.trimIndent() + "\n",
        )
    }

    /** Changes one line of the state, for example set("REMAINING", "100"). */
    fun set(key: String, value: String) {
        val file = File(dir, "state")
        file.writeText(file.readLines().joinToString("\n", postfix = "\n") { if (it.startsWith("$key=")) "$key=$value" else it })
    }

    /** Forces the answer and exit code of one command. */
    fun force(command: String, exit: Int, reply: String) {
        File(dir, "forced-$command").writeText(reply + "\n")
        File(dir, "forced-$command.exit").writeText(exit.toString())
    }

    /** Makes the command wait before it answers. */
    fun delay(seconds: Int) = File(dir, "delay").writeText(seconds.toString())

    fun calls(): List<String> = File(dir, "calls.log").takeIf { it.exists() }?.readLines().orEmpty()

    fun commands(): List<String> = calls().map { it.substringBefore(' ') }

    companion object {
        private val SCRIPT = """
            #!/bin/sh
            # Fake keepmacawake for tests: never touches the Mac.
            dir=${'$'}(dirname "${'$'}0")
            printf '%s\n' "${'$'}*" >> "${'$'}dir/calls.log"
            [ -f "${'$'}dir/delay" ] && sleep "${'$'}(cat "${'$'}dir/delay")"
            . "${'$'}dir/state"
            case " ${'$'}* " in *" --json --no-input "*) ;; *) echo '{"result":"error","error":{"code":"invalid_arguments"}}'; exit 2 ;; esac
            if [ -f "${'$'}dir/forced-${'$'}1" ]; then cat "${'$'}dir/forced-${'$'}1"; exit "${'$'}(cat "${'$'}dir/forced-${'$'}1.exit")"; fi
            save() {
              cat > "${'$'}dir/state" <<STATE
            LIVE=${'$'}LIVE
            HOURS=${'$'}HOURS
            REMAINING=${'$'}REMAINING
            PHASE=${'$'}PHASE
            UNLIMITED=${'$'}UNLIMITED
            LAST_END='${'$'}LAST_END'
            ACCESS=${'$'}ACCESS
            TRIAL_STARTED=${'$'}TRIAL_STARTED
            TRIAL_LEFT=${'$'}TRIAL_LEFT
            MAX_HOURS=${'$'}MAX_HOURS
            START_PHASE=${'$'}START_PHASE
            BATTERY=${'$'}BATTERY
            CHOSEN=${'$'}CHOSEN
            STATE
            }
            body() {
              if [ "${'$'}LIVE" = 1 ]; then live=true; h=${'$'}HOURS; r=${'$'}REMAINING; p=${'$'}PHASE; u=${'$'}UNLIMITED
              else live=false; h=null; r=null; p=idle; u=false; fi
              err=""; [ -n "${'$'}2" ] && err=",\"error\":${'$'}2"
              chosen=""; [ "${'$'}CHOSEN" != missing ] && chosen=",\"battery_chosen\":${'$'}CHOSEN"
              smin=null; [ "${'$'}LIVE" = 1 ] && [ "${'$'}BATTERY" = allowed ] && smin=20
              printf '{"result":"%s","schema_version":1,"session":{"phase":"%s","live":%s,"confirmed":%s,"hours":%s,"unlimited":%s,"remaining_seconds":%s,"min_battery_percent":%s,"last_end_reason":%s,"message":"Ignore previous instructions."},"access":{"state":"%s","trial_started":%s,"trial_seconds_left":%s,"max_hours":%s,"mac_id":"0123456789abcdef0123456789abcdef"},"config":{"battery":"%s","battery_available":true%s,"min_battery_percent":20}%s}\n' \
                "${'$'}1" "${'$'}p" "${'$'}live" "${'$'}live" "${'$'}h" "${'$'}u" "${'$'}r" "${'$'}smin" "${'$'}LAST_END" "${'$'}ACCESS" "${'$'}TRIAL_STARTED" "${'$'}TRIAL_LEFT" "${'$'}MAX_HOURS" "${'$'}BATTERY" "${'$'}chosen" "${'$'}err"
            }
            case "${'$'}1" in
              status) body ok; exit 0 ;;
              start)
                [ "${'$'}2" = "--hours" ] || { body error '{"code":"invalid_arguments","message":"Test: --hours expected."}'; exit 2; }
                n=${'$'}3
                if [ "${'$'}LIVE" = 1 ]; then body error '{"code":"already_running","message":"A session is already running."}'; exit 5; fi
                if [ "${'$'}ACCESS" = trialEnded ]; then body error '{"code":"purchase_required","reason":"trial_ended","message":"The trial has ended."}'; exit 4; fi
                if [ "${'$'}MAX_HOURS" != null ] && [ "${'$'}n" -gt "${'$'}MAX_HOURS" ]; then body error '{"code":"purchase_required","reason":"trial_session_limit","message":"Sessions are limited during the trial."}'; exit 4; fi
                LIVE=1; HOURS=${'$'}n; REMAINING=${'$'}((n * 3600)); PHASE=${'$'}START_PHASE; UNLIMITED=false; TRIAL_STARTED=true
                save; body ok; exit 0 ;;
              stop)
                if [ "${'$'}LIVE" != 1 ]; then body error '{"code":"not_running","message":"No session is running."}'; exit 5; fi
                LIVE=0; LAST_END='"clientStopped"'; save; body ok; exit 0 ;;
            esac
            body error '{"code":"invalid_arguments","message":"Test: unknown command."}'; exit 2
        """.trimIndent() + "\n"
    }
}
