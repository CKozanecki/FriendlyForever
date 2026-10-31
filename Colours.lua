-- The addon's one colour palette (#46). Every colour the addon shows is named
-- here and used by name: chat output, the options pages, the buff-back
-- button and the minimap tooltip. A repo test (spec/colours_spec.lua) fails
-- on a colour code anywhere else.
--
-- Drawn from the logo (art/): its gold, its orange, and a sky blue that
-- stands against its navy. Every colour reads at least 4.5:1 (WCAG AA) on
-- black, on the tooltip's navy and on a dark grey panel, and good and bad
-- stay apart under simulated deuteranopia, protanopia and tritanopia; the
-- numbers are on #46. Colour never carries meaning alone: "on" and "off",
-- "Enabled" and "Disabled" stay in words.
local _, ns = ...

local Colours = {}
ns.Colours = Colours

-- [name] = "rrggbb".
Colours.HEX = {
    title = "ffd27a", -- logo gold: the addon's name, headings and labels
    good = "6cc8ff", -- sky blue: on, enabled, sent, open
    bad = "ff6e86", -- rose: off, disabled, errors
    warn = "f5a623", -- logo orange: snoozed, notes and warnings
    muted = "a8adbf", -- grey-blue: hints in brackets, debug lines
    text = "d6d6d6", -- light grey: tooltip body text
    bright = "ffffff", -- white: the click a tooltip line names, and what a click casts
    shade = "000000", -- black: the dim panel behind the buff-back button's text
}

-- The shade's opacity.
local ALPHA = { shade = 0.6 }

-- name -> r, g, b, from 0 to 1. Exactly three values, so it can end a
-- tooltip's AddLine without setting its wrap flag; a wrapped line takes them
-- into locals first. An unknown name is a bug in the addon, not the
-- player's, so it reads as white rather than failing.
function Colours.RGB(name)
    local hex = Colours.HEX[name] or "ffffff"
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- name -> r, g, b and its opacity, for a texture.
function Colours.RGBA(name)
    local r, g, b = Colours.RGB(name)
    return r, g, b, ALPHA[name] or 1
end

-- text, wrapped in the colour's escape. An unknown name leaves it plain.
function Colours.Text(name, text)
    text = tostring(text)
    local hex = Colours.HEX[name]
    if not hex then return text end
    return "|cff" .. hex .. text .. "|r"
end
