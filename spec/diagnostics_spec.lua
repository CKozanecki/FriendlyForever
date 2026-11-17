-- Spec: #101, #46, #47, #392, #406, #431
local wow = require("spec.support.wow")

describe("Diagnostics", function()
    local ns

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    local function logHas(fragment)
        for _, line in ipairs(ns.db.diagLog) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    local function printedHas(fragment)
        for _, line in ipairs(wow.printed) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    local function online(name)
        wow.systemMessage("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
    end

    before_each(function()
        ns = wow.boot({ before = function(state) state.guildRoster = { "Thrall" } end })
        wow.fire("GUILD_ROSTER_UPDATE")
    end)

    describe("debug mode", function()
        it("is off by default and logs nothing", function()
            assert.is_false(ns.db.debug)
            online("Thrall")
            wow.advance(10)
            assert.are.same({}, ns.db.diagLog)
        end)

        it("/friendly debug turns it on and off", function()
            slash("debug")
            assert.is_true(ns.db.debug)
            assert.is_true(logHas("debug: started; version " .. ns.VERSION))
            slash("debug")
            assert.is_false(ns.db.debug)
        end)

        it("logs the whole path of a greeting, from system message to send", function()
            slash("debug")
            online("Thrall")
            wow.advance(30)
            assert.is_true(logHas("system: ||Hplayer:Thrall||h[Thrall]||h has come online. -> guildOnline Thrall"))
            local wait -- 15 s and the random wait (#38, #392)
            for _, line in ipairs(ns.db.diagLog) do
                wait = wait or tonumber(line:match("guildLogin: scheduled for Thrall in (%d+)s"))
            end
            assert.is_true(wait ~= nil and wait >= 16 and wait <= 23, tostring(wait))
            assert.is_true(logHas("guildLogin: announced greeting Thrall with line 1"))
            assert.is_true(logHas("send: queued guildLogin for Thrall"))
            assert.is_true(logHas("send: sent guildLogin for Thrall to GUILD: Thrall has logged in. Quick, everyone look busy."))
        end)

        it("logs unrecognised system messages so their real format can be seen", function()
            slash("debug")
            wow.systemMessage("Something new happened.")
            assert.is_true(logHas("system: Something new happened. -> not recognised"))
        end)

        it("logs why nothing was sent", function()
            slash("debug")
            ns.db.guildLogin.enabled = false
            online("Thrall")
            assert.is_true(logHas("guildLogin: not sending for Thrall: this message type is switched off"))
            ns.db.guildLogin.enabled = true
            online("Stranger")
            wow.fire("GUILD_ROSTER_UPDATE")
            -- Said when the wait for the roster runs out, not on the first update.
            assert.is_false(logHas("Stranger is not in the guild roster"))
            wow.advance(ns.Greeter.PENDING_TIMEOUT)
            assert.is_true(logHas("Stranger is not in the guild roster (a friend?)"))
        end)

        it("logs events ignored during the login grace period", function()
            ns = wow.boot({ noGrace = true, db = { debug = true } })
            wow.systemMessage("Bob joins the party.")
            assert.is_true(logHas("partyJoin: ignored: login grace period"))
        end)

        it("logs each buff with its caster decision", function()
            slash("debug")
            wow.state.groupType = "party"
            wow.gainBuff({ name = "Strength of Earth", spellId = 8076 })
            assert.is_true(logHas("buff: Strength of Earth (spell 8076): no caster unit, and you're in a group"))
            assert.is_true(logHas("-> skip"))
        end)

        it("logs why an unidentified caster isn't thanked", function()
            slash("debug")
            ns.db.buff.fallback = "none"
            wow.gainBuff({ name = "Fort" })
            assert.is_true(logHas("not thanking: caster can't be named, and no fallback is chosen"))
        end)

        it("logs buffs merged into a waiting thank-you", function()
            slash("debug")
            wow.gainBuff({ name = "Fort" })
            wow.gainBuff({ name = "Renew" })
            assert.is_true(logHas("added to the thank-you already waiting for ?unknown"))
        end)

        it("logs messages held for a key press or lockdown", function()
            slash("debug")
            wow.addUnit("target", { name = "Bob" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.1)
            assert.is_true(logHas("holding buff for Bob: SAY outdoors needs a key press"))
        end)

        it("captures the game's error text when a send fails", function()
            slash("debug")
            _G.C_ChatInfo.SendChatMessage = function() error("Invalid chat type") end
            online("Thrall")
            wow.advance(30)
            assert.is_true(logHas("ERROR sending guildLogin for Thrall to GUILD"))
            assert.is_true(logHas("Invalid chat type"))
            assert.are.equal(1, ns.Diag.Counters().sendErrors)
        end)

        it("never touches secret values, and shows | literally", function()
            slash("debug")
            ns.Diag.Log("x", "value %s and %s", wow.secret("hidden"), "a|cffb")
            assert.is_true(logHas("x: value <secret> and a||cffb"))
        end)

        it("keeps only the most recent lines", function()
            slash("debug")
            for i = 1, ns.Diag.MAX_LOG + 50 do ns.Diag.Log("x", "line %s", i) end
            assert.are.equal(ns.Diag.MAX_LOG, #ns.db.diagLog)
            assert.is_true(logHas("line " .. (ns.Diag.MAX_LOG + 50)))
            assert.is_nil(ns.db.diagLog[1]:find("line 1$"), "oldest lines are dropped first")
        end)

        it("survives a reload: logging continues from the saved setting", function()
            ns = wow.boot({ db = { debug = true, diagLog = { "older line" } } })
            assert.is_true(logHas("older line"))
            assert.is_true(logHas("load: loaded " .. ns.VERSION))
        end)

        it("cleans a corrupted saved log", function()
            ns = wow.boot({ db = { debug = "yes", diagLog = { "ok", 5, {}, string.rep("x", 900) } } })
            assert.is_false(ns.db.debug)
            assert.are.equal(2, #ns.db.diagLog)
            assert.are.equal(500, #ns.db.diagLog[2])
        end)
    end)

    describe("/friendly status", function()
        it("reports state, settings, counts and APIs", function()
            online("Thrall")
            wow.advance(30)
            slash("status")
            assert.is_true(printedHas("version " .. wow.parseToc().Version))
            assert.is_true(printedHas("state: active"))
            assert.is_true(printedHas("Guild Login:"))
            assert.is_true(printedHas("guild: yes, 1 members known"))
            assert.is_true(printedHas("1 system messages (1 recognised)"))
            assert.is_true(printedHas("1 queued, 1 sent, 0 dropped, 0 send errors, 0 blocked"))
            assert.is_true(printedHas("APIs:"))
        end)

        it("says when the login event never arrived", function()
            wow.reset()
            -- Saved settings, as an install has after its first run: a new
            -- one is switched off until its walkthrough is done (#47).
            _G.FriendlyForeverDB = { walkthrough = { seen = 1, firstRun = false } }
            ns = wow.load()
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            slash("status")
            assert.is_true(printedHas("waiting for the login/reload event"))
        end)

        it("shows the chat lockdown and a waiting /say", function()
            wow.state.lockdown = true
            wow.addUnit("target", { name = "Bob" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.1)
            slash("status")
            assert.is_true(printedHas("lockdown " .. ns.Colours.Text("good", "on") .. ", 1 waiting"))
        end)

        it("shows the AFK option, and says when it is dropping messages", function()
            slash("status")
            assert.is_true(printedHas("skip while AFK: " .. ns.Colours.Text("good", "on") .. " (you're not AFK)"))
            wow.state.afk = true
            slash("status")
            assert.is_true(printedHas("skip while AFK: " .. ns.Colours.Text("good", "on") .. " (you're AFK: automatic messages are being dropped)"))
            ns.db.skipWhileAFK = false
            wow.printed = {}
            slash("status")
            assert.is_true(printedHas("skip while AFK: " .. ns.Colours.Text("bad", "off") .. " (you're AFK)"))
            assert.is_false(printedHas("being dropped"))
        end)

        it("says when it can't tell whether you're AFK", function()
            wow.state.afk, wow.state.unitsRestricted = true, true
            slash("status")
            assert.is_true(printedHas("(can't tell if you're AFK right now, so messages are sent)"))
        end)

        it("says it can't tell when the game's guild answer isn't yes or no (#406)", function()
            local real = _G.IsInGuild
            for label, answer in pairs({
                secret = function() return wow.secret(true) end,
                none = function() return nil end,
                number = function() return 1 end,
                error = function() error("boom") end,
            }) do
                _G.IsInGuild = answer
                wow.printed, wow.errors = {}, {}
                slash("status")
                assert.are.same({}, wow.errors, label)
                assert.is_true(printedHas("guild: can't tell, "), label)
            end
            _G.IsInGuild = real
        end)

        it("works outside a guild and group", function()
            wow.state.inGuild = false
            slash("status")
            assert.is_true(printedHas("guild: no"))
            assert.is_true(printedHas("none (not grouped)"))
        end)
    end)

    describe("/friendly selftest", function()
        it("whispers you through the real send path", function()
            slash("selftest")
            assert.are.equal(1, #wow.sent)
            assert.are.equal("WHISPER", wow.sent[1].channel)
            assert.are.equal("Me", wow.sent[1].target)
            assert.is_true(printedHas("self-test: " .. ns.Colours.Text("good", "sent")))
        end)

        it("waits for the chat lockdown like any message", function()
            wow.state.lockdown = true
            slash("selftest")
            assert.are.equal(0, #wow.sent)
            wow.state.lockdown = false
            wow.advance(ns.ChatQueue.RETRY_DELAY)
            assert.are.equal(1, #wow.sent)
        end)

        it("reports a failed send", function()
            _G.C_ChatInfo.SendChatMessage = function() error("nope") end
            slash("selftest")
            assert.is_true(printedHas("self-test: " .. ns.Colours.Text("bad", "not sent")))
        end)
    end)

    describe("Lua errors", function()
        it("are counted, logged and still shown by the game's error display", function()
            slash("debug")
            ns.Parser.Parse = function() error("parser exploded") end
            wow.systemMessage("anything")
            assert.are.equal(1, ns.Diag.Counters().luaErrors)
            assert.is_true(logHas("parser exploded"))
            assert.are.equal(1, #wow.errors)
        end)

        it("in a timer don't stop later messages", function()
            local realPush = ns.ChatQueue.Push
            ns.ChatQueue.Push = function() error("boom") end
            online("Thrall")
            wow.advance(30)
            assert.are.equal(1, ns.Diag.Counters().luaErrors)
            ns.ChatQueue.Push = realPush
            ns.db.guildLogin.repeatCooldown = 0
            online("Thrall")
            wow.advance(30)
            assert.are.equal(1, #wow.sent)
        end)

        it("are shown in /friendly status", function()
            ns.Parser.Parse = function() error("bad") end
            wow.systemMessage("anything")
            slash("status")
            assert.is_true(printedHas("Lua errors in this addon: 1 (last:"))
        end)
    end)

    describe("blocked actions", function()
        it("counts and reports the game blocking our calls", function()
            wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", "SendChatMessage()")
            assert.are.equal(1, ns.Diag.Counters().actionsBlocked)
            assert.is_true(printedHas("the game blocked a call to SendChatMessage()"))
        end)

        it("reports at most 3 times per session", function()
            for _ = 1, 10 do wow.fire("ADDON_ACTION_FORBIDDEN", "FriendlyForever", "X()") end
            assert.are.equal(10, ns.Diag.Counters().actionsBlocked)
            local n = 0
            for _, line in ipairs(wow.printed) do if line:find("forbidden", 1, true) then n = n + 1 end end
            assert.are.equal(3, n)
        end)

        local function optionsLines()
            local n = 0
            for _, line in ipairs(wow.printed) do
                if line:find("let the options open", 1, true) then n = n + 1 end
            end
            return n
        end

        it("tells the player how to open the options by hand when the game blocks that call (#431)", function()
            wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", "OpenSettingsPanel()")
            assert.are.equal(1, optionsLines())
            assert.is_true(printedHas("Esc, then Options, AddOns, Friendly Forever"))
            assert.is_false(printedHas("the game blocked a call to"))
            assert.are.equal(1, ns.Diag.Counters().actionsBlocked)
        end)

        it("prints the options line once for a burst, and again after the gap (#431)", function()
            for _ = 1, 50 do wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", "OpenSettingsPanel()") end
            assert.are.equal(1, optionsLines())
            assert.are.equal(50, ns.Diag.Counters().actionsBlocked)
            wow.advance(11)
            wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", "OpenSettingsPanel()")
            assert.are.equal(2, optionsLines())
        end)

        it("never retries the protected call by itself (#431)", function()
            local calls = 0
            _G.Settings.OpenToCategory = function() calls = calls + 1 end
            for _ = 1, 20 do wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", "OpenSettingsPanel()") end
            wow.advance(60)
            assert.are.equal(0, calls)
        end)

        it("handles a damaged function name or another addon or a forbidden kind without error (#431)", function()
            for _, bad in ipairs({ 42, true, {}, "", string.rep("x", 5000) }) do
                assert.has_no.errors(function() wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", bad) end)
            end
            assert.are.equal(0, optionsLines())
            wow.fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "OpenSettingsPanel()")
            wow.fire("ADDON_ACTION_FORBIDDEN", "FriendlyForever", "OpenSettingsPanel()")
            assert.are.equal(0, optionsLines())
        end)

        it("survives a storm of mixed blocked events with at most one options line per gap (#431)", function()
            math.randomseed(431)
            local funcs = { "OpenSettingsPanel()", "SendChatMessage()", "X()", "OpenSettingsPanel()" }
            local kinds = { "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }
            local opens = 0
            for _ = 1, 500 do
                local f, k = funcs[math.random(#funcs)], kinds[math.random(#kinds)]
                if f == "OpenSettingsPanel()" and k == "ADDON_ACTION_BLOCKED" then opens = opens + 1 end
                assert.has_no.errors(function() wow.fire(k, "FriendlyForever", f) end)
                if math.random() < 0.05 then wow.advance(math.random(0, 30)) end
            end
            assert.is_true(opens > 0)
            assert.is_true(optionsLines() >= 1)
            assert.is_true(optionsLines() <= opens)
            local reports = 0
            for _, line in ipairs(wow.printed) do
                if line:find("the game ", 1, true) and line:find("a call to", 1, true) then reports = reports + 1 end
            end
            assert.is_true(reports <= 3)
        end)

        it("ignores other addons being blocked", function()
            wow.fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "X()")
            assert.is_nil(ns.Diag.Counters().actionsBlocked)
            assert.are.equal(0, #wow.printed)
        end)
    end)
end)
