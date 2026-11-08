-- The list beside the buff-back button (#43): everyone the button would
-- offer to, and the buff for each. Clicking a row makes that player the
-- button's next offer. Nothing here casts: rows are plain buttons (a secure
-- one can't be changed in a fight), so casting still goes through the one
-- secure button, on the player's own press.
--
-- The offers come from BuffButton.lua, which makes them with the same rules
-- it uses to arm the button (Offers.lua, GroupBuffs.lua): there is no second
-- copy of those rules here. The list is hidden in combat and whenever it has
-- nothing to show. It scrolls when it grows (docs/visual-style.md).
local _, ns = ...
local Util = ns.Util

local BuffList = {}
ns.BuffList = BuffList

BuffList.FRAME_NAME = "FriendlyForeverBuffList"
BuffList.ROW_HEIGHT = 18
BuffList.WIDTH = 230
BuffList.VISIBLE_ROWS = 6   -- rows shown before the list scrolls
BuffList.MAX_ROWS = 60      -- rows kept: 20 favours (Offers.MAX) and a raid of 40 can't exceed it

local frame, scroll, content
local rows = {}
local shownOffers = {}   -- the offers the rows show, in order

-- One row's text: the player's name, the buff, and a mark on the offer the
-- button holds now (colour alone isn't enough).
local function RowText(offer, current)
    local name = Util.StripChat(Util.DisplayName(offer.name))
    return (current and "> " or "") .. name .. ": " .. Util.StripChat(offer.spell)
end

local function MakeRow(i)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(BuffList.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * BuffList.ROW_HEIGHT)
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp")
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(ns.Colours.RGBA("shade"))
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", -4, 0)
    row.text:SetJustifyH("LEFT")
    -- One line: the game cuts what doesn't fit with "...", however long the name.
    row.text:SetWordWrap(false)
    row:SetScript("OnClick", function()
        ns.Diag.Call(function()
            local offer = shownOffers[i]
            if offer then ns.BuffButton.Choose(offer.name) end
        end)
    end)
    return row
end

local function Create(button)
    frame = CreateFrame("Frame", BuffList.FRAME_NAME, UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetWidth(BuffList.WIDTH)
    -- Beside the button, level with its top.
    frame:SetPoint("TOPLEFT", button, "TOPRIGHT", 6, 0)
    frame.rows = rows
    frame:Hide()
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(ns.Colours.RGBA("shade"))
    scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -22, 0)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(BuffList.WIDTH - 22, BuffList.ROW_HEIGHT)
    scroll:SetScrollChild(content)
end

-- Show these offers (the first row's offer is what the button holds unless
-- another is chosen), marking current, the name the button holds. Hidden
-- when there is nothing to show or the player is in combat.
function BuffList.Update(button, offers, current)
    if InCombatLockdown() then return BuffList.Hide() end
    if not offers or #offers == 0 then return BuffList.Hide() end
    if not frame then Create(button) end
    for i = #shownOffers, 1, -1 do shownOffers[i] = nil end
    local count = math.min(#offers, BuffList.MAX_ROWS)
    for i = 1, count do
        shownOffers[i] = offers[i]
        rows[i] = rows[i] or MakeRow(i)
        rows[i].text:SetText(RowText(offers[i], offers[i].name == current))
        rows[i]:Show()
    end
    for i = count + 1, #rows do rows[i]:Hide() end
    content:SetHeight(count * BuffList.ROW_HEIGHT)
    frame:SetHeight(math.min(count, BuffList.VISIBLE_ROWS) * BuffList.ROW_HEIGHT)
    frame:Show()
end

function BuffList.Hide()
    if frame and frame:IsShown() then frame:Hide() end
end

-- For the tests and the UI scenarios.
function BuffList.Frame() return frame end
function BuffList.Rows() return rows end
function BuffList.ShownOffers() return shownOffers end
