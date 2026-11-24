-- Spec: #154, #223, #209, #160, #362, #424, #500, #521
-- The UI scenarios' game-event helpers (uitests/button_states.lua), run here
-- against a stand-in for the simulator's A_Admin that records each call and
-- event in order. They follow what wow-ui-sim does itself (its admin.rs and
-- admin_party_target_helpers.rs, the same at 936d5f5 as at ac893c6):
-- SetTarget, ClearTarget and SetInCombat fire their own events, after the
-- state change, and LearnSpell fills the spellbook. Since 936d5f5's Forever
-- profile it also names Forever's buffs and answers their range (#160). The
-- scenarios themselves run only in the simulator.

-- Loads button_states.lua with a recording A_Admin; returns its States, the
-- log of calls and events, and the stand-in client tables.
local function load(opts)
    opts = opts or {}
    local log = {}
    local function record(entry) log[#log + 1] = entry end
    local client = {
        inCombat = false,
        class = 2, -- the simulator's player starts as a Paladin
        C_SpellBook = {},
        C_Spell = {},
    }
    local function original(name)
        return function() return "simulator's " .. name end
    end
    client.C_SpellBook.IsSpellInSpellBook = original("IsSpellInSpellBook")
    client.C_Spell.GetSpellName = original("GetSpellName")
    client.C_Spell.IsSpellInRange = original("IsSpellInRange")
    client.originals = {
        IsSpellInSpellBook = client.C_SpellBook.IsSpellInSpellBook,
        GetSpellName = client.C_Spell.GetSpellName,
        IsSpellInRange = client.C_Spell.IsSpellInRange,
    }
    client.fired = {} -- each event fired, with its arguments
    local admin = {
        FireEvent = function(event, ...)
            record("event " .. event)
            client.fired[#client.fired + 1] = { event, ... }
        end,
        SetTarget = function(name) record("SetTarget " .. name) end,
        ClearTarget = function() record("ClearTarget") end,
        SetInCombat = function(on)
            client.inCombat = on
            record("SetInCombat " .. tostring(on))
        end,
        LearnSpell = function(id) record("LearnSpell " .. id) end,
        UnlearnSpell = function(id) record("UnlearnSpell " .. id) end,
        SetPlayerClass = function(class)
            client.class = class
            record("SetPlayerClass " .. class)
        end,
        -- The aura goes on the player, as the simulator's add_buff puts it (#424).
        AddBuff = function(id, name)
            record("AddBuff " .. id)
            client.auras[#client.auras + 1] = { spellId = id, name = name }
        end,
        -- The simulator matches the exact spell ID (wow-ui-sim's remove_buff).
        RemoveBuff = function(id)
            record("RemoveBuff " .. id)
            if client.stubborn then return end
            for i = #client.auras, 1, -1 do
                if client.auras[i].spellId == id then table.remove(client.auras, i) end
            end
        end,
    }
    client.auras = {} -- the player's helpful auras, as the simulator seeds them
    -- A state's setup makes calls no test here is about (the clock, the
    -- party): they are recorded and ignored.
    if opts.lenient then
        setmetatable(admin, { __index = function(_, name)
            return function(...) record(name .. " " .. select("#", ...)) end
        end })
    end
    client.db = opts.db
    local env = setmetatable({
        FriendlyForeverDB = opts.db,
        A_Admin = admin,
        C_SpellBook = client.C_SpellBook,
        C_Spell = client.C_Spell,
        C_UnitAuras = { GetAuraDataByIndex = function(_, i) return client.auras[i] end },
        UnitClass = function() return "x", "X", client.class end,
        GetTime = function() return 0 end,
        UnitExists = function() return false end,
        UnitName = function() return nil end,
        UnitLevel = function() return 1 end,
        SlashCmdList = { FRIENDLYFOREVER = function(text) record("slash " .. text) end },
        UnitInRange = function(unit) return unit == "party1" end,
        InCombatLockdown = function() return client.inCombat end,
    }, { __index = _G })
    local chunk = assert(loadfile("uitests/button_states.lua"))
    setfenv(chunk, env)
    chunk()
    return env.FriendlyForeverUIStates, log, client
end

describe("UI scenarios: game events on wow-ui-sim (#154)", function()
    it("targets and clears the target, leaving PLAYER_TARGET_CHANGED to the simulator (white)", function()
        local States, log = load()
        States.Target("Aria Lindqvist")
        States.Target(nil)
        assert.are.same({ "SetTarget Aria Lindqvist", "ClearTarget" }, log)
    end)

    it("fires PLAYER_REGEN_DISABLED before the lockdown starts, as the game does (white)", function()
        local States, log, client = load()
        States.Combat(true)
        assert.are.same({ "event PLAYER_REGEN_DISABLED", "SetInCombat true" }, log)
        assert.is_true(client.inCombat)
    end)

    it("ends a fight with SetInCombat alone, whose PLAYER_REGEN_ENABLED comes after it (white)", function()
        local States, log, client = load()
        States.Combat(true)
        States.Combat(false)
        assert.are.same({ "event PLAYER_REGEN_DISABLED", "SetInCombat true", "SetInCombat false" }, log)
        assert.is_false(client.inCombat)
    end)
end)

describe("UI scenarios: the spellbook fixture on wow-ui-sim (#154, #160)", function()
    it("teaches the buff with LearnSpell, as a Priest, then says the spells changed (white)", function()
        local States, log, client = load()
        States.Learn()
        assert.are.same({ "LearnSpell 10938", "SetPlayerClass 5", "event SPELLS_CHANGED" }, log)
        assert.are.equal(client.originals.IsSpellInSpellBook, client.C_SpellBook.IsSpellInSpellBook,
            "the spellbook is the simulator's own now")
    end)

    -- #160: the Forever profile has Forever's spell data, so the fixture no
    -- longer answers for the simulator: what a scenario reads is its own.
    it("leaves the buff's name and range to the simulator, for the buff and every other spell (white)", function()
        local States, _, client = load()
        States.Learn()
        assert.are.equal(client.originals.GetSpellName, client.C_Spell.GetSpellName)
        assert.are.equal(client.originals.IsSpellInRange, client.C_Spell.IsSpellInRange)
        assert.are.equal("simulator's GetSpellName", client.C_Spell.GetSpellName(10938))
        assert.are.equal("simulator's IsSpellInRange", client.C_Spell.IsSpellInRange("Power Word: Fortitude", "party1"))
        assert.are.equal("simulator's GetSpellName", client.C_Spell.GetSpellName(1243))
    end)

    it("leaves the group spell's name and range to the simulator too, and answers only its reagent count (white)", function()
        local States, _, client = load({ lenient = true })
        -- The fixture answers the game's global, which the stand-in lacks.
        local before = _G.GetItemCount
        local counted = function() return 0 end
        _G.GetItemCount = counted
        local ok, err = pcall(function()
            States.ListGroupCast.Set()
            assert.are.equal(client.originals.GetSpellName, client.C_Spell.GetSpellName)
            assert.are.equal(client.originals.IsSpellInRange, client.C_Spell.IsSpellInRange)
            assert.are.equal(5, _G.GetItemCount(States.GROUP_SPELL.reagent), "the reagent the group cast needs")
            assert.are.equal(0, _G.GetItemCount(17020), "any other item is the simulator's to count")
            States.ListGroupCast.Undo()
            assert.are.equal(counted, _G.GetItemCount)
            assert.are.equal(client.originals.GetSpellName, client.C_Spell.GetSpellName)
        end)
        _G.GetItemCount = before
        assert.is_true(ok, tostring(err))
    end)

    it("puts everything back on Unlearn: the spell and the class (white)", function()
        local States, log, client = load()
        States.Learn()
        States.Unlearn()
        assert.are.same({ "LearnSpell 10938", "SetPlayerClass 5", "event SPELLS_CHANGED",
            "UnlearnSpell 10938", "SetPlayerClass 2", "event SPELLS_CHANGED" }, log)
        assert.are.equal(client.originals.GetSpellName, client.C_Spell.GetSpellName)
        assert.are.equal(client.originals.IsSpellInRange, client.C_Spell.IsSpellInRange)
        assert.are.equal(2, client.class)
    end)

    it("does nothing on a second Learn or an Unlearn with nothing learned (black)", function()
        local States, log = load()
        States.Unlearn()
        States.Learn()
        States.Learn()
        assert.are.same({ "LearnSpell 10938", "SetPlayerClass 5", "event SPELLS_CHANGED" }, log)
    end)
end)

describe("UI scenarios: the player's seeded buffs on wow-ui-sim (#223)", function()
    it("takes every Fortitude off the player, the simulator's random 21562 too, and no other buff (white)", function()
        local States, log, client = load()
        client.auras = { { spellId = 1459 }, { spellId = 21562 }, { spellId = 10938 }, { spellId = 21564 } }
        States.NoFortitude()
        assert.are.same({ { spellId = 1459 } }, client.auras)
        assert.are.same({ "RemoveBuff 10938", "RemoveBuff 10937", "RemoveBuff 2791", "RemoveBuff 1245",
            "RemoveBuff 1244", "RemoveBuff 1243", "RemoveBuff 21564", "RemoveBuff 21562" }, log)
    end)

    it("does nothing when the player wears none (white)", function()
        local States, _, client = load()
        client.auras = { { spellId = 1459 } }
        States.NoFortitude()
        assert.are.same({ { spellId = 1459 } }, client.auras)
    end)

    it("fails loudly when a Fortitude stays, so a scenario can't pass or fail by chance (black)", function()
        local States, _, client = load()
        client.auras = { { spellId = 1459 }, { spellId = 21562 } }
        client.stubborn = true
        assert.has_error(function() States.NoFortitude() end, "the player still wears Fortitude (21562)")
    end)

    it("is done by the buff mode state's setup, whatever the simulator seeded (white)", function()
        local States, log, client = load({ lenient = true })
        client.auras = { { spellId = 21562 }, { spellId = 1459 } }
        States.GroupMissing.Set()
        assert.are.same({ { spellId = 1459 } }, client.auras, "no Fortitude is left once the state is set")
        assert.is_true(table.concat(log, "\n"):find("RemoveBuff 21562", 1, true) ~= nil)
    end)

    it("removes exactly the IDs the addon counts as Priest Fortitude (BuffData.lua), so a rank change can't leave one (white)", function()
        local States = load()
        local ns = { Util = {} }
        assert(loadfile("BuffTable.lua"))("FriendlyForever", ns)
        assert(loadfile("BuffData.lua"))("FriendlyForever", ns)
        local expected = {}
        for _, buff in ipairs(ns.BuffData.CLASSES.PRIEST) do
            if buff.key == "fortitude" then
                for _, id in ipairs(buff.ranks) do expected[#expected + 1] = id end
                for _, id in ipairs(buff.group) do expected[#expected + 1] = id end
            end
        end
        local removed = {}
        for _, id in ipairs(States.FORTITUDE_IDS) do removed[#removed + 1] = id end
        table.sort(expected)
        table.sort(removed)
        assert.are.same(expected, removed)
    end)
end)

-- #362: the button holding a buff asked for in chat, for its screenshot and
-- scenario. The state switches requests on as the Buff Back tab's checkbox
-- does, and has a stranger you target whisper a request the addon reads.
describe("UI scenarios: a buff asked for in chat (#362)", function()
    it("switches requests on, targets the stranger, then fires their whisper, with their whole name (white)", function()
        local db = { buffBack = { requests = false } }
        local States, log, client = load({ lenient = true, db = db })
        States.Requested.Set()
        assert.is_true(db.buffBack.requests)
        local whole = table.concat(log, "\n")
        local on = whole:find("slash on\n", 1, true)
        local target = whole:find("SetTarget " .. States.ASKER, 1, true)
        local whisper = whole:find("event CHAT_MSG_WHISPER", 1, true)
        assert.is_truthy(on and target and whisper and on < whisper and target < whisper, whole)
        local fired = client.fired[#client.fired]
        assert.are.same({ "CHAT_MSG_WHISPER", States.ASKED, "Ingrid-Halvorsen" }, fired)
    end)

    it("puts the setting back as it was, and lets a request still on the button go (white)", function()
        for _, before in ipairs({ false, true }) do
            local db = { buffBack = { requests = before } }
            local States, log = load({ lenient = true, db = db })
            States.Requested.Set()
            States.Requested.Undo()
            assert.are.equal(before, db.buffBack.requests)
            assert.is_truthy(table.concat(log, "\n"):find("ClearTarget", 1, true))
            -- A second Undo changes nothing.
            db.buffBack.requests = "kept"
            States.Requested.Undo()
            assert.are.equal("kept", db.buffBack.requests)
        end
    end)

    it("is a request the addon reads: the button names who asked over the longest buff name (white)", function()
        local States = load({ lenient = true, db = { buffBack = {} } })
        local wow = require("spec.support.wow")
        local ns = wow.boot({ before = function(state)
            state.class = "PRIEST"
            state.knownSpells = { [States.SPELL.id] = true }
        end })
        ns.Requests.SetEnabled(true)
        local first, last = States.ASKER:match("^(%S+) (%S+)$")
        wow.addUnit("target", { name = first, surname = last, id = first .. "-" .. last, class = "WARRIOR" })
        wow.whisper(States.ASKED, first .. "-" .. last)
        local button = ns.BuffButton.Frame()
        assert.is_true(button:IsShown())
        assert.are.equal(States.ASKER, button.title:GetText())
        assert.are.equal("asked for " .. States.SPELL.name, button.subtitle:GetText())
    end)
end)

-- #424: the button and its list holding a weapon buff (#45), for its
-- screenshot and scenario. The simulator has no bags or weapon enchants to
-- set up, so the state answers those reads for its own items while it's set,
-- and leaves every other question to the simulator.
describe("UI scenarios: a weapon buff picked in the list (#424)", function()
    local NAMES = { "GetWeaponEnchantInfo", "GetInventoryItemID", "GetItemInfoInstant", "GetItemSpell", "GetItemCount",
        "IsUsableItem" }
    local ITEM_NAMES = { "GetItemInfoInstant", "GetItemSpell", "GetItemCount", "IsUsableItem", "GetItemNameByID" }

    -- The simulator's own functions, each answering its name, and a list
    -- with your weapon buff's row; put back after fn.
    local function withClient(fn)
        local saved = { C_Item = _G.C_Item, FriendlyForeverBuffList = _G.FriendlyForeverBuffList }
        local originals = { C_Item = {} }
        for _, name in ipairs(NAMES) do
            saved[name] = _G[name]
            originals[name] = function() return "simulator's " .. name end
            _G[name] = originals[name]
        end
        _G.C_Item = {}
        for _, name in ipairs(ITEM_NAMES) do
            originals.C_Item[name] = function() return "simulator's C_Item." .. name end
            _G.C_Item[name] = originals.C_Item[name]
        end
        local clicked = {}
        local function row(text)
            return { text = { GetText = function() return text end }, IsShown = function() return true end,
                GetScript = function() return function() clicked[#clicked + 1] = text end end }
        end
        _G.FriendlyForeverBuffList = { rows = { row("Sigrun Aasen: Power Word: Fortitude"),
            row("You: Elemental Sharpening Stone (main)") } }
        local ok, err = pcall(fn, originals, clicked)
        for name, value in pairs(saved) do _G[name] = value end
        assert.is_true(ok, tostring(err))
    end

    it("answers the weapon reads for its own items only, then picks your row in the list (white)", function()
        withClient(function(originals, clicked)
            local db = { buffBack = { weaponBuffs = false, weaponMain = "none", selfBuffs = true } }
            local States, log = load({ lenient = true, db = db })
            local W = States.WEAPON
            States.WeaponOffer.Set()
            assert.are.same({ true, W.kind, false },
                { db.buffBack.weaponBuffs, db.buffBack.weaponMain, db.buffBack.selfBuffs })
            local enchants = { GetWeaponEnchantInfo() }
            assert.is_false(enchants[1], "the main hand has an enchant")
            assert.is_false(enchants[5], "the off hand has an enchant")
            assert.are.equal(W.weapon, GetInventoryItemID("player", W.slot))
            assert.are.equal("simulator's GetInventoryItemID", GetInventoryItemID("player", 17))
            assert.are.equal("simulator's GetInventoryItemID", GetInventoryItemID("target", W.slot))
            for _, holder in ipairs({ _G, _G.C_Item }) do
                assert.are.equal(2, select(6, holder.GetItemInfoInstant(W.weapon)), "the axe isn't a weapon")
                assert.are.equal(0, select("#", holder.GetItemSpell(W.weapon)), "the axe has a Use")
                assert.are.equal(W.count, holder.GetItemCount(W.item))
                assert.is_true(holder.IsUsableItem(W.item))
                -- Any other item is the simulator's to count.
                local own = holder == _G and originals or originals.C_Item
                assert.are.equal(own.GetItemCount(), holder.GetItemCount(17020))
            end
            assert.are.equal("simulator's GetItemSpell", GetItemSpell(W.item))
            assert.are.equal("simulator's GetItemInfoInstant", GetItemInfoInstant(W.item))
            assert.are.equal("simulator's IsUsableItem", IsUsableItem(17020))
            assert.are.equal(W.name, _G.C_Item.GetItemNameByID(W.item))
            assert.are.equal("simulator's C_Item.GetItemNameByID", _G.C_Item.GetItemNameByID(17020))
            -- The favour first, then buff mode, then your row picked.
            local whole = table.concat(log, "\n")
            local target = whole:find("SetTarget " .. States.WEAPONSTRANGER, 1, true)
            local aura = whole:find("event UNIT_AURA", 1, true)
            local mode = whole:find("slash buffmode on", 1, true)
            assert.is_truthy(target and aura and mode and target < aura and aura < mode, whole)
            assert.are.same({ "You: Elemental Sharpening Stone (main)" }, clicked)
        end)
    end)

    it("puts every read and setting back on Undo, ends buff mode, and a second Undo changes nothing (white)", function()
        withClient(function(originals)
            local db = { buffBack = { weaponBuffs = false, weaponMain = "none", selfBuffs = true } }
            local States, log = load({ lenient = true, db = db })
            States.WeaponOffer.Set()
            States.WeaponOffer.Set() -- a second Set keeps the first one's saved reads
            States.WeaponOffer.Undo()
            assert.are.same({ weaponBuffs = false, weaponMain = "none", selfBuffs = true }, db.buffBack)
            for _, name in ipairs(NAMES) do assert.are.equal(originals[name], _G[name], name) end
            for _, name in ipairs(ITEM_NAMES) do assert.are.equal(originals.C_Item[name], _G.C_Item[name], name) end
            local whole = table.concat(log, "\n")
            assert.is_truthy(whole:find("slash buffmode off", 1, true), whole)
            assert.is_truthy(whole:find("ClearTarget", 1, true), whole)
            db.buffBack.weaponMain = "kept"
            States.WeaponOffer.Undo()
            assert.are.equal("kept", db.buffBack.weaponMain)
        end)
    end)

    it("fails loudly when the list has no row for your weapon buff (black)", function()
        withClient(function()
            _G.FriendlyForeverBuffList = { rows = {} }
            local States = load({ lenient = true, db = { buffBack = {} } })
            assert.has_error(function() States.WeaponOffer.Set() end, "the list has no row for your weapon buff")
            States.WeaponOffer.Undo()
        end)
    end)

    it("is a state the screenshot job stages and shoots as button-weapon, like every shown state (white)", function()
        local States = load({ lenient = true, db = { buffBack = {} } })
        local workflow = require("spec.support.wow").readFile(".github/workflows/ui-sim.yml")
        local list = workflow:match("\n%s*for state in ([%w ]+); do\n%s*{ cat uitests/button_states%.lua;")
        assert.is_truthy(list, "no staging loop over the button states")
        local staged = {}
        for name in list:gmatch("%S+") do staged[name] = true end
        local shown = {}
        for name in pairs(States.SHOWN) do shown[name] = true end
        assert.are.same(shown, staged, "the staged states aren't the ones Show knows")
        assert.is_true(staged.weapon)
        local all = workflow:match("shoot_all%(%) {\n(.-)\n%s*}\n")
        assert.is_truthy(all, "no shoot_all")
        for name in pairs(shown) do
            assert.is_truthy(all:find("\n%s*shoot button%-" .. name .. " %-%-exec%-lua @/shot%-lua/" .. name .. "%.lua\n"),
                "button-" .. name .. " isn't shot from its staged script")
        end
    end)

    it("is set up and hovered by Show, so the shot has the tooltip; an unknown state is an error (white, black)", function()
        withClient(function(_, clicked)
            local hovered = {}
            local before = _G.FriendlyForeverBuffButton
            _G.FriendlyForeverBuffButton = {
                GetScript = function(_, script) return function() hovered[#hovered + 1] = script end end,
                GetAttribute = function() return nil end, -- holding no macro, for Undo
            }
            local ok, err = pcall(function()
                local db = { buffBack = { weaponBuffs = false } }
                local States = load({ lenient = true, db = db })
                States.Show("weapon")
                assert.is_true(db.buffBack.weaponBuffs)
                assert.are.same({ "You: Elemental Sharpening Stone (main)" }, clicked)
                assert.are.same({ "OnEnter" }, hovered)
                States.WeaponOffer.Undo()
                assert.has_error(function() States.Show("nope") end, "no button state called nope")
            end)
            _G.FriendlyForeverBuffButton = before
            assert.is_true(ok, tostring(err))
        end)
    end)

    it("is the offer the addon makes from those answers: the best stone, and the words the scenario expects (white)", function()
        local States = load({ lenient = true, db = { buffBack = {} } })
        local W = States.WEAPON
        local wow = require("spec.support.wow")
        local ns = wow.boot({ db = { buffBack = { weaponBuffs = true, weaponMain = W.kind, selfBuffs = false } },
            before = function(state)
                state.class = "PRIEST"
                state.items = { [W.item] = W.count }
                state.itemNames = { [W.item] = W.name }
            end })
        -- The stone is the best of its kind, offered first; the hand is the main hand.
        assert.are.equal(W.item, ns.WeaponBuffs.KINDS[W.kind].items[1][1])
        assert.are.same({ W.slot, W.hand }, { ns.WeaponBuffs.HANDS[1].slot, ns.WeaponBuffs.HANDS[1].words })
        SlashCmdList.FRIENDLYFOREVER("buffmode on")
        local button = ns.BuffButton.Frame()
        assert.are.equal("You", button.title:GetText())
        assert.are.equal(W.name .. " on your " .. W.hand, button.subtitle:GetText())
        assert.are.equal(("/use item:%d\n/use %d"):format(W.item, W.slot),
            button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText))
        local list = ns.BuffList.Frame()
        assert.are.equal(("> You: %s (%s)"):format(W.name, W.row), list.rows[1].text:GetText())
    end)
end)

-- #500: a druid in a form, for the shift back, a refused one and the key's click to buff.
describe("UI scenarios: a druid in a form (#500, #452, #495)", function()
    local function withButton(fn)
        local saved = { button = _G.FriendlyForeverBuffButton, form = _G.GetShapeshiftForm,
            info = _G.GetShapeshiftFormInfo, id = _G.GetShapeshiftFormID, C_Spell = _G.C_Spell }
        local pressed = {}
        _G.FriendlyForeverBuffButton = {
            GetScript = function(_, script)
                return function(_, mouseButton, isDown)
                    pressed[#pressed + 1] = { script, mouseButton, isDown }
                end
            end,
            GetAttribute = function() return nil end,
        }
        _G.GetShapeshiftForm = function() return "simulator's form" end
        _G.GetShapeshiftFormInfo = function() return "simulator's info" end
        _G.GetShapeshiftFormID = function() return "simulator's id" end
        local ok, err = pcall(fn, pressed)
        _G.FriendlyForeverBuffButton, _G.GetShapeshiftForm = saved.button, saved.form
        _G.GetShapeshiftFormInfo, _G.GetShapeshiftFormID, _G.C_Spell = saved.info, saved.id, saved.C_Spell
        assert.is_true(ok, tostring(err))
    end

    it("shows the three states, each staged and shot by name (white)", function()
        local States = load({ lenient = true, db = { buffBack = {} } })
        assert.are.equal(States.FormBack, States.SHOWN.formback)
        assert.are.equal(States.FormRefused, States.SHOWN.formrefused)
        assert.are.equal(States.FormKey, States.SHOWN.formkey)
        -- The tooltip is drawn over the mode line, so only the shift back's shot hovers (#500).
        assert.is_function(States.FormBack.Hover)
        assert.is_nil(States.FormRefused.Hover)
        assert.is_nil(States.FormKey.Hover)
    end)

    it("leaves the form on a buff press, then buffs you, then presses again for the refusal (white)", function()
        withButton(function(pressed)
            local db = { buffBack = { fastCastInForm = false } }
            local States, log = load({ lenient = true, db = db })
            States.FormRefused.Set()
            assert.is_true(db.buffBack.fastCastInForm)
            assert.are.equal(2, #pressed, "a buff press, then a press of the shift back")
            assert.are.same({ "PreClick", "LeftButton", false }, pressed[1])
            local whole = table.concat(log, "\n")
            local sent = whole:find("event UNIT_SPELLCAST_SENT", 1, true)
            local buff = whole:find("AddBuff 9885", 1, true)
            local error = whole:find("event UI_ERROR_MESSAGE", 1, true)
            assert.is_truthy(sent and buff and error and sent < buff and buff < error, whole)
            -- Out of the form by now; the refusal's text is the long one.
            assert.are.equal(0, GetShapeshiftForm())
            States.FormRefused.Undo()
            assert.are.equal("simulator's form", GetShapeshiftForm())
            assert.is_false(db.buffBack.fastCastInForm)
        end)
    end)

    it("answers the form reads for its own form only, and the key's state never presses (white)", function()
        withButton(function(pressed)
            local db = { buffBack = {} }
            local States = load({ lenient = true, db = db })
            States.FormKey.Set()
            assert.are.equal(0, #pressed)
            assert.is_false(db.buffBack.fastCastInForm, "the key waits only with the setting off")
            assert.are.equal(1, GetShapeshiftForm())
            assert.are.equal(States.FORM.spell, select(4, GetShapeshiftFormInfo(1)))
            assert.are.equal("simulator's info", GetShapeshiftFormInfo(2))
            assert.are.equal("Dire Bear Form", States.FORM.name)
            States.FormKey.Undo()
        end)
    end)
end)

describe("UI scenarios: passers-by stopped for want of friendly nameplates (#521)", function()
    it("answers \"0\" for that setting alone, turns passers-by and buff mode on, and Undo puts all back (white)",
        function()
        local cvar, global = _G.C_CVar, _G.GetCVar
        local realGet = function(name) return "1 " .. name end
        local realGlobal = function(name) return "g " .. name end
        _G.C_CVar, _G.GetCVar = { GetCVar = realGet }, realGlobal
        local ok, err = pcall(function()
            local db = { buffBack = { passersBy = false } }
            local States, log = load({ lenient = true, db = db })
            assert.are.equal(States.PassersByNameplates, States.SHOWN.passersby)
            States.PassersByNameplates.Set()
            assert.are.equal("0", _G.C_CVar.GetCVar("nameplateShowFriendlyPlayers"))
            assert.are.equal("0", _G.GetCVar("nameplateShowFriendlyPlayers"))
            assert.are.equal("1 autoLootDefault", _G.C_CVar.GetCVar("autoLootDefault"), "every other setting is the client's")
            assert.is_true(db.buffBack.passersBy)
            local slashes = {}
            for _, entry in ipairs(log) do
                if entry:find("^slash ") then slashes[#slashes + 1] = entry end
            end
            assert.are.same({ "slash buffmode on" }, slashes)
            States.PassersByNameplates.Undo()
            assert.are.equal(realGet, _G.C_CVar.GetCVar)
            assert.are.equal(realGlobal, _G.GetCVar)
            assert.is_false(db.buffBack.passersBy)
        end)
        _G.C_CVar, _G.GetCVar = cvar, global
        assert(ok, err)
    end)
end)
