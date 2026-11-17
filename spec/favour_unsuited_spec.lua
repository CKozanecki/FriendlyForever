-- Spec: #419
-- A favour none of your buffs suit isn't owed, before the #408 choice too:
-- it isn't counted, holds no place on the button, and never turns buff mode
-- on or keeps it on. A favour whose class can't be read still counts (it
-- may yet show one your buffs suit).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local INTELLECT = 10157
local MOTW = 9885

-- The classes that use mana, written out here, not read from the addon:
-- Arcane Intellect is for them alone.
local MANA = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true,
    DRUID = true }
local CLASSES = { "WARRIOR", "ROGUE", "PALADIN", "HUNTER", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

describe("A favour none of your buffs suit isn't owed, before the #408 choice too (#419)", function()
    local ns

    -- A mage who knows only Arcane Intellect, with only the "someone buffed
    -- you" trigger on. choice: "kept" or "new"; nil leaves it pending.
    local function boot(choice, owedMinutes)
        ns = wow.boot({ autoBuffMode = true, buffDefaults = true,
            db = { buffBack = { autoOnJoin = false, autoOnDeath = false, autoOnMissing = false,
                autoOnBuffed = true, owedMinutes = owedMinutes } },
            before = function(state)
                state.class = "MAGE"
                state.knownSpells = { [INTELLECT] = true }
            end })
        ns.BuffButton.Frame()
        if choice then assert.is_true(ns.BuffRules.Choose(choice)) end
        assert.are.equal(choice or "pending", ns.BuffRules.Choice())
    end

    -- A stranger of class (nil: one that can't be read) buffs you.
    -- Each a new name: letters only, as the game's names are.
    local n = 0
    local function buffedBy(class)
        n = n + 1
        local name = "Str" .. string.char(97 + math.floor(n / 26) % 26, 97 + n % 26)
        local token = "nameplate" .. (n % 40 + 1)
        wow.addUnit(token, { name = name, surname = "Vale", id = name .. "-Vale", class = class })
        wow.gainBuff({ sourceUnit = token, name = "Mark of the Wild", spellId = MOTW })
        return name .. "-Vale"
    end

    for _, choice in ipairs({ false, "kept", "new" }) do
        local when = choice and ("after choosing \"" .. choice .. "\"") or "while the choice is pending"
        it(when .. ", a warrior's favour to a mage with only Intellect isn't counted and turns nothing on (white)",
            function()
            boot(choice or nil)
            buffedBy("WARRIOR")
            assert.are.equal(0, ns.Offers.Count())
            assert.is_false(ns.BuffMode.IsOn(), "nothing to give them: buff mode stays off")
            assert.is_nil(ns.BuffMode.LentKey())
            assert.are.same({ nil, "nobody is owed a buff" }, { ns.Offers.Current() })
        end)
    end

    it("while pending, a priest's favour is still owed, offered Intellect, and turns buff mode on (white)", function()
        boot(nil)
        buffedBy("PRIEST")
        assert.are.equal(1, ns.Offers.Count())
        assert.is_true(ns.BuffMode.IsOn())
        local offer = ns.Offers.Current()
        assert.are.equal("Arcane Intellect", offer.spell)
    end)

    it("while pending, a favour whose class can't be read still counts (black)", function()
        boot(nil)
        buffedBy(nil)
        assert.are.equal(1, ns.Offers.Count())
        assert.is_true(ns.BuffMode.IsOn(), "their class may yet show one Intellect suits")
    end)

    it("while pending, a mage who forgets Intellect owes nobody, and buff mode doesn't stay on for them (white)",
        function()
        boot(nil)
        buffedBy("PRIEST")
        assert.is_true(ns.BuffMode.IsOn())
        wow.state.knownSpells = {}
        wow.fire("SPELLS_CHANGED")
        assert.are.equal(0, ns.Offers.Count())
        ns.BuffButton.Refresh()
        assert.is_false(ns.BuffMode.IsOn(), "nothing to give: buff mode goes off")
    end)

    it("a storm of favours from every class, with Intellect learned and forgotten, never leaves buff mode on with "
        .. "nothing to give (red)", function()
        -- Classes Intellect doesn't suit come half the time, and favours run
        -- out after a minute, so "only favours you can't return" comes and
        -- goes. Each seed must reach both outcomes the storm is for.
        local UNSUITED = { "WARRIOR", "ROGUE" }
        local LIMIT = 60
        for _, seed in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) do
            random.seed(seed)
            boot(nil, LIMIT / 60)
            -- Who has buffed you, their class as the game shows it, and when.
            local owed = {}
            local reached = { unsuitedOnly = 0, onThenNothing = 0 }
            for _ = 1, 40 do
                local wasOn = ns.BuffMode.IsOn()
                local roll = random.random(4)
                if roll == 1 then
                    local known = wow.state.knownSpells[INTELLECT] == true
                    wow.state.knownSpells = known and {} or { [INTELLECT] = true }
                    wow.fire("SPELLS_CHANGED")
                else
                    local class
                    if random.random(2) == 1 then
                        class = UNSUITED[random.random(#UNSUITED)]
                    else
                        class = CLASSES[random.random(#CLASSES + 1)] -- one past the end: can't be read
                    end
                    owed[buffedBy(class)] = { class = class, at = wow.now }
                end
                wow.advance(random.random(1, 30))
                ns.BuffButton.Refresh()
                -- Worked out from the client's own state, not the addon's:
                -- a favour lasts LIMIT seconds.
                local live, suits = 0, 0
                for name, f in pairs(owed) do
                    if wow.now - f.at > LIMIT then
                        owed[name] = nil
                    else
                        live = live + 1
                        if wow.state.knownSpells[INTELLECT] and (f.class == nil or MANA[f.class]) then
                            suits = suits + 1
                        end
                    end
                end
                assert.are.equal(suits, ns.Offers.Count(), "seed " .. seed)
                if suits == 0 then
                    assert.is_false(ns.BuffMode.IsOn(), "seed " .. seed .. ": on with nothing to give")
                    assert.is_nil(ns.Offers.Current(), "seed " .. seed)
                    if wasOn then reached.onThenNothing = reached.onThenNothing + 1 end
                    if live > 0 and wow.state.knownSpells[INTELLECT] then
                        reached.unsuitedOnly = reached.unsuitedOnly + 1
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(reached.unsuitedOnly > 0, "seed " .. seed .. " never owed only favours Intellect can't suit")
            assert.is_true(reached.onThenNothing > 0, "seed " .. seed .. " never had buff mode on, then nothing to give")
        end
    end)
end)
