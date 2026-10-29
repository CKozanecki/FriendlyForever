-- A small window with a scrolling text box: shows text to copy (export, bug
-- report) or takes text to paste (import). One window, reused.
local _, ns = ...

local Window = {}
ns.Window = Window

Window.NAME = "FriendlyForeverTextWindow"

local frame

local function Create()
    frame = CreateFrame("Frame", Window.NAME, UIParent, "BasicFrameTemplateWithInset")
    -- Esc closes frames listed here, as it does the game's own windows.
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, Window.NAME) end
    frame:SetSize(520, 360)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.hint:SetPoint("TOPLEFT", 14, -32)
    frame.hint:SetPoint("RIGHT", -14, 0)
    frame.hint:SetJustifyH("LEFT")
    -- Up to two lines; the text box starts below the second, so a hint that
    -- wraps never runs into it (#52).
    frame.hint:SetMaxLines(2)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -64)
    scroll:SetPoint("BOTTOMRIGHT", -34, 44)
    frame.scroll = scroll
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetWidth(460)
    box:SetMaxLetters(0)
    box:SetScript("OnEscapePressed", function() frame:Hide() end)
    scroll:SetScrollChild(box)
    frame.box = box

    local accept = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    accept:SetSize(120, 22)
    accept:SetPoint("BOTTOMRIGHT", -14, 12)
    accept:SetScript("OnClick", function()
        if frame.onAccept then frame.onAccept(box:GetText()) end
    end)
    frame.accept = accept

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(90, 22)
    close:SetPoint("RIGHT", accept, "LEFT", -8, 0)
    close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.close = close
end

-- opts = { title, hint, text, acceptText, onAccept = function(text) }.
-- Without onAccept the text is selected, ready for Ctrl+C.
function Window.Show(opts)
    if not frame then Create() end
    frame.title:SetText(opts.title or ns.TITLE)
    frame.hint:SetText(opts.hint or "")
    frame.box:SetText(opts.text or "")
    frame.onAccept = opts.onAccept
    frame.accept:SetShown(opts.onAccept ~= nil)
    frame.accept:SetText(opts.acceptText or "OK")
    frame:Show()
    frame.box:SetFocus()
    if opts.onAccept then
        frame.box:SetCursorPosition(0)
    else
        frame.box:HighlightText()
    end
end

function Window.Hide()
    if frame then frame:Hide() end
end

function Window.Frame()
    return frame
end
