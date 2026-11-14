package com.keepmacawake.jetbrains

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class JsonTest {
    @Test
    fun readsTheDocumentedStatusLine() {
        val line = """{"access":{"mac_id":"0123456789abcdef0123456789abcdef","max_hours":null,"purchase":null,"state":"purchased","trial_ends_at":null,"trial_seconds_left":null,"trial_started":true},"app_version":"1.0.0","config":{"battery":"ac-only","battery_available":true,"battery_chosen":true,"min_battery_percent":20,"mute_on_lid_close":"off","update_check":"daily"},"protocol_version":"2","result":"ok","schema_version":1,"session":{"confirmed":true,"hours":8,"last_end_reason":null,"live":true,"message":"Sleep prevention is on.","min_battery_percent":null,"phase":"active","remaining_seconds":28734,"unlimited":false},"update":{"available_version":null,"current_version":"1.0.0","install_command":null}}"""
        val state = KmaState.from(KeepMacAwakeCli.parseReply("diagnostic\n$line\n"))
        assertEquals("active", state.phase)
        assertEquals(true, state.running)
        assertEquals(8, state.hours)
        assertEquals(28734L, state.remainingSeconds)
        assertEquals("purchased", state.accessState)
        assertNull(state.maxHours)
        assertEquals(false, state.batteryAllowed)
        assertEquals(true, state.batteryChosen)
        assertEquals(false, state.batteryNotChosen)
        assertEquals(20, state.batteryFloor)
    }

    @Test
    fun readsTheBatteryDefaultOf1011() {
        val line = """{"result":"ok","config":{"battery":"allowed","battery_available":true,"battery_chosen":false,"min_battery_percent":30},"session":{"phase":"idle","live":false}}"""
        val state = KmaState.from(KeepMacAwakeCli.parseReply(line))
        assertEquals(true, state.batteryNotChosen)
        assertEquals(30, state.batteryFloor)
        val desktop = """{"result":"ok","config":{"battery":"ac-only","battery_available":false,"battery_chosen":false},"session":{"phase":"idle","live":false}}"""
        assertEquals(false, KmaState.from(KeepMacAwakeCli.parseReply(desktop)).batteryNotChosen)
        val older = """{"result":"ok","config":{"battery":"allowed","battery_available":true},"session":{"phase":"idle","live":false}}"""
        assertEquals(false, KmaState.from(KeepMacAwakeCli.parseReply(older)).batteryNotChosen)
    }

    @Test
    fun readsEscapesArraysAndNumbers() {
        assertEquals(mapOf("a" to listOf(1L, -2.5, true, null), "b" to "x\"yé\n"), Json.parse("""{"a":[1,-2.5,true,null],"b":"x\"yé\n"}"""))
    }

    @Test
    fun rejectsMalformedText() {
        listOf("", "{", "{\"a\":}", "[1,]", "nul", "{\"a\":1} x", "\"\u0001\"", "[".repeat(100)).forEach {
            assertNull(Json.parse(it), it)
        }
        assertNull(KeepMacAwakeCli.parseReply("[1,2]"))
    }

    @Test
    fun resolvesTheCommandPathWithoutSearchingPath() {
        assertEquals(DEFAULT_CLI_PATH, resolveCliPath(emptyMap()))
        assertEquals("/tmp/fake", resolveCliPath(mapOf("KEEPMACAWAKE_CLI" to " /tmp/fake ")))
        assertNull(resolveCliPath(mapOf("KEEPMACAWAKE_CLI" to "")))
    }
}
