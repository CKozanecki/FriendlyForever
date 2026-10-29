-- Spec: #35
-- The lines-per-minute cap: a hard ceiling on what the addon says in each
-- chat type, so a crowded launch can't make it spam.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

describe("The chat rate limit (#35)", function()
    local ns

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    local function boot(db)
        ns = wow.boot({ db = db, before = function(state) state.guildRoster = { "Thrall", "Jaina", "Varian" } end })
        wow.fire("GUILD_ROSTER_UPDATE")
        for _, msgType in ipairs(ns.Config.TYPES) do
            ns.db[msgType].messages = { ns.CasualMessages[msgType][1] } -- fixed wording
        end
    end

    -- Distinct strangers' names: Buffera, Bufferb, ...
    local function strangerName(i)
        return "Buffer" .. string.char(96 + (i - 1) % 26 + 1) .. string.rep("x", math.floor((i - 1) / 26))
    end

    local function buffedBy(i)
        local token = "nameplate" .. i
        wow.addUnit(token, { name = strangerName(i) })
        wow.gainBuff({ sourceUnit = token, name = "Arcane Intellect", spellId = 1459 })
    end

    local function online(name)
        wow.systemMessage("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
    end

    -- Advance the clock in small steps with a key press at each, so /say is
    -- never waiting for a key press.
    local function pressFor(seconds)
        local steps = math.floor(seconds / 0.5)
        for _ = 1, steps do
            wow.advance(0.5)
            wow.keyDown()
        end
    end

    -- The most lines the client's own record shows in any 60 seconds, for
    -- the records whose field matches.
    local function mostInAMinute(records)
        local most = 0
        for i = 1, #records do
            local n = 0
            for j = 1, #records do
                local d = records[j].time - records[i].time
                if d >= 0 and d < 60 then n = n + 1 end
            end
            if n > most then most = n end
        end
        return most
    end

    local function sentIn(channel)
        local out = {}
        for _, s in ipairs(wow.sent) do
            if s.channel == channel then out[#out + 1] = s end
        end
        return out
    end

    local function printedHas(fragment)
        for _, line in ipairs(wow.printed) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    before_each(function() boot() end)

    describe("a burst of favours (white)", function()
        it("sends at most N lines in /say per minute, and notes the rest in the ledger", function()
            local N = ns.db.linesPerMinute
            assert.are.equal(4, N, "the default cap")
            for i = 1, 20 do
                buffedBy(i)
                wow.advance(0.1)
            end
            pressFor(180)
            local say = sentIn("SAY")
            assert.are.equal(N, #say, "only N thank-yous went out")
            assert.is_true(mostInAMinute(say) <= N)
            local entries = ns.db.ledger.entries
            assert.are.equal(20, #entries)
            local thanked, capped = 0, 0
            for _, e in ipairs(entries) do
                if e.result == ns.Ledger.THANKED then thanked = thanked + 1 end
                if e.result == ns.Ledger.NOT_THANKED and e.note == "chat rate limit reached" then
                    capped = capped + 1
                end
            end
            assert.are.equal(N, thanked)
            assert.are.equal(20 - N, capped, "every other favour names the cap as the reason")
        end)

        it("drops thanks over the cap at once, rather than sending them a minute later", function()
            for i = 1, 8 do buffedBy(i) end
            pressFor(30)
            local before = #wow.sent
            assert.are.equal(ns.db.linesPerMinute, before)
            pressFor(120)
            assert.are.equal(before, #wow.sent, "nothing dropped comes back later")
            assert.are.equal(0, ns.ChatQueue.Count())
        end)

        it("follows a cap set higher or lower", function()
            ns.db.linesPerMinute = 2
            for i = 1, 8 do buffedBy(i) end
            pressFor(60)
            assert.are.equal(2, #sentIn("SAY"))
        end)

        it("counts /thank emotes against their own cap, and drops the rest", function()
            ns.db.buff.thankStyle = "emote"
            for i = 1, 10 do buffedBy(i) end
            pressFor(120)
            assert.are.equal(ns.db.linesPerMinute, #wow.emotes)
            assert.is_true(mostInAMinute(wow.emotes) <= ns.db.linesPerMinute)
            assert.are.equal(0, #wow.sent)
            local capped = 0
            for _, e in ipairs(ns.db.ledger.entries) do
                if e.note == "chat rate limit reached" then capped = capped + 1 end
            end
            assert.are.equal(10 - ns.db.linesPerMinute, capped, "dropped for the cap, not left to expire")
        end)

        it("counts whispered thanks against the whisper cap", function()
            ns.db.buff.useWhisper = true
            for i = 1, 10 do buffedBy(i) end
            pressFor(120)
            assert.are.equal(ns.db.linesPerMinute, #sentIn("WHISPER"))
        end)

        it("drops the /say fallback for a failed whisper over the cap", function()
            ns.db.buff.useWhisper = true
            ns.db.buff.messages = { "Thanks, {name}!" }
            local Q = ns.ChatQueue
            for _ = 1, Q.LinesPerMinute() do
                Q.Push({ channel = "SAY", getText = function() return "filler" end })
                pressFor(Q.MIN_INTERVAL + 0.5)
            end
            buffedBy(1)
            wow.advance(ns.db.buff.delay + 0.01)
            assert.are.equal("WHISPER", wow.sent[#wow.sent].channel)
            wow.systemMessage("No player named '" .. strangerName(1) .. "' is currently playing.")
            pressFor(60)
            assert.are.equal(Q.LinesPerMinute(), #sentIn("SAY"), "no fallback line, not even later")
            assert.are.equal(1, ns.Diag.Counters().capDropped)
        end)

        it("drops a line marked dropOverCap, telling its sender why", function()
            local Q = ns.ChatQueue
            for _ = 1, Q.LinesPerMinute() do
                Q.Push({ channel = "SAY", getText = function() return "filler" end })
                pressFor(Q.MIN_INTERVAL + 0.5)
            end
            local reason
            Q.Push({ channel = "SAY", dropOverCap = true, getText = function() return "line" end,
                onDone = function(sent, why) reason = not sent and why end })
            pressFor(2)
            assert.are.equal("chat rate limit reached (4 lines a minute in /say)", reason)
            -- spec/buffback_spec.lua checks the button's own line is dropped this way.
        end)
    end)

    describe("greetings over the cap (white)", function()
        it("wait for room in the next minute instead of being dropped", function()
            ns.db.linesPerMinute = 2
            for _, name in ipairs({ "Thrall", "Jaina", "Varian" }) do online(name) end
            wow.advance(30)
            assert.are.equal(2, #sentIn("GUILD"))
            wow.advance(60)
            assert.are.equal(3, #sentIn("GUILD"))
            assert.is_true(mostInAMinute(sentIn("GUILD")) <= 2)
        end)

        it("are counted per chat type: a full /say doesn't hold back guild chat", function()
            for i = 1, 8 do buffedBy(i) end
            pressFor(20)
            online("Thrall")
            pressFor(10)
            assert.are.equal(1, #sentIn("GUILD"))
        end)

        it("count party, raid and instance chat together, and name each chat type in the reason", function()
            local Q = ns.ChatQueue
            ns.db.linesPerMinute = 2
            local function reasonFor(channel)
                local reason
                Q.Push({ channel = channel, target = "Jaina", emote = "THANK", dropOverCap = true,
                    getText = function() return "x" end, onDone = function(sent, why) reason = not sent and why end })
                return reason
            end
            for _, case in ipairs({ { "SAY", "/say" }, { "WHISPER", "whispers" }, { "EMOTE", "emotes" },
                { "GUILD", "guild chat" }, { "PARTY", "group chat" }, { "CHANNEL", "CHANNEL" } }) do
                wow.state.inInstance = true -- no key press needed
                Q.Push({ channel = case[1], target = "Jaina", emote = "THANK", getText = function() return "a" end })
                wow.advance(Q.MIN_INTERVAL)
                if case[1] == "PARTY" then
                    Q.Push({ channel = "RAID", getText = function() return "b" end })
                else
                    Q.Push({ channel = case[1], target = "Jaina", emote = "THANK", getText = function() return "b" end })
                end
                wow.advance(Q.MIN_INTERVAL)
                assert.are.equal(string.format("chat rate limit reached (2 lines a minute in %s)", case[2]),
                    reasonFor(case[1] == "PARTY" and "INSTANCE_CHAT" or case[1]), case[1])
            end
        end)

        it("hold the self-test whisper too: nothing gets round the cap", function()
            ns.db.linesPerMinute = 1
            slash("selftest")
            slash("selftest")
            wow.advance(30)
            assert.are.equal(1, #sentIn("WHISPER"))
            wow.advance(40)
            assert.are.equal(2, #sentIn("WHISPER"))
        end)
    end)

    describe("the in-game hint (white)", function()
        local function hints()
            local n = 0
            for _, line in ipairs(wow.printed) do
                if line:find("skipped a thank-you to keep chat from turning spammy", 1, true) then n = n + 1 end
            end
            return n
        end

        it("tells you once a session, in your own chat, the first time the limit skips a thank-you", function()
            for i = 1, 4 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(0, hints(), "nothing skipped yet, so no hint")
            for i = 5, 12 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(1, hints(), "one hint for eight skipped thank-yous")
            local said = false
            for _, line in ipairs(wow.printed) do
                if line:find("(4 lines a minute in each chat; set it on the General options page)", 1, true) then
                    said = true
                end
            end
            assert.is_true(said, "with the limit in force and where to change it")
            for _, s in ipairs(wow.sent) do
                assert.is_nil(s.text:find("spammy", 1, true), "never sent to anyone")
            end
            pressFor(70)
            for i = 13, 30 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(1, hints(), "still once")
        end)

        it("doesn't show for greetings that only wait", function()
            ns.db.linesPerMinute = 1
            online("Thrall")
            online("Jaina")
            wow.advance(90)
            assert.are.equal(2, #sentIn("GUILD"))
            assert.are.equal(0, hints())
        end)

        it("shows again in a new session", function()
            for i = 1, 6 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(1, hints())
            local now = wow.now
            wow.fire("PLAYER_LOGOUT")
            boot(_G.FriendlyForeverDB)
            wow.now = now
            wow.advance(ns.Announcer.LOGIN_GRACE + 1)
            for i = 7, 9 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(1, hints(), "the reloaded session's own hint")
        end)
    end)

    describe("diagnostics (white)", function()
        it("count the lines held back and dropped, in /friendly status", function()
            ns.db.linesPerMinute = 1
            online("Thrall")
            online("Jaina")
            for i = 1, 3 do buffedBy(i) end
            pressFor(20)
            local counters = ns.Diag.Counters()
            assert.are.equal(1, counters.capHeld, "Jaina's hello waited")
            assert.are.equal(2, counters.capDropped, "two thank-yous were dropped")
            slash("status")
            assert.is_true(printedHas("chat cap: 1 lines a minute in each chat; 1 held back by it, 2 dropped by it"))
        end)
    end)

    describe("diagnostics (black)", function()
        it("say when the game has no chat or emote function", function()
            local function apis()
                wow.printed = {}
                slash("status")
                for _, line in ipairs(wow.printed) do
                    if line:find("APIs:", 1, true) then return line end
                end
            end
            assert.is_truthy(apis():find("SendChatMessage |cff00ff00on|r", 1, true))
            assert.is_truthy(apis():find("emote |cff00ff00on|r", 1, true))
            _G.C_ChatInfo.SendChatMessage, _G.SendChatMessage = nil, nil
            _G.C_ChatInfo.PerformEmote, _G.DoEmote = nil, nil
            assert.is_truthy(apis():find("SendChatMessage |cffff4040off|r", 1, true))
            assert.is_truthy(apis():find("emote |cffff4040off|r", 1, true))
        end)
    end)

    describe("the setting (white)", function()
        it("is set on the General page, within its limits", function()
            local stepper = ns.Options.widgets.general.linesPerMinute
            ns.Options.FillGeneral()
            assert.are.equal("4", stepper.box:GetText())
            -- Its hint says what the limit is for (the owner's wording request on #35).
            assert.is_truthy(ns.Options.widgets.general.capHelp:GetText():find("a helper, not a spammer", 1, true))
            wow.run(stepper.plus, "OnClick")
            assert.are.equal(5, ns.db.linesPerMinute)
            assert.are.equal("5", stepper.box:GetText())
            wow.run(stepper.minus, "OnClick")
            assert.are.equal(4, ns.db.linesPerMinute)
            stepper.box:SetText("99")
            wow.run(stepper.box, "OnEditFocusLost")
            assert.are.equal(10, ns.db.linesPerMinute)
            wow.run(stepper.plus, "OnClick")
            assert.are.equal(10, ns.db.linesPerMinute, "not past the top")
            stepper.box:SetText("0")
            wow.run(stepper.box, "OnEditFocusLost")
            assert.are.equal(1, ns.db.linesPerMinute)
            ns.db.linesPerMinute = 7
            ns.Options.FillGeneral()
            assert.are.equal("7", stepper.box:GetText())
            -- The message tabs' steppers still work on their own type.
            ns.Options.SelectType("guildLogin")
            wow.run(ns.Options.widgets.steppers.delay.plus, "OnClick")
            assert.are.equal(ns.Config.DEFAULTS.guildLogin.delay + 1, ns.db.guildLogin.delay)
            assert.are.equal(7, ns.db.linesPerMinute)
        end)

        it("travels in profiles and exported settings", function()
            ns.db.linesPerMinute = 6
            local line = assert(ns.Profiles.Export())
            ns.db.linesPerMinute = 2
            assert.is_true(ns.Profiles.Import(line))
            assert.are.equal(6, ns.db.linesPerMinute)
        end)

        it("survives a reload, and so does the count of lines just sent", function()
            for i = 1, 6 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(4, #sentIn("SAY"))
            local now = wow.now
            wow.fire("PLAYER_LOGOUT")
            boot(_G.FriendlyForeverDB)
            wow.now = now -- a reload: GetTime() carries on
            wow.advance(ns.Announcer.LOGIN_GRACE + 1)
            -- What's saved may be changed after loading (another addon, a
            -- bad /run): the session's own copy still counts.
            for _ = 1, 4 do table.remove(_G.FriendlyForeverDB.chatCap.say) end
            for i = 7, 9 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(0, #sentIn("SAY"), "the cap still remembers the four lines")
            pressFor(60)
            wow.fire("PLAYER_LOGOUT")
            assert.are.same({}, _G.FriendlyForeverDB.chatCap.say, "lines a minute old aren't saved")
        end)
    end)

    describe("damaged values and clock jumps (black)", function()
        local function loadCap(value)
            return ns.Config.Load({ linesPerMinute = value }).linesPerMinute
        end

        it("repairs a damaged cap value to its limits when loading", function()
            assert.are.equal(4, loadCap(nil))
            assert.are.equal(4, loadCap("lots"))
            assert.are.equal(4, loadCap(0 / 0))
            assert.are.equal(4, loadCap({}))
            assert.are.equal(1, loadCap(0))
            assert.are.equal(1, loadCap(-5))
            assert.are.equal(10, loadCap(1e9))
            assert.are.equal(10, loadCap(math.huge))
            assert.are.equal(3, loadCap(3.9))
        end)

        it("never lifts the cap for a value damaged mid-session", function()
            for _, bad in ipairs({ "lots", 0 / 0, math.huge, 1e9, -1, {}, true }) do
                ns.db.linesPerMinute = bad
                local n = ns.ChatQueue.LinesPerMinute()
                assert.is_true(n >= 1 and n <= 10, tostring(bad))
            end
            ns.db.linesPerMinute = nil
            assert.are.equal(4, ns.ChatQueue.LinesPerMinute())
            ns.db.linesPerMinute = 1e9
            for i = 1, 30 do buffedBy(i) end
            pressFor(60)
            assert.are.equal(10, #sentIn("SAY"))
        end)

        -- GetTime() doesn't jump within a session in the real game (the
        -- login grace and C_Timer run on it too), and time() can; the queue
        -- copes with either. Lines straight to the queue, past the grace.
        local function guildLines(count, first)
            for i = first, first + count - 1 do
                ns.ChatQueue.Push({ channel = "GUILD", getText = function() return "g" .. i end })
            end
        end

        -- In the simulated client time() follows GetTime(); these move one
        -- clock and leave the other where it was.
        local function jumpGameClock(seconds)
            wow.now = wow.now + seconds
            wow.state.clock = wow.state.clock - seconds
        end
        local function jumpWallClock(seconds)
            wow.state.clock = wow.state.clock + seconds
        end

        -- Timers set before a backward jump lie ahead of the clock, so pump by hand.
        local function waitPumping(seconds)
            for _ = 1, seconds do
                wow.advance(1)
                ns.ChatQueue.Pump(false)
            end
        end

        for _, case in ipairs({
            { "the game clock", function() jumpGameClock(-3600) end },
            { "the wall clock", function() jumpWallClock(-3600) end },
            { "both clocks", function() wow.now = wow.now - 3600 end },
        }) do
            it("doesn't let a burst through when " .. case[1] .. " jumps back, nor block for good", function()
                guildLines(4, 1)
                wow.advance(10)
                assert.are.equal(4, #sentIn("GUILD"))
                case[2]()
                guildLines(3, 5)
                waitPumping(59)
                assert.are.equal(4, #sentIn("GUILD"), "the lines before the jump still count")
                waitPumping(10)
                assert.are.equal(7, #sentIn("GUILD"), "sending resumes within a minute")
            end)
        end

        for _, case in ipairs({
            { "the game clock", jumpGameClock },
            { "the wall clock (the date or time is changed)", jumpWallClock },
        }) do
            it("lets nothing more through when " .. case[1] .. " jumps forward", function()
                for i = 1, 6 do buffedBy(i) end
                pressFor(20)
                case[2](86400 * 365)
                for i = 7, 12 do buffedBy(i) end
                pressFor(20)
                assert.are.equal(4, #sentIn("SAY"), "the other clock still counts them")
                pressFor(60)
                for i = 13, 14 do buffedBy(i) end
                pressFor(10)
                assert.are.equal(6, #sentIn("SAY"), "and a minute later sending goes on")
            end)
        end

        it("comes back after a restart puts the saved times in the future", function()
            for i = 1, 6 do buffedBy(i) end
            pressFor(20)
            wow.fire("PLAYER_LOGOUT")
            local db = _G.FriendlyForeverDB
            for _, list in pairs(db.chatCap) do
                for _, e in ipairs(list) do e.t, e.w = e.t + 1e6, e.w + 1e6 end
            end
            boot(db) -- a new session: GetTime() restarts lower
            wow.advance(ns.Announcer.LOGIN_GRACE + 1)
            for i = 7, 9 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(0, #sentIn("SAY"), "the saved lines count as just sent")
            pressFor(60)
            for i = 10, 11 do buffedBy(i) end
            pressFor(10)
            assert.are.equal(2, #sentIn("SAY"), "and age out within a minute")
        end)

        it("repairs a damaged saved record without letting lines through or blocking for good", function()
            local function loadRecord(record) return ns.Config.Load({ chatCap = record }).chatCap end
            local t, w = wow.now, time()
            assert.are.same({}, loadRecord("junk"))
            assert.are.same({}, loadRecord({ say = "junk", [1] = { 1 } }))
            local junk = loadRecord({ say = { "a", {}, { t = 0 / 0, w = 5 }, { t = 5, w = math.huge },
                { t = -math.huge, w = 6 }, { t = 7, w = 8 } } })
            assert.are.same({ { t = t, w = w }, { t = t, w = w }, { t = t, w = 5 }, { t = 5, w = w },
                { t = t, w = 6 }, { t = 7, w = 8 } }, junk.say)
            local long = {}
            for i = 1, 500 do long[i] = { t = i, w = i } end
            local kept = loadRecord({ say = long }).say
            assert.are.equal(10, #kept, "only the newest the cap can need")
            assert.are.same({ t = 500, w = 500 }, kept[10])
            local many = {}
            for i = 1, 100 do many["g" .. i] = {} end
            many[string.rep("k", 33)] = {}
            local n = 0
            for key in pairs(loadRecord(many)) do
                n = n + 1
                assert.is_true(#key <= 32)
            end
            assert.are.equal(ns.Config.MAX_CAP_GROUPS, n)
            assert.are.same({ say = {} }, loadRecord({ [string.rep("k", 33)] = {}, [true] = {}, say = {} }),
                "keys that aren't short text are dropped")

            -- Loaded from a damaged file: every bad entry counts as just sent.
            boot({ chatCap = { say = { "x", {}, { t = 0 / 0 }, { w = -math.huge }, true, "y" } } })
            wow.advance(ns.Announcer.LOGIN_GRACE + 1)
            for i = 1, 4 do buffedBy(i) end
            pressFor(20)
            assert.are.equal(0, #sentIn("SAY"))
            pressFor(60)
            for i = 5, 6 do buffedBy(i) end
            pressFor(10)
            assert.are.equal(2, #sentIn("SAY"), "and age out within a minute")

            -- Damaged mid-session: the session's own record still counts.
            for round, damage in ipairs({ "gone", { say = "gone" }, { say = { { t = 0 / 0 } } }, {} }) do
                ns.db.chatCap = damage
                for i = round * 10, round * 10 + 5 do buffedBy(i) end
                pressFor(10)
                assert.are.equal(4, #sentIn("SAY"), "nothing more within the minute")
            end
            assert.are.equal(4, #ns.db.chatCap.say, "and the saved copy is put right")
        end)

        it("waits while either clock can't be read, and ages entries out only on both", function()
            local RL, list = ns.RateLimit, {}
            assert.is_false(RL.HasRoom(list, 60, 4, 0 / 0, 1))
            assert.is_false(RL.HasRoom(list, 60, 4, 1, math.huge))
            assert.is_false(RL.HasRoom(list, 60, 0 / 0, 1, 1))
            assert.is_false(RL.HasRoom(list, 60, math.huge, 1, 1), "no limit is no room")
            assert.is_true(RL.HasRoom(list, 60, 4, 1, 1))
            RL.Note(list, 60, "soon", 1)
            RL.Note(list, 60, 1, nil)
            assert.are.equal(0, #list, "an unreadable time isn't noted")
            RL.Note(list, 60, 5, 100)
            assert.are.equal(1, RL.Count(list, 60, -math.huge, 100), "counts all with no clock")
            assert.are.equal(1, RL.Count(list, 60, 1000, nil), "or with no wall clock")
            assert.are.equal(1, RL.Count(list, 60, 64.9, 1000), "the game clock holds it")
            assert.are.equal(1, RL.Count(list, 60, 1000, 159.9), "the wall clock holds it")
            assert.are.equal(0, RL.Count(list, 60, 65, 160), "aged out after exactly the window on both")
            list[1] = "junk"
            assert.are.equal(1, RL.Count(list, 60, 70, 170), "a damaged entry counts as now")
            assert.are.same({ t = 70, w = 170 }, list[1])
            list[1] = { t = 0 / 0, w = "x" }
            assert.are.equal(1, RL.Count(list, 60, 80, 180), "and so does a damaged time in one")
            assert.are.same({ t = 80, w = 180 }, list[1])
        end)
    end)

    describe("no way round the queue (black)", function()
        -- Lua source without comments and string literals, so prose and
        -- status labels can't trip or satisfy the check.
        local function code(text)
            text = text:gsub("%-%-%[(=*)%[.-%]%1%]", "")
            text = text:gsub("%[(=*)%[.-%]%1%]", '""')
            text = text:gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
            return (text:gsub("%-%-[^\n]*", ""))
        end

        it("names the game's chat functions only in ChatQueue.lua", function()
            local _, files = wow.parseToc()
            local apis = { "SendChatMessage", "PerformEmote", "DoEmote", "BNSendWhisper", "ChatEdit_SendText",
                "RunMacroText", "RunMacro", "SendMail" }
            local checked = 0
            for _, file in ipairs(files) do
                if file:match("%.lua$") and file ~= "ChatQueue.lua" then
                    local source = code(wow.readFile(file))
                    for _, api in ipairs(apis) do
                        assert.is_nil(source:find("%f[%w_]" .. api .. "%f[^%w_]"), file .. " names " .. api)
                    end
                    checked = checked + 1
                end
            end
            assert.is_true(checked > 20)
            assert.is_truthy(code(wow.readFile("ChatQueue.lua")):find("SendChatMessage", 1, true))
        end)

        it("checks every send against the cap: the queue is the only sender", function()
            local Q = ns.ChatQueue
            ns.db.linesPerMinute = 3
            for i = 1, 10 do
                Q.Push({ channel = ({ "SAY", "GUILD", "PARTY", "WHISPER" })[i % 4 + 1], target = "Jaina",
                    getText = function() return "m" .. i end })
            end
            pressFor(119)
            for _, channel in ipairs({ "SAY", "GUILD", "PARTY", "WHISPER" }) do
                assert.is_true(mostInAMinute(sentIn(channel)) <= 3, channel)
            end
        end)
    end)

    describe("chaos (red)", function()
        -- The test's own idea of the cap a stored value gives, worked out
        -- here rather than asked of the addon: whole numbers 1 to 10, and 4
        -- for anything that isn't a number.
        local function expectedCap(value)
            if type(value) ~= "number" or value ~= value then return 4 end
            value = math.floor(value)
            if value < 1 then return 1 end
            if value > 10 then return 10 end
            return value
        end

        -- Which chat types count together, as the issue lists them.
        local GROUP = { SAY = "say", WHISPER = "whisper", GUILD = "guild", PARTY = "group", RAID = "group",
            INSTANCE_CHAT = "group" }

        local CAPS = { 1, 2, 3, 4, 7, 10, "junk", 0 / 0, -3, 1e9, 2.5 }

        local function storm(seed)
            random.seed(seed)
            boot()
            -- Every line the client's record shows, on the test's own
            -- timeline: real seconds, which only wow.advance moves (a jump
            -- of GetTime() or the date is not time passing).
            local lines, harvestedSent, harvestedEmotes = {}, 0, 0
            local realNow, base = 0, wow.now
            local capNow = expectedCap(ns.db.linesPerMinute)
            local where = "start" -- the step and action, for a failure's message
            local function harvest()
                for i = harvestedSent + 1, #wow.sent do
                    local s = wow.sent[i]
                    lines[#lines + 1] = { t = realNow + (s.time - base), group = GROUP[s.channel] or s.channel,
                        cap = capNow, where = where }
                end
                for i = harvestedEmotes + 1, #wow.emotes do
                    local e = wow.emotes[i]
                    lines[#lines + 1] = { t = realNow + (e.time - base), group = "emote", cap = capNow, where = where }
                end
                harvestedSent, harvestedEmotes = #wow.sent, #wow.emotes
            end
            local function passTime(seconds)
                base = wow.now
                wow.advance(seconds)
                harvest()
                realNow = realNow + seconds
                base = wow.now
            end
            -- The clocks as the real ones behave: GetTime() never runs ahead
            -- of real time, though it can start lower; the wall clock, time(),
            -- jumps whenever its date or time is changed. Each moves alone.
            local function setGameClock(value)
                local wall = time()
                wow.now = value
                wow.state.clock = wall - (wow.now - 1000) -- time() stays put
                base = wow.now
            end
            local function restart(keepClock)
                harvest()
                local db, now, wall = _G.FriendlyForeverDB, wow.now, time()
                wow.fire("PLAYER_LOGOUT")
                boot(db)
                wow.now = keepClock and now or (math.min(now, wow.now) - random.random(0, 900))
                wow.state.clock = wall - (wow.now - 1000)
                harvestedSent, harvestedEmotes = 0, 0
                base = wow.now
            end
            local n = 0
            local actions = {
                function()
                    n = n + 1
                    buffedBy(n)
                end,
                function()
                    for _ = 1, random.random(2, 8) do
                        n = n + 1
                        buffedBy(n)
                    end
                end,
                function() online(({ "Thrall", "Jaina", "Varian" })[random.random(3)]) end,
                function()
                    local name = strangerName(random.random(1, 30)) .. "-Realm"
                    wow.setGroup("party", { name })
                    wow.systemMessage(strangerName(random.random(1, 30)) .. " Realm joins the party.")
                end,
                function() slash("selftest") end,
                function()
                    base = wow.now
                    wow.keyDown()
                    harvest()
                end,
                function() passTime(random.random() * 20) end,
                function()
                    for _ = 1, random.random(5, 40) do
                        passTime(0.5)
                        wow.keyDown()
                        harvest()
                    end
                end,
                function()
                    local value = CAPS[random.random(#CAPS)]
                    ns.db.linesPerMinute = value
                    capNow = expectedCap(value)
                end,
                function() ns.db.buff.thankStyle = ({ "message", "emote", "both" })[random.random(3)] end,
                function() ns.db.buff.useWhisper = random.random() < 0.5 end,
                function() wow.state.lockdown = not wow.state.lockdown end,
                function() wow.state.inInstance = not wow.state.inInstance end,
                function() setGameClock(wow.now - random.random(1, 5000)) end, -- the game clock back
                function() wow.state.clock = wow.state.clock + random.random(-1e6, 1e6) end, -- the wall clock
                function() restart(true) end, -- /reload: GetTime() carries on
                function() restart(false) end, -- a new session after a restart: GetTime() is lower
                function()
                    local junk = { "x", {}, { t = 0 / 0 }, { w = "y" }, true, { t = 1e12, w = -1e12 } }
                    ns.db.chatCap = { say = { junk[random.random(#junk)] }, guild = junk[random.random(#junk)] }
                end,
            }
            -- How often each action comes up: mostly favours, greetings and
            -- key presses, so the cap is pushed; clock jumps and restarts
            -- (each a full reload) less often.
            local WEIGHTS = { 6, 4, 4, 3, 3, 3, 3, 6, 2, 1, 1, 1, 1, 1, 2, 1, 1, 1 }
            assert(#WEIGHTS == #actions)
            local deck = {}
            for i, w in ipairs(WEIGHTS) do
                for _ = 1, w do deck[#deck + 1] = i end
            end
            for step = 1, 300 do
                local action = deck[random.random(#deck)]
                where = "step " .. step .. " action " .. action
                local ok, err = pcall(actions[action])
                assert.is_true(ok, "seed " .. seed .. " step " .. step .. ": " .. tostring(err))
                harvest()
            end
            passTime(200)
            return lines
        end

        it("never exceeds the cap in any 60-second window, whatever the storm", function()
            local total, atCap = 0, 0
            for seed = 1, 20 do
                local lines = storm(seed)
                total = total + #lines
                for i, line in ipairs(lines) do
                    -- The lines of its chat type in the minute up to it, it included.
                    local count = 0
                    for j = 1, #lines do
                        local other = lines[j]
                        if other.group == line.group and other.t <= line.t and line.t - other.t < 60 then
                            count = count + 1
                        end
                    end
                    assert.is_true(count <= line.cap, string.format(
                        "seed %d line %d (%s): %d lines in %s within a minute, cap %d", seed, i, line.where, count,
                        line.group, line.cap))
                    if count == line.cap then atCap = atCap + 1 end
                end
            end
            assert.is_true(total > 100, "the storms sent plenty of lines: " .. total)
            assert.is_true(atCap > 20, "and often filled the cap: " .. atCap)
        end)
    end)
end)
