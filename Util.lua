local addonName, ns = ...

--------------------------------------------------------------------------------
-- KazCraft Util.lua — Thin shim over KazGUILib
-- All widget/color/helper logic lives in KazGUILib. This file maps ns.* calls
-- so existing consumer files (Core, ProfessionFrame, AHUI, etc.) work unchanged.
--------------------------------------------------------------------------------

local KazGUI = LibStub("KazGUILib-1.0")

--------------------------------------------------------------------------------
-- Color mapping: ns.COLORS → KazGUI.Colors via __index metatable
--------------------------------------------------------------------------------
local COLOR_MAP = {
    backdrop     = "bg",
    border       = "borderLight",
    panelBg      = "panelBg",
    panelBorder  = "border",
    footerBg     = "footerBg",
    tabInactive  = "tabInactive",
    tabHover     = "ctrlHover",
    tabActive    = "accent",
    accent       = "accentBronze",
    rowDivider   = "rowDivider",
    rowHover     = "rowHover",
    rowSelected  = "rowSelected",
    headerText   = "textHeader",
    brightText   = "textNormal",
    mutedText    = "textMuted",
    greenText    = "green",
    redText      = "red",
    goldText     = "gold",
    searchBg     = "searchBg",
    searchBorder = "border",
    searchFocus  = "searchFocus",
    scrollThumb  = "scrollThumb",
    scrollTrack  = "scrollTrack",
    btnDefault   = "ctrlText",
    btnHover     = "ctrlHover",
    closeDefault = "closeNormal",
    closeHover   = "closeHover",
}

ns.COLORS = setmetatable({}, {
    __index = function(_, key)
        local mapped = COLOR_MAP[key]
        if mapped then return KazGUI.Colors[mapped] end
        return KazGUI.Colors[key]
    end,
})

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
ns.FONT      = KazGUI.Constants.FONT
ns.ROW_HEIGHT = KazGUI.Constants.ROW_HEIGHT_LARGE
ns.ICON_SIZE  = KazGUI.Constants.ICON_SIZE

--------------------------------------------------------------------------------
-- Backdrop templates (kept local for CreateFlatFrame)
--------------------------------------------------------------------------------
local BACKDROP_FLAT = {
    bgFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeSize = 1,
}

--------------------------------------------------------------------------------
-- CreateFlatFrame — NOT delegated to KazGUI:CreateFrame (different strata/shadow)
--------------------------------------------------------------------------------
function ns.CreateFlatFrame(name, w, h, parent)
    local f = CreateFrame("Frame", name, parent or UIParent, "BackdropTemplate")
    f:SetSize(w, h)
    f:SetBackdrop(BACKDROP_FLAT)
    f:SetBackdropColor(unpack(KazGUI.Colors.bg))
    f:SetBackdropBorderColor(unpack(KazGUI.Colors.borderLight))
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self.SavePosition then self:SavePosition() end
    end)
    return f
end

--------------------------------------------------------------------------------
-- Widget shims — delegate to KazGUILib
--------------------------------------------------------------------------------
function ns.CreateRow(parent, index, height)
    return KazGUI:CreateListRow(parent, index, height)
end

function ns.CreateTabBar(parent, tabs, onSelect)
    return KazGUI:CreateTabBar(parent, tabs, onSelect)
end

function ns.CreateButton(parent, text, w, h)
    return KazGUI:CreateButton(parent, text, w, h)
end

function ns.CreateCloseButton(parent)
    local C = KazGUI.Colors
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 20)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    btn.label = btn:CreateFontString(nil, "OVERLAY")
    btn.label:SetFont(KazGUI.Constants.FONT, 14, "")
    btn.label:SetPoint("CENTER")
    btn.label:SetText("x")
    btn.label:SetTextColor(unpack(C.closeNormal))

    btn:SetScript("OnEnter", function(self)
        self.label:SetTextColor(unpack(C.closeHover))
    end)
    btn:SetScript("OnLeave", function(self)
        self.label:SetTextColor(unpack(C.closeNormal))
    end)
    btn:SetScript("OnClick", function()
        parent:Hide()
    end)

    return btn
end

function ns.FormatGold(copper)
    return KazGUI:FormatGold(copper)
end

--------------------------------------------------------------------------------
-- Crafting quality helpers
--------------------------------------------------------------------------------
function ns.GetCraftingQuality(itemID)
    return KazGUI:GetCraftingQuality(itemID)
end

function ns.GetQualityAtlas(tier)
    return KazGUI:GetQualityAtlas(tier)
end

--------------------------------------------------------------------------------
-- Stubs for unused functions (kept for safety)
--------------------------------------------------------------------------------
function ns.CreateScrollFrame(parent, topOffset, bottomOffset)
    topOffset = topOffset or 0
    bottomOffset = bottomOffset or 0

    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -topOffset)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -20, bottomOffset)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth())
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)

    local scrollBar = scrollFrame.ScrollBar
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 2, -16)
        scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 2, 16)
    end

    scrollFrame.content = content
    return scrollFrame
end

function ns.FadeFrame(frame, targetAlpha, duration)
    if not frame then return end
    duration = duration or 0.2
    if targetAlpha > 0 then frame:Show() end
    local startAlpha = frame:GetAlpha()
    if math.abs(startAlpha - targetAlpha) < 0.01 then
        frame:SetAlpha(targetAlpha)
        if targetAlpha == 0 then frame:Hide() end
        return
    end
    local startTime = GetTime()
    if frame._fadeTicker then frame._fadeTicker:Cancel() end
    frame._fadeTicker = C_Timer.NewTicker(0.016, function(ticker)
        local elapsed = GetTime() - startTime
        local pct = math.min(1, elapsed / duration)
        frame:SetAlpha(startAlpha + (targetAlpha - startAlpha) * pct)
        if pct >= 1 then
            ticker:Cancel()
            frame._fadeTicker = nil
            if targetAlpha == 0 then frame:Hide() end
        end
    end)
end
