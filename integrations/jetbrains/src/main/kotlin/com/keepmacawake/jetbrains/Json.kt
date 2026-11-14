package com.keepmacawake.jetbrains

/**
 * A small JSON reader for the one-line answers of `keepmacawake --json`, so the
 * plugin needs no library beyond the IntelliJ Platform. Objects become maps,
 * arrays lists, numbers Long or Double; anything malformed gives null.
 */
object Json {
    fun parse(text: String): Any? = try {
        val reader = Reader(text)
        reader.skipSpace()
        val value = reader.value()
        reader.skipSpace()
        if (reader.atEnd()) value else null
    } catch (_: IllegalArgumentException) {
        null
    }

    private class Reader(private val text: String) {
        private var index = 0
        private var depth = 0

        fun atEnd() = index >= text.length

        fun skipSpace() {
            while (!atEnd() && text[index] in " \t\r\n") index++
        }

        private fun fail(): Nothing = throw IllegalArgumentException("Malformed JSON at $index")

        private fun expect(word: String) {
            if (!text.startsWith(word, index)) fail()
            index += word.length
        }

        fun value(): Any? {
            if (atEnd()) fail()
            return when (text[index]) {
                '{' -> nested { obj() }
                '[' -> nested { array() }
                '"' -> string()
                't' -> { expect("true"); true }
                'f' -> { expect("false"); false }
                'n' -> { expect("null"); null }
                else -> number()
            }
        }

        private fun <T> nested(read: () -> T): T {
            if (++depth > 64) fail()
            return read().also { depth-- }
        }

        private fun obj(): Map<String, Any?> {
            val map = LinkedHashMap<String, Any?>()
            index++
            skipSpace()
            if (!atEnd() && text[index] == '}') { index++; return map }
            while (true) {
                skipSpace()
                if (atEnd() || text[index] != '"') fail()
                val key = string()
                skipSpace()
                expect(":")
                skipSpace()
                map[key] = value()
                skipSpace()
                if (atEnd()) fail()
                when (text[index++]) {
                    ',' -> continue
                    '}' -> return map
                    else -> fail()
                }
            }
        }

        private fun array(): List<Any?> {
            val list = ArrayList<Any?>()
            index++
            skipSpace()
            if (!atEnd() && text[index] == ']') { index++; return list }
            while (true) {
                skipSpace()
                list.add(value())
                skipSpace()
                if (atEnd()) fail()
                when (text[index++]) {
                    ',' -> continue
                    ']' -> return list
                    else -> fail()
                }
            }
        }

        private fun string(): String {
            val out = StringBuilder()
            index++
            while (true) {
                if (atEnd()) fail()
                val c = text[index++]
                when {
                    c == '"' -> return out.toString()
                    c == '\\' -> {
                        if (atEnd()) fail()
                        when (val e = text[index++]) {
                            '"', '\\', '/' -> out.append(e)
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000c')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (index + 4 > text.length) fail()
                                val code = text.substring(index, index + 4).toIntOrNull(16) ?: fail()
                                out.append(code.toChar())
                                index += 4
                            }
                            else -> fail()
                        }
                    }
                    c < ' ' -> fail()
                    else -> out.append(c)
                }
            }
        }

        private fun number(): Any {
            val start = index
            if (!atEnd() && text[index] == '-') index++
            while (!atEnd() && (text[index].isDigit() || text[index] in ".eE+-")) index++
            val token = text.substring(start, index)
            if (token.isEmpty() || token == "-") fail()
            return token.toLongOrNull() ?: token.toDoubleOrNull() ?: fail()
        }
    }
}
