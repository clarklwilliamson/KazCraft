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
-- CreateFlatFrame — delegates to KazGUI:CreateFrame (HIGH strata, no shadow)
--------------------------------------------------------------------------------
function ns.CreateFlatFrame(name, w, h, parent)
    return KazGUI:CreateFrame(name, w, h, {
        parent = parent,
        strata = "HIGH",
        shadow = false,
        borderColor = "borderLight",
        escClose = false,
    })
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
    return KazGUI:CreateCloseButton(parent)
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

function ns.CreateScrollFrame(parent, topOffset, bottomOffset)
    return KazGUI:CreateClassicScrollFrame(parent, topOffset, bottomOffset)
end

function ns.FadeFrame(frame, targetAlpha, duration)
    return KazGUI:FadeFrame(frame, targetAlpha, duration)
end
