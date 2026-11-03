-- Tests KeepMacAwake.spoon with a fake `hs`: hs.task never starts a process,
-- it records the arguments and answers like the keepmacawake command.
-- Run: lua test.lua (Lua 5.4, as in Hammerspoon).
local tasks, alerts, failures = {}, {}, 0
local answer = { code = 0, out = "Awake: keeping this Mac awake, 8 h left.\n", err = "" }
local installed = true
local bound

hs = {
    fs = { attributes = function(path) return installed and { mode = "file" } or nil end },
    alert = { show = function(text) table.insert(alerts, text) end },
    task = {
        new = function(path, callback, args)
            local task = { path = path, args = args }
            function task:start()
                table.insert(tasks, self)
                callback(answer.code, answer.out, answer.err)
                return self
            end
            return task
        end,
    },
    spoons = { bindHotkeysToSpec = function(actions, mapping) bound = { actions = actions, mapping = mapping } end },
}

local function check(name, condition, detail)
    if not condition then
        failures = failures + 1
        print("FAIL: " .. name .. (detail and (": " .. detail) or ""))
    end
end
local function lastArgs() return tasks[#tasks] and table.concat(tasks[#tasks].args, " ") or "" end

local spoon = dofile("KeepMacAwake.spoon/init.lua")
check("metadata", spoon.name == "KeepMacAwake" and spoon.license:match("^MIT"))

spoon:start()
check("start default", lastArgs() == "start --hours 8 --no-input", lastArgs())
check("path", tasks[#tasks].path == "/usr/local/bin/keepmacawake")
check("alert", alerts[#alerts] == "Awake: keeping this Mac awake, 8 h left.", alerts[#alerts])
spoon:start(3)
check("start 3", lastArgs() == "start --hours 3 --no-input", lastArgs())
spoon:start("unlimited")
check("unlimited", lastArgs() == "start --unlimited --no-input", lastArgs())
local count = #tasks
for _, bad in ipairs({ 0, 169, 2.5, "8; rm -rf ~", -1 }) do spoon:start(bad) end
check("refused hours run nothing", #tasks == count, tostring(#tasks - count))
check("refused hours alert", alerts[#alerts] == "Pick 1 to 168 hours.")
spoon:stop()
check("stop", lastArgs() == "stop --no-input", lastArgs())
spoon:status()
check("status", lastArgs() == "status --no-input", lastArgs())

answer = { code = 4, out = "", err = "Error: AC power is needed.\n" }
local gotCode, gotMessage
spoon:start(2, function(code, message) gotCode, gotMessage = code, message end)
check("refusal shown", alerts[#alerts] == "Error: AC power is needed.", alerts[#alerts])
check("callback", gotCode == 4 and gotMessage == "Error: AC power is needed.")
answer = { code = 5, out = "", err = "" }
spoon:stop()
check("empty answer", alerts[#alerts]:match("exit code 5") ~= nil, alerts[#alerts])

installed = false
count = #tasks
spoon:start()
check("not installed runs nothing", #tasks == count)
check("not installed alert", alerts[#alerts]:match("free trial") ~= nil, alerts[#alerts])
installed = true

spoon:bindHotkeys({ start = { { "cmd", "alt" }, "A" } })
check("hotkeys", bound and bound.mapping.start and bound.actions.start and bound.actions.startUnlimited and bound.actions.stop and bound.actions.status)
bound.actions.startUnlimited()
check("hotkey action", lastArgs() == "start --unlimited --no-input", lastArgs())

if failures > 0 then
    print(failures .. " test(s) failed.")
    os.exit(1)
end
print("All Hammerspoon Spoon tests passed.")
