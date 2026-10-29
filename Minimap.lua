-- Minimap button: left-click opens options, right-click turns the addon
-- on/off, drag moves it around the minimap edge. The same entry goes in the
-- addon compartment (the drop-down of addons by the minimap), where the
-- client has one.
local _, ns = ...

local MinimapButton = {}
ns.Minimap = MinimapButton

-- Our own icon (#65): the logo's heart and sparkle on a navy disc. The same
-- texture is the AddOns list's ## IconTexture in the TOC.
MinimapButton.ICON = "Interface\\AddOns\\FriendlyForever\\Media\\Icon"
MinimapButton.EDGE_OFFSET = 5

local button

-- Angle in degrees [0, 360) from the minimap centre to the cursor.
function MinimapButton.AngleFromCursor(centerX, centerY, cursorX, cursorY, scale)
    return math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
end

-- x, y offset from the minimap centre for a button at this angle.
function MinimapButton.OffsetForAngle(angle, minimapWidth)
    local radius = minimapWidth / 2 + MinimapButton.EDGE_OFFSET
    local rad = math.rad(angle)
    return math.cos(rad) * radius, math.sin(rad) * radius
end

local function UpdatePosition()
    local x, y = MinimapButton.OffsetForAngle(ns.db.minimap.angle, Minimap:GetWidth())
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnDragUpdate()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local angle = MinimapButton.AngleFromCursor(centerX, centerY, cursorX, cursorY, Minimap:GetEffectiveScale())
    ns.db.minimap.angle = math.floor(angle + 0.5) % 360
    UpdatePosition()
end

function MinimapButton.Refresh()
    if not button then return end
    button:SetShown(not ns.db.minimap.hide)
    button.icon:SetDesaturated(not ns.db.enabled or ns.Announcer.SnoozeLeft() ~= nil)
end

local function FillTooltip(tooltip)
    tooltip:AddLine(ns.TITLE)
    local snoozed = ns.Announcer.SnoozeLeft()
    if not ns.db.enabled then
        tooltip:AddLine("|cffff4040Disabled|r")
    elseif snoozed then
        tooltip:AddLine(string.format("|cffffd040Snoozed|r (%d min left)", math.ceil(snoozed / 60)))
    else
        tooltip:AddLine("|cff00ff00Enabled|r")
    end
    tooltip:AddLine(ns.LedgerSummaryText(), 0.8, 0.8, 0.8, true)
end

local function OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    FillTooltip(GameTooltip)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffffffLeft-click:|r open options", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffRight-click:|r turn on/off", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffDrag:|r move button", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function MinimapButton.OnClick(_, mouseButton)
    if mouseButton == "RightButton" then
        ns.SetEnabled(not ns.db.enabled)
    else
        ns.Options.Open()
    end
    GameTooltip:Hide()
end

function MinimapButton.Create()
    if button then return end
    button = CreateFrame("Button", "FriendlyForeverMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MinimapButton.ICON)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", MinimapButton.OnClick)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
    MinimapButton.Refresh()
    MinimapButton.RegisterCompartment()
end

local compartment

-- The addon compartment's entry: left-click opens options, right-click
-- turns the addon on or off, as on the minimap button.
function MinimapButton.RegisterCompartment()
    local frame = AddonCompartmentFrame
    if compartment or type(frame) ~= "table" or type(frame.RegisterAddon) ~= "function" then return false end
    compartment = {
        text = ns.TITLE,
        icon = MinimapButton.ICON,
        notCheckable = true,
        registerForAnyClick = true,
        func = ns.Diag.Wrap(function(_, input)
            local which = type(input) == "table" and input.buttonName or "LeftButton"
            MinimapButton.OnClick(nil, which)
        end),
        funcOnEnter = ns.Diag.Wrap(function(owner)
            GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
            FillTooltip(GameTooltip)
            GameTooltip:AddLine("|cffffffffClick:|r options  |cffffffffRight-click:|r on/off", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end),
        funcOnLeave = function() GameTooltip:Hide() end,
    }
    local ok = pcall(frame.RegisterAddon, frame, compartment)
    if not ok then compartment = nil end
    return ok
end
