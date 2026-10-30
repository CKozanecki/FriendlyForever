-- Spec: #46
-- The one colour palette: every colour defined once in Colours.lua and used
-- by name, readable on the game's dark backgrounds and for colour-vision
-- deficiency, and never the only way meaning is shown.
local wow = require("spec.support.wow")

-- Lua source split into code and string literals, with comments dropped, so
-- prose can't trip a check and a string can't hide a call.
local function lex(source)
    local code, strings = {}, {}
    local i, n = 1, #source
    while i <= n do
        local c = source:sub(i, i)
        local long = source:match("^%[(=*)%[", i)
        if source:sub(i, i + 1) == "--" then
            local level = source:match("^%-%-%[(=*)%[", i)
            local close = level and source:find("]" .. level .. "]", i, true)
            i = close and close + #level + 2 or (source:find("\n", i, true) or n + 1)
        elseif long then
            local close = source:find("]" .. long .. "]", i, true) or n
            strings[#strings + 1] = source:sub(i + #long + 2, close - 1)
            code[#code + 1] = '""'
            i = close + #long + 2
        elseif c == '"' or c == "'" then
            local j, parts = i + 1, {}
            while j <= n and source:sub(j, j) ~= c do
                if source:sub(j, j) == "\\" then
                    parts[#parts + 1] = source:sub(j, j + 1)
                    j = j + 2
                else
                    parts[#parts + 1] = source:sub(j, j)
                    j = j + 1
                end
            end
            strings[#strings + 1] = table.concat(parts)
            code[#code + 1] = '""'
            i = j + 1
        else
            code[#code + 1] = c
            i = i + 1
        end
    end
    return table.concat(code), strings
end

-- What's wrong with a source file's colours: a list of reasons, empty when
-- every colour comes from the palette by name.
local function strayColours(source)
    local found = {}
    local code, strings = lex(source)
    for _, text in ipairs(strings) do
        -- A colour escape. "||c" is a pipe the game shows as text, and "|c%x"
        -- is a pattern that strips colours, so neither counts.
        local plain = text:gsub("||", "")
        if plain:find("|c[^%%]") or plain:find("|c$") then found[#found + 1] = "colour escape: " .. text end
        -- A pipe written as an escape, which could build one.
        if text:find("\\124") or text:find("\\x7[cC]") then found[#found + 1] = "escaped pipe: " .. text end
    end
    -- The game's colour calls (SetTextColor, SetColorTexture, SetVertexColor,
    -- SetBackdropColor, CreateColor and the rest) take their colour from the
    -- palette, by name.
    for name, args in code:gmatch("([%w_]*Color[%w_]*)%s*(%b())") do
        if not args:find("Colours%.RGBA?%(") then found[#found + 1] = "colour call: " .. name .. args end
    end
    -- A tooltip line's, text's or chat line's colour, given as numbers: any
    -- number after the text (AddLine, AddDoubleLine, SetText, AddMessage).
    for _, call in ipairs({ "Add%a*Line", "SetText", "AddMessage" }) do
        for name, args in code:gmatch("(" .. call .. ")%s*(%b())") do
            if args:find(",%s*%-?%.?%d") then found[#found + 1] = "text colour: " .. name .. args end
        end
    end
    -- The game's own colour tables and codes (NORMAL_FONT_COLOR,
    -- RAID_CLASS_COLORS, RED_FONT_COLOR_CODE and the like).
    for name in code:gmatch("[%w_]*COLOR[%w_]*") do found[#found + 1] = "game colour: " .. name end
    return found
end

-- Every file at the top of the addon that could ship code: Lua and XML.
local function addonFiles()
    local handle = io.popen('ls "' .. wow.ROOT .. '"')
    local files = {}
    for name in handle:read("*a"):gmatch("[^\n]+") do
        if name:match("%.lua$") or name:match("%.xml$") then files[#files + 1] = name end
    end
    handle:close()
    return files
end

-- WCAG relative luminance and contrast, worked out here from the hex, not by
-- the addon.
local function channel(hex, at)
    local v = tonumber(hex:sub(at, at + 1), 16) / 255
    return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end
local function linear(hex) return { channel(hex, 1), channel(hex, 3), channel(hex, 5) } end
local function luminance(rgb) return 0.2126 * rgb[1] + 0.7152 * rgb[2] + 0.0722 * rgb[3] end
local function contrast(a, b)
    local la, lb = luminance(linear(a)), luminance(linear(b))
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end

-- Colour-vision deficiency, simulated with Machado, Oliveira and Fernandes
-- (2009) at full severity, in linear RGB.
local CVD = {
    deuteranopia = { { 0.367322, 0.860646, -0.227968 }, { 0.280085, 0.672501, 0.047413 },
        { -0.011820, 0.042940, 0.968881 } },
    protanopia = { { 0.152286, 1.052583, -0.204868 }, { 0.114503, 0.786281, 0.099216 },
        { -0.003882, -0.048116, 1.051998 } },
    tritanopia = { { 1.255528, -0.076749, -0.178779 }, { -0.078411, 0.930809, 0.147602 },
        { 0.004733, 0.691367, 0.303900 } },
}
local function simulate(rgb, m)
    local out = {}
    for i = 1, 3 do
        local v = m[i][1] * rgb[1] + m[i][2] * rgb[2] + m[i][3] * rgb[3]
        out[i] = math.min(1, math.max(0, v))
    end
    return out
end
-- CIELAB distance (CIE76) between two linear RGB colours.
local function lab(rgb)
    local x = (0.4124 * rgb[1] + 0.3576 * rgb[2] + 0.1805 * rgb[3]) / 0.95047
    local y = 0.2126 * rgb[1] + 0.7152 * rgb[2] + 0.0722 * rgb[3]
    local z = (0.0193 * rgb[1] + 0.1192 * rgb[2] + 0.9505 * rgb[3]) / 1.08883
    local function f(t) return t > 0.008856 and t ^ (1 / 3) or 7.787 * t + 16 / 116 end
    return { 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)) }
end
local function distance(a, b)
    local p, q = lab(a), lab(b)
    return math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2 + (p[3] - q[3]) ^ 2)
end

-- The game's dark backgrounds: the chat frame and screen behind it at their
-- darkest, the tooltip's navy, and the options window's dark grey panel.
local BACKGROUNDS = { black = "000000", tooltip = "0b1229", panel = "262626" }

describe("Colours", function()
    local ns
    before_each(function() ns = wow.boot() end)

    describe("one palette, used by name", function()
        it("every colour is defined once, as six hex digits", function()
            local seen = {}
            for name, hex in pairs(ns.Colours.HEX) do
                assert.is_truthy(hex:match("^%x%x%x%x%x%x$"), name)
                assert.is_nil(seen[hex], name .. " repeats " .. tostring(seen[hex]))
                seen[hex] = name
            end
        end)

        it("no file outside the palette has a stray colour code", function()
            local files = addonFiles()
            assert.is_true(#files > 20, "found the addon's files")
            for _, file in ipairs(files) do
                if file ~= "Colours.lua" then
                    assert.are.same({}, strayColours(wow.readFile(file)), file)
                end
            end
        end)

        it("the check passes colours taken from the palette by name", function()
            assert.are.same({}, strayColours(table.concat({
                'ns.Print(ns.Colours.Text("good", "on"))',
                'background:SetColorTexture(ns.Colours.RGBA("shade"))',
                'label:SetTextColor(ns.Colours.RGB("muted"))',
                'local r, g, b = ns.Colours.RGB("text")',
                'GameTooltip:AddLine("Hi", r, g, b, true)',
                'GameTooltip:AddLine(ns.TITLE)',
                'label:SetText(("%d left"):format(3))',
                'GameTooltip:SetText(self.tooltip, r, g, b, a, true)',
                'local plain = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")',
                'local shown = "a||cffb"',
                '-- a comment saying |cffff0000 or SetTextColor(1, 0, 0)',
                '--[[ a block comment: NORMAL_FONT_COLOR ]]',
            }, "\n")))
        end)
    end)

    describe("a stray colour code fails the check", function()
        local STRAYS = {
            escape = 'ns.Print("|cff00ff00on|r")',
            ["escape in single quotes"] = "ns.Print('|cFFFF0000off|r')",
            ["escape in a long string"] = 'local s = [[|cff999999hint|r]]',
            ["named escape"] = 'ns.Print("|cnGREEN_FONT_COLOR:on|r")',
            ["escape built from pieces"] = 'ns.Print("|c" .. hex .. "on|r")',
            ["escaped pipe"] = 'ns.Print("\\124cff00ff00on")',
            ["hex-escaped pipe"] = 'ns.Print("\\x7Ccff00ff00on")',
            SetTextColor = "label:SetTextColor(1, 0.82, 0)",
            ["SetTextColor from elsewhere"] = "label:SetTextColor(r, g, b)",
            SetColorTexture = "tex:SetColorTexture(0, 0, 0, 0.6)",
            SetVertexColor = "icon:SetVertexColor(.5, .5, .5)",
            SetBackdropColor = "frame:SetBackdropColor(0, 0, 0)",
            CreateColor = "local c = CreateColor(1, 1, 1)",
            ["AddLine colour"] = 'GameTooltip:AddLine("x", 0.8, 0.8, 0.8)',
            ["AddDoubleLine colour"] = 'GameTooltip:AddDoubleLine("a", "b", 1, 1, 1, 1, 1, 1)',
            ["tooltip SetText colour"] = "GameTooltip:SetText(self.tooltip, 1, 1, 1, 1, true)",
            ["chat AddMessage colour"] = 'DEFAULT_CHAT_FRAME:AddMessage("[FF debug] " .. line, 0.6, 0.6, 0.6)',
            ["game colour table"] = "local c = NORMAL_FONT_COLOR",
            ["game colour code"] = 'ns.Print(RED_FONT_COLOR_CODE .. "off")',
            ["class colours"] = "local c = RAID_CLASS_COLORS.PRIEST",
            WrapTextInColorCode = 'local s = WrapTextInColorCode("x", "ff00ff00")',
        }
        for label, source in pairs(STRAYS) do
            it(label, function() assert.are.equal(1, #strayColours(source), source) end)
        end
    end)

    describe("readable on the game's dark backgrounds", function()
        for bg, bgHex in pairs(BACKGROUNDS) do
            it("every text colour reads at least 4.5:1 (WCAG AA) on " .. bg, function()
                for name, hex in pairs(ns.Colours.HEX) do
                    if name ~= "shade" then
                        local ratio = contrast(hex, bgHex)
                        assert.is_true(ratio >= 4.5, string.format("%s on %s: %.2f", name, bg, ratio))
                    end
                end
            end)
        end
    end)

    describe("readable for colour-vision deficiency", function()
        for kind, matrix in pairs(CVD) do
            it("good and bad stay clearly apart under " .. kind, function()
                local good, bad = linear(ns.Colours.HEX.good), linear(ns.Colours.HEX.bad)
                local apart = distance(simulate(good, matrix), simulate(bad, matrix))
                -- The colours they replaced (00ff00 and ff4040) were 32 apart
                -- under deuteranopia.
                assert.is_true(apart >= 35, string.format("%s: %.1f", kind, apart))
            end)
        end
    end)

    describe("colour never carries meaning alone", function()
        local function plain(text) return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

        it("on and off, enabled and disabled are words", function()
            _G.SlashCmdList.FRIENDLYFOREVER("off")
            _G.SlashCmdList.FRIENDLYFOREVER("on")
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            local printed = plain(table.concat(wow.printed, "\n"))
            assert.is_truthy(printed:find(": disabled", 1, true))
            assert.is_truthy(printed:find(": enabled", 1, true))
            assert.is_truthy(printed:find("skip while AFK: on", 1, true))
            assert.is_truthy(printed:find("debug off", 1, true))
        end)
    end)

    describe("by name", function()
        it("Text wraps text in the named colour", function()
            assert.are.equal("|cff" .. ns.Colours.HEX.good .. "on|r", ns.Colours.Text("good", "on"))
        end)

        it("RGB gives exactly three values from 0 to 1, so a tooltip line's wrap flag is untouched", function()
            assert.are.equal(3, select("#", ns.Colours.RGB("title")))
            local r, g, b = ns.Colours.RGB("title")
            assert.are.equal(0xff / 255, r)
            assert.are.equal(0xd2 / 255, g)
            assert.are.equal(0x7a / 255, b)
        end)

        it("RGBA adds the colour's opacity: the shade's, or fully opaque", function()
            assert.are.same({ 0, 0, 0, 0.6 }, { ns.Colours.RGBA("shade") })
            assert.are.equal(1, select(4, ns.Colours.RGBA("good")))
        end)
    end)

    describe("after an update that adds Colours.lua and a /reload (no restart)", function()
        it("asks for a restart instead of erroring, and sends nothing", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "Colours.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.advance(60)
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            wow.keyDown()
            assert.are.same({}, wow.errors)
            assert.are.same({}, wow.sent)
            assert.is_truthy(table.concat(wow.printed, "\n"):find(
                "Friendly Forever: this update added files. Restart the game (not /reload)", 1, true))
        end)
    end)

    describe("bad input", function()
        it("an unknown name leaves text plain and reads as white", function()
            assert.are.equal("on", ns.Colours.Text("nope", "on"))
            assert.are.equal("on", ns.Colours.Text(nil, "on"))
            assert.are.same({ 1, 1, 1 }, { ns.Colours.RGB("nope") })
            assert.are.same({ 1, 1, 1, 1 }, { ns.Colours.RGBA({}) })
        end)

        it("text that isn't a string is shown as text", function()
            assert.are.equal("|cff" .. ns.Colours.HEX.muted .. "42|r", ns.Colours.Text("muted", 42))
            assert.are.equal("|cff" .. ns.Colours.HEX.muted .. "nil|r", ns.Colours.Text("muted", nil))
        end)
    end)
end)
