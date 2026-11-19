-- Spec: #510, #507, #509
-- The buff button in 1.5.1 (the owner's decisions of 19 Nov):
--   #510: the shift back into a form (#495) comes straight after your own
--         buffs and your group's, and before passers-by and strangers'
--         favours; a refusal's reason ("Can only use outside") clears once you
--         move indoors or outdoors, or change zone, and nothing presses by
--         itself.
--   #507: with nothing to offer, the button shows Friendly Forever's own
--         icon, never another class's buff.
--   #509: the bindings have a Key Bindings section of their own, and the
--         Buffs tab says buff mode's key is lent only while buff mode is on.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, INTELLECT = 9885, 1126, 10157
local CAT, BEAR, DIRE, TRAVEL, WOLF = 768, 5487, 9634, 783, 2645
local WATER_BREATHING, WATER_WALKING = 131, 546
local FORT_1 = 1243
local OWN_ICON = "Interface\\AddOns\\FriendlyForever\\Media\\Icon"
local PAW = "Interface\\Icons\\Spell_Nature_Regeneration"

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("The shift back into your form before strangers (#510)", function()
    local ns, button

    -- A druid who knows Mark of the Wild and the forms, in buff mode with
    -- "Fast-cast buffs in form" and passers-by on, in a party with Ann and
    -- Cid (opts.solo: alone), who lack it; opts.form: the form at the start.
    -- opts.shaman: a shaman in Ghost Wolf who knows Water Breathing and
    -- Water Walking instead.
    local function boot(opts)
        opts = opts or {}
        local db = { buffBack = { fastCastInForm = true, passersBy = true, breathNearWater = false } }
        ns = wow.boot({ db = db, before = function(state)
            if opts.shaman then
                state.class = "SHAMAN"
                state.knownSpells = { [WATER_BREATHING] = true, [WATER_WALKING] = true, [WOLF] = true }
                state.ghostWolfForm, state.ghostWolfAura = 1, true
            else
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [CAT] = true, [BEAR] = true, [DIRE] = true,
                    [TRAVEL] = true }
                if opts.form then state.form, state.formSpell = wow.FORM_STANCE[opts.form], opts.form end
            end
        end })
        button = ns.BuffButton.Frame()
        if opts.shaman then wow.setGhostWolf(true) end
        slash("buffmode on")
        if not opts.solo then
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.fire("GROUP_ROSTER_UPDATE")
        end
        wow.advance(0)
        ns.BuffButton.Refresh()
    end

    local A = function() return ns.BuffButton.SECURE_ATTRIBUTE end
    local function clickMacro() return button:GetAttribute(A().leftButtonMacroText) end
    local function keyMacro() return button:GetAttribute(A().keyMacroText) end
    local function scroll() wow.pressKey("MOUSEWHEELUP") end
    local function offersForm() return (clickMacro() or ""):find("^/cast !") ~= nil end
    local function form() return (wow.state.form or 0) ~= 0 and wow.state.formSpell or 0 end
    local function formCasts()
        local n = 0
        for _, c in ipairs(wow.casts) do if c.form then n = n + 1 end end
        return n
    end

    -- A stranger on a nameplate, a warrior: a passer-by, unless they buff you.
    local function stranger(token, name, surname)
        wow.addUnit(token, { name = name, surname = surname, id = name .. "-" .. surname, class = "WARRIOR",
            auras = {} })
    end
    -- A stranger who buffed you: you owe them a favour.
    local function favour(token, name, surname)
        stranger(token, name, surname)
        wow.gainBuff({ sourceUnit = token, name = "Arcane Intellect", spellId = INTELLECT })
    end
    local STRANGERS = { ["Bob-Stone"] = true, ["Dan-Reed"] = true, ["Eve-Moss"] = true, ["Fay-Lark"] = true }
    local function strangerCasts(from)
        local out = {}
        for i = from + 1, #wow.casts do
            local c = wow.casts[i]
            if c.target and STRANGERS[c.target] then out[#out + 1] = c.target .. ":" .. tostring(c.spell) end
        end
        return out
    end
    -- Each buff that landed, worn by whoever it landed on.
    local function wearLanded()
        for _, l in ipairs(wow.landed) do
            for token, u in pairs(wow.state.units) do
                if token ~= "player" and u.id == l.target and not l.worn then
                    wow.wearBuff(token, l.id, { source = "player" })
                end
            end
            l.worn = true
        end
    end

    describe("its place (white)", function()
        it("passers-by and a stranger's favour arriving while it waits: your group's buffs and your own come "
            .. "first, then the shift back; no stranger is buffed before it", function()
            boot({ form = CAT })
            scroll()
            wearLanded()
            assert.are.equal(0, form(), "the buff took you out of Cat Form")
            stranger("nameplate1", "Bob", "Stone")
            favour("nameplate2", "Dan", "Reed")
            ns.BuffButton.Refresh()
            local from = #wow.casts
            for _ = 1, 8 do
                if offersForm() then break end
                assert.is_nil(STRANGERS[ns.BuffButton.ArmedOffer().name or ""], "a stranger before the shift back")
                scroll()
                wearLanded()
            end
            assert.is_true(offersForm(), "your own buffs done: the shift back is offered")
            assert.are.same({}, strangerCasts(from))
            local buffed = {}
            for _, c in ipairs(wow.casts) do buffed[c.target or "?"] = true end
            assert.is_true(buffed["Ann-Vale"] and buffed["Cid-Rock"] or false, "your group was buffed before it")
            assert.are.equal("/cast !Cat Form", keyMacro(), "the key presses it")
            assert.matches("shift back into Cat Form", button.subtitle:GetText(), 1, true)
            scroll()
            assert.are.equal(CAT, form(), "the scroll shifted you back")
            assert.are.same({}, strangerCasts(from), "no stranger was buffed")
            -- Back in the form, the strangers are offered again.
            ns.BuffButton.Refresh()
            assert.is_truthy(STRANGERS[ns.BuffButton.ArmedOffer().name or ""], "the strangers come after")
        end)

        it("while the shift back is being cast (Ghost Wolf takes a moment), nothing is offered, "
            .. "not even a passer-by", function()
            boot({ shaman = true })
            for _ = 1, 8 do
                if offersForm() then break end
                scroll()
                wearLanded()
            end
            assert.are.equal("/cast !Ghost Wolf", clickMacro())
            stranger("nameplate1", "Bob", "Stone")
            local from = #wow.casts
            wow.state.castLatency = 2.5
            scroll()
            assert.are.equal(1, formCasts())
            ns.BuffButton.Refresh()
            assert.is_nil(clickMacro(), "nothing offered while it's cast")
            assert.matches("shifting you back into Ghost Wolf", button.subtitle:GetText(), 1, true)
            for _ = 1, 4 do
                wow.advance(0.4)
                scroll()
            end
            assert.are.same({}, strangerCasts(from))
            wow.advance(1)
            assert.is_true(wow.state.ghostWolf, "back in Ghost Wolf")
        end)
    end)

    describe("the order without a shift back (black)", function()
        it("with no form left, a stranger's favour still comes first, then your group, then passers-by", function()
            boot()
            stranger("nameplate1", "Bob", "Stone")
            favour("nameplate2", "Dan", "Reed")
            ns.BuffButton.Refresh()
            assert.are.equal("Dan-Reed", ns.BuffButton.ArmedOffer().name, "the favour first, as before")
            local names = {}
            for _, o in ipairs(ns.BuffList.ShownOffers()) do names[#names + 1] = o.name end
            assert.are.equal("Dan-Reed", names[1])
            assert.are.same({ "Ann-Vale", "Cid-Rock" }, { names[2], names[3] }, "then your group")
            for i = 1, 3 do assert.are_not.equal("Bob-Stone", names[i], "passers-by last") end
        end)

        it("with the shift back waiting, a mana refusal still shows click to shift back and holds nobody back",
            function()
            boot({ form = BEAR })
            for _ = 1, 8 do
                if offersForm() then break end
                scroll()
                wearLanded()
            end
            assert.is_true(offersForm())
            stranger("nameplate1", "Bob", "Stone")
            local from = #wow.casts
            wow.state.formRefusals = { [BEAR] = "Not enough mana" }
            scroll()
            assert.matches("click to shift back (Not enough mana)", button.mode:GetText(), 1, true)
            assert.is_nil(keyMacro(), "the key waits")
            assert.are.equal("/cast !Bear Form", clickMacro(), "the shift back is still the one offered")
            for _ = 1, 5 do scroll() end
            assert.are.same({}, strangerCasts(from), "the key buffs no stranger meanwhile")
        end)
    end)

    describe("a refusal's reason clears when you move (white)", function()
        -- Travel Form refused indoors: the key waits, with the reason.
        local function refusedIndoors()
            boot({ form = TRAVEL })
            for _ = 1, 8 do
                if offersForm() then break end
                scroll()
                wearLanded()
            end
            assert.is_true(offersForm())
            wow.state.indoors = true
            wow.state.formRefusals = { [TRAVEL] = "Can only use outside." }
            scroll()
            assert.is_nil(keyMacro(), "the key waits")
            assert.matches("click to shift back (Can only use outside)", button.mode:GetText(), 1, true)
            wow.state.formRefusals = nil
        end

        it("outdoors again: the button offers the shift back fresh, the key presses it, and nothing presses "
            .. "by itself", function()
            refusedIndoors()
            wow.state.indoors = false
            local casts = #wow.casts
            wow.advance(ns.BuffButton.RECHECK_SECONDS + 0.5)
            assert.are.equal("/cast !Travel Form", keyMacro(), "the key presses it again")
            assert.is_nil(button.mode:GetText():find("click to shift back", 1, true))
            assert.matches("shift back into Travel Form", button.subtitle:GetText(), 1, true)
            wow.advance(5)
            assert.are.equal(casts, #wow.casts, "nothing pressed by itself")
            stranger("nameplate1", "Bob", "Stone")
            scroll()
            assert.are.equal(TRAVEL, form(), "the scroll shifted you back")
            assert.are.same({}, strangerCasts(casts))
        end)

        it("a new zone clears it too, at once", function()
            refusedIndoors()
            wow.state.zone = "Westfall"
            wow.fire("ZONE_CHANGED_NEW_AREA")
            wow.advance(0.5)
            assert.are.equal("/cast !Travel Form", keyMacro())
        end)

        it("moving indoors after a refusal outdoors clears it as well", function()
            boot({ form = CAT })
            for _ = 1, 8 do
                if offersForm() then break end
                scroll()
                wearLanded()
            end
            wow.state.formRefusals = { [CAT] = "You can't do that here." }
            scroll()
            assert.is_nil(keyMacro())
            wow.state.formRefusals = nil
            wow.state.indoors = true
            scroll() -- a press reads the place first: this one shifts you back
            assert.are.equal(CAT, form())
        end)
    end)

    describe("a refusal's reason stays (black)", function()
        local function refused()
            boot({ form = TRAVEL })
            for _ = 1, 8 do
                if offersForm() then break end
                scroll()
                wearLanded()
            end
            wow.state.formRefusals = { [TRAVEL] = "Can only use outside." }
            scroll()
            assert.is_nil(keyMacro())
            local casts = #wow.casts
            for _ = 1, 4 do scroll() end
            assert.are.equal(casts, #wow.casts)
        end

        it("while you stay where you were", function()
            wow.state.indoors = nil
            refused()
            wow.advance(ns.BuffButton.RECHECK_SECONDS + 0.5)
            assert.is_nil(keyMacro(), "the key still waits")
            assert.matches("click to shift back (Can only use outside)", button.mode:GetText(), 1, true)
        end)

        for _, case in ipairs({
            { "indoors unreadable (an error) when refused", function() wow.state.indoors = function() error("x") end end,
                function() wow.state.indoors = true end },
            { "indoors a secret when refused", function() wow.state.indoors = function() return wow.secret(true) end end,
                function() wow.state.indoors = false end },
            { "indoors unreadable after", function() wow.state.indoors = false end,
                function() wow.state.indoors = function() error("x") end end },
            { "the zone with no name when refused", function() wow.state.zone = "" end,
                function() wow.state.zone = "Westfall" end },
            { "the zone a secret after", function() end, function() wow.state.zone = wow.secret("Westfall") end },
        }) do
            it(case[1] .. ": the reason stays, and the key waits", function()
                boot({ form = TRAVEL })
                for _ = 1, 8 do
                    if offersForm() then break end
                    scroll()
                    wearLanded()
                end
                case[2]()
                wow.state.formRefusals = { [TRAVEL] = "Can only use outside." }
                scroll()
                assert.is_nil(keyMacro())
                case[3]()
                wow.fire("ZONE_CHANGED_NEW_AREA")
                wow.advance(ns.BuffButton.RECHECK_SECONDS + 0.5)
                assert.is_nil(keyMacro(), "nothing readable said you moved")
                assert.are.equal("/cast !Travel Form", clickMacro(), "a click still can")
            end)
        end

        it("PlaceChanged: only what both places read can say you moved", function()
            boot()
            local changed = ns.BuffButton.PlaceChanged
            assert.is_true(changed({ indoors = true, zone = "A" }, { indoors = false, zone = "A" }))
            assert.is_true(changed({ indoors = false, zone = "A" }, { indoors = false, zone = "B" }))
            assert.is_false(changed({ indoors = false, zone = "A" }, { indoors = false, zone = "A" }))
            assert.is_false(changed({ zone = "A" }, { indoors = true, zone = "A" }))
            assert.is_false(changed({ indoors = true }, { indoors = true, zone = "B" }))
            assert.is_false(changed(nil, { indoors = true }))
            assert.is_false(changed({ indoors = true }, nil))
        end)
    end)

    describe("storms (red)", function()
        -- Strangers arriving and leaving, strangers buffing you, your group's
        -- buffs fading, scrolls, clicks and time at random, for a druid who
        -- starts in Cat Form. Checked from the simulated client's own state:
        -- once a press has taken you out of a form, until you're back in one
        -- or 30 seconds pass after your last buff, no press casts anything on
        -- a stranger. Every seed must hold a stranger back at least once and
        -- shift back at least once.
        local NAMES = { { "Bob", "Stone" }, { "Dan", "Reed" }, { "Eve", "Moss" }, { "Fay", "Lark" } }

        local function storm(seed)
            random.seed(seed)
            boot({ form = CAT })
            local errors = ns.Diag.Counters().luaErrors or 0
            local left, lastBuff = false, -math.huge
            local heldBack, backs = 0, 0
            for _ = 1, 260 do
                local roll = random.random(1, 10)
                if roll == 1 then
                    local i = random.random(1, #NAMES)
                    local token = "nameplate" .. i
                    if wow.state.units[token] then
                        wow.state.units[token] = nil
                    elseif random.random(1, 2) == 1 then
                        favour(token, NAMES[i][1], NAMES[i][2])
                    else
                        stranger(token, NAMES[i][1], NAMES[i][2])
                    end
                elseif roll == 2 then
                    local token = random.random(1, 2) == 1 and "party1" or "party2"
                    wow.state.units[token].auras = {}
                elseif roll == 3 then
                    wow.advance(random.random(1, 40) / 4)
                else
                    local before, casts = form(), #wow.casts
                    local waiting = left and wow.now - lastBuff < ns.BuffButton.RETURN_SECONDS
                    local strangersNear = false
                    for i = 1, #NAMES do if wow.state.units["nameplate" .. i] then strangersNear = true end end
                    if roll == 4 then wow.press(button) else scroll() end
                    wearLanded()
                    if waiting then
                        assert.are.same({}, strangerCasts(casts), "a stranger buffed while the shift back waited")
                        if strangersNear then heldBack = heldBack + 1 end
                    end
                    for i = casts + 1, #wow.casts do
                        if not wow.casts[i].form then lastBuff = wow.now end
                    end
                    if before ~= 0 and form() == 0 and #wow.casts > casts then left = true end
                    if before == 0 and form() ~= 0 then
                        if left then backs = backs + 1 end
                        left = false
                    end
                    wow.advance(0.2)
                end
                if form() ~= 0 then left = false end
            end
            assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0)
            assert.is_true(heldBack >= 1, "a stranger was near while the shift back waited")
            assert.is_true(backs >= 1, "shifted back at least once")
        end

        for _, seed in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8 }) do
            it("seed " .. seed .. ": no press buffs a stranger while the shift back waits", function()
                storm(seed)
            end)
        end
    end)
end)

describe("The idle buff button's icon (#507)", function()
    -- A level 10 priest, a shaman, or a druid, in buff mode, solo, with
    -- nothing to hand out.
    local function idle(class, known)
        local ns = wow.boot({ before = function(state)
            state.class = class
            state.knownSpells = known
        end })
        _G.SlashCmdList.FRIENDLYFOREVER("buffmode on")
        for _, id in pairs(known) do wow.gainBuff({ spellId = id, sourceUnit = "player" }) end
        ns.BuffButton.Refresh()
        return ns, ns.BuffButton.Frame()
    end

    for _, case in ipairs({ { "PRIEST", { FORT_1 } }, { "SHAMAN", {} }, { "DRUID", { MOTW_1 } }, { "WARRIOR", {} } }) do
        it(case[1] .. ": with nothing to offer, the button shows Friendly Forever's own icon (white)", function()
            local known = {}
            for _, id in ipairs(case[2]) do known[id] = true end
            local ns, button = idle(case[1], known)
            assert.is_nil(ns.BuffButton.ArmedOffer(), "nothing offered")
            assert.is_true(button:IsShown())
            assert.are.equal(OWN_ICON, button.icon.texture)
            assert.are_not.equal(PAW, button.icon.texture)
        end)
    end

    it("the TOC's icon and the button's are the same file (white)", function()
        local toc = wow.readFile("FriendlyForever.toc")
        local ns = wow.boot()
        assert.is_truthy(toc:find("## IconTexture: " .. ns.BuffButton.PLACEHOLDER_ICON .. "\n", 1, true))
        assert.are.equal(OWN_ICON, ns.BuffButton.PLACEHOLDER_ICON)
    end)

    it("unlocked for moving: Friendly Forever's own icon (black)", function()
        local ns, button = idle("PRIEST", { [FORT_1] = true })
        ns.db.buffBack.unlocked = true
        ns.BuffButton.Refresh()
        assert.are.equal(OWN_ICON, button.icon.texture)
    end)

    it("an offer whose icon can't be read shows Friendly Forever's own, never another class's spell (black)",
        function()
        local ns = wow.boot({ before = function(state)
            state.class = "PRIEST"
            state.knownSpells = { [FORT_1] = true }
        end })
        local button = ns.BuffButton.Frame()
        _G.C_Spell.GetSpellTexture = function() error("unreadable") end
        _G.GetSpellTexture = function() error("unreadable") end
        _G.SlashCmdList.FRIENDLYFOREVER("buffmode on")
        wow.setGroup("party", { "Ann-Vale" })
        wow.fire("GROUP_ROSTER_UPDATE")
        ns.BuffButton.Refresh()
        assert.is_truthy(ns.BuffButton.ArmedOffer(), "your Fortitude is offered")
        assert.are.equal(OWN_ICON, button.icon.texture)
    end)
end)

describe("Key Bindings and buff mode's key (#509)", function()
    it("the bindings are in a Friendly Forever section of their own, the buff button first (white)", function()
        wow.boot()
        local xml = wow.readFile("Bindings.xml")
        local order = {}
        for name, category in xml:gmatch('<Binding name="([^"]+)" category="([^"]+)"') do
            order[#order + 1] = name
            assert.are.equal("BINDING_HEADER_FRIENDLYFOREVER", category, name)
        end
        assert.are.same({ "CLICK FriendlyForeverBuffButton:LeftButton", "FRIENDLYFOREVER_BUFFMODE" }, order)
        assert.are.equal("Friendly Forever", _G.BINDING_HEADER_FRIENDLYFOREVER)
    end)

    it("a key saved for either binding is kept: the bindings' names are unchanged (black)", function()
        -- The game keeps a key by its binding's name; these are the names
        -- 1.5.0 shipped.
        local xml = wow.readFile("Bindings.xml")
        assert.is_truthy(xml:find('<Binding name="CLICK FriendlyForeverBuffButton:LeftButton"', 1, true))
        assert.is_truthy(xml:find('<Binding name="FRIENDLYFOREVER_BUFFMODE"', 1, true))
        local ns = wow.boot()
        assert.are.equal("FRIENDLYFOREVER_BUFFMODE", ns.BuffMode.BINDING)
        assert.are.equal("FriendlyForeverBuffButton", ns.BuffButton.FRAME_NAME)
    end)

    it("the Buffs tab's key line says the key is lent only while buff mode is on (white)", function()
        local ns = wow.boot()
        local w = ns.Options.widgets
        ns.Options.Open()
        wow.run(w.tabs.buffs, "OnClick")
        assert.is_true(w.buffModeKeyNote:IsVisible())
        assert.matches("only while buff mode is on", w.buffModeKeyNote:GetText(), 1, true)
        assert.matches("Not Bound", w.buffModeKeyNote:GetText(), 1, true)
    end)
end)
