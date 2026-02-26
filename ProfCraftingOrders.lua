local addonName, ns = ...

local ProfOrders = {}
ns.ProfOrders = ProfOrders

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------
local LEFT_PANEL_WIDTH = 340
local ROW_HEIGHT = 32
local VISIBLE_ROWS = 14
local ORDER_TYPE_TAB_HEIGHT = 26
local SEARCH_HEIGHT = 26
local DETAIL_ICON_SIZE = 40
local REAGENT_ROW_HEIGHT = 22
local REAGENT_ICON_SIZE = 18

-- Order type tab definitions
local ORDER_TYPES = {
    { key = "npc",      label = "Patron",   type = Enum.CraftingOrderType.Npc },
    { key = "guild",    label = "Guild",    type = Enum.CraftingOrderType.Guild },
    { key = "public",   label = "Public",   type = Enum.CraftingOrderType.Public },
    { key = "personal", label = "Personal", type = Enum.CraftingOrderType.Personal },
}

-- Sort options
local SORT_OPTIONS = {
    { label = "Item Name",  sort = Enum.CraftingOrderSortType.ItemName },
    { label = "Tip",        sort = Enum.CraftingOrderSortType.Tip },
    { label = "Time Left",  sort = Enum.CraftingOrderSortType.TimeRemaining },
    { label = "Reagents",   sort = Enum.CraftingOrderSortType.Reagents },
}

local BUCKET_SORT_OPTIONS = {
    { label = "Item Name", sort = Enum.CraftingOrderSortType.ItemName },
    { label = "Avg Tip",   sort = Enum.CraftingOrderSortType.AveTip },
    { label = "Max Tip",   sort = Enum.CraftingOrderSortType.MaxTip },
    { label = "Quantity",  sort = Enum.CraftingOrderSortType.Quantity },
}

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------
local initialized = false
local parentFrame

-- UI refs
local mainPanel
local unavailableOverlay
local orderTypeTabs = {}
local leftPanel, rightPanel
local searchBox
local sortBtn
local listFrame
local listRows = {}
local scrollBar
local detailFrame

-- Data state
local activeOrderType = Enum.CraftingOrderType.Npc
local currentOrders = {}        -- CraftingOrderInfo[] or CraftingOrderBucketInfo[]
local displayBuckets = false    -- true = bucketed view (public), false = flat list
local selectedOrder = nil       -- CraftingOrderInfo or nil
local selectedBucket = nil      -- CraftingOrderBucketInfo or nil (drilldown source)
local claimedOrder = nil        -- the one claimed order (from GetClaimedOrder)
local scrollOffset = 0
local expectMoreRows = false
local currentOffset = 0         -- pagination offset for server requests
local isLoading = false
local primarySort = { sortType = Enum.CraftingOrderSortType.ItemName, reversed = false }
local secondarySort = { sortType = Enum.CraftingOrderSortType.Tip, reversed = true }
local searchText = ""
local professionEnum = nil      -- Enum.Profession value

-- Event frame
local eventFrame

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------
local function GetProfessionEnum()
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    if profInfo and profInfo.profession then
        return profInfo.profession
    end
    return nil
end

local function IsAtCraftingTable()
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    local profession = profInfo and profInfo.profession
    if not profession then return false end
    if C_TradeSkillUI.IsNearProfessionSpellFocus then
        local ok, result = pcall(C_TradeSkillUI.IsNearProfessionSpellFocus, profession)
        return ok and result or false
    end
    return false
end

local _IsInGuild = IsInGuild
local function IsPlayerInGuild()
    return _IsInGuild and _IsInGuild() or false
end

local function FormatGold(copper)
    if not copper or copper == 0 then return "0g" end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    if gold > 0 then
        if silver > 0 then
            return string.format("%d|cffffd700g|r %d|cffc7c7cfs|r", gold, silver)
        end
        return string.format("%d|cffffd700g|r", gold)
    end
    return string.format("%d|cffc7c7cfs|r", silver)
end

local function FormatTimeLeft(expirationTime)
    if not expirationTime then return "" end
    local remaining = expirationTime - time()
    if remaining <= 0 then return "|cffff4444Expired|r" end
    if remaining < 3600 then
        return string.format("%dm", math.floor(remaining / 60))
    elseif remaining < 86400 then
        return string.format("%dh", math.floor(remaining / 3600))
    else
        return string.format("%dd", math.floor(remaining / 86400))
    end
end

local function GetItemName(itemID)
    if not itemID then return "Unknown" end
    local name = C_Item.GetItemNameByID(itemID)
    return name or "Loading..."
end

local function GetItemIcon(itemID)
    if not itemID then return nil end
    local icon = C_Item.GetItemIconByID(itemID)
    return icon
end

local function GetReagentStateName(state)
    if state == Enum.CraftingOrderReagentsType.All then
        return "|cff33cc33All Provided|r"
    elseif state == Enum.CraftingOrderReagentsType.Some then
        return "|cffffff44Some Provided|r"
    elseif state == Enum.CraftingOrderReagentsType.None then
        return "|cffcc3333None Provided|r"
    end
    return ""
end

--------------------------------------------------------------------
-- Unavailable overlay
--------------------------------------------------------------------
local function CreateUnavailableOverlay(parent)
    local overlay = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
    })
    overlay:SetBackdropColor(0, 0, 0, 0.75)
    overlay:SetFrameLevel(parent:GetFrameLevel() + 50)
    overlay:EnableMouse(true) -- block clicks through

    local icon = overlay:CreateTexture(nil, "OVERLAY")
    icon:SetSize(48, 48)
    icon:SetPoint("CENTER", overlay, "CENTER", 0, 20)
    icon:SetAtlas("Professions-Icon-Lock")
    icon:SetDesaturated(true)
    icon:SetVertexColor(0.6, 0.6, 0.6)

    local text = overlay:CreateFontString(nil, "OVERLAY")
    text:SetFont(ns.FONT, 14, "")
    text:SetPoint("TOP", icon, "BOTTOM", 0, -8)
    text:SetTextColor(unpack(ns.COLORS.mutedText))
    text:SetText("Must be at a crafting table\nto view Crafting Orders")
    text:SetJustifyH("CENTER")

    overlay:Hide()
    return overlay
end

--------------------------------------------------------------------
-- Order type tabs
--------------------------------------------------------------------
local function CreateOrderTypeTabs(parent)
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(ORDER_TYPE_TAB_HEIGHT)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local xOff = 4
    for i, def in ipairs(ORDER_TYPES) do
        -- Skip guild tab if not in guild
        local show = true
        if def.key == "guild" and not IsPlayerInGuild() then
            show = false
        end

        if show then
            local tab = CreateFrame("Button", nil, container)
            tab:SetHeight(ORDER_TYPE_TAB_HEIGHT - 4)

            local label = tab:CreateFontString(nil, "OVERLAY")
            label:SetFont(ns.FONT, 11, "")
            label:SetPoint("CENTER", tab, "CENTER", 0, 0)
            label:SetText(def.label)
            tab.label = label

            local w = label:GetStringWidth() + 20
            tab:SetWidth(w)
            tab:SetPoint("LEFT", container, "LEFT", xOff, 0)
            xOff = xOff + w + 2

            tab.orderType = def.type
            tab.key = def.key

            -- Underline
            tab.underline = tab:CreateTexture(nil, "ARTWORK")
            tab.underline:SetHeight(2)
            tab.underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 2, 0)
            tab.underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -2, 0)
            tab.underline:SetColorTexture(unpack(ns.COLORS.accent))
            tab.underline:Hide()

            tab:SetScript("OnClick", function()
                ProfOrders:SelectOrderType(def.type)
            end)
            tab:SetScript("OnEnter", function()
                if activeOrderType ~= def.type then
                    label:SetTextColor(unpack(ns.COLORS.tabHover))
                end
            end)
            tab:SetScript("OnLeave", function()
                if activeOrderType ~= def.type then
                    label:SetTextColor(unpack(ns.COLORS.tabInactive))
                end
            end)

            table.insert(orderTypeTabs, tab)
        end
    end

    -- Separator
    local sep = container:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    sep:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    sep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    return container
end

local function UpdateOrderTypeTabHighlights()
    for _, tab in ipairs(orderTypeTabs) do
        if tab.orderType == activeOrderType then
            tab.label:SetTextColor(unpack(ns.COLORS.tabActive))
            tab.underline:Show()
        else
            tab.label:SetTextColor(unpack(ns.COLORS.tabInactive))
            tab.underline:Hide()
        end
    end
end

--------------------------------------------------------------------
-- Search bar
--------------------------------------------------------------------
local function CreateSearchBar(parent)
    local f = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    f:SetHeight(SEARCH_HEIGHT)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    f:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(ns.COLORS.searchBg))
    f:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    f:SetFont(ns.FONT, 12, "")
    f:SetTextColor(unpack(ns.COLORS.brightText))
    f:SetTextInsets(8, 24, 0, 0)
    f:SetAutoFocus(false)

    -- Placeholder
    local ph = f:CreateFontString(nil, "OVERLAY")
    ph:SetFont(ns.FONT, 12, "")
    ph:SetPoint("LEFT", f, "LEFT", 8, 0)
    ph:SetTextColor(0.4, 0.4, 0.4)
    ph:SetText("Search orders...")
    f.placeholder = ph

    f:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        ph:SetShown(text == "")
        searchText = text
        ProfOrders:FilterAndRefreshList()
    end)
    f:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    f:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchFocus))
    end)
    f:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    end)

    return f
end

--------------------------------------------------------------------
-- Sort button
--------------------------------------------------------------------
local function CreateSortButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(80, 20)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -2)

    local label = btn:CreateFontString(nil, "OVERLAY")
    label:SetFont(ns.FONT, 10, "")
    label:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
    label:SetTextColor(unpack(ns.COLORS.tabInactive))
    label:SetText("Sort: Name")
    btn.label = label

    btn:SetScript("OnClick", function(self)
        -- Toggle through sort options
        local opts = displayBuckets and BUCKET_SORT_OPTIONS or SORT_OPTIONS
        local currentIdx = 1
        for i, opt in ipairs(opts) do
            if opt.sort == primarySort.sortType then
                currentIdx = i
                break
            end
        end
        local nextIdx = (currentIdx % #opts) + 1
        primarySort.sortType = opts[nextIdx].sort
        label:SetText("Sort: " .. opts[nextIdx].label)
        ProfOrders:RequestOrders()
    end)
    btn:SetScript("OnEnter", function()
        label:SetTextColor(unpack(ns.COLORS.tabHover))
    end)
    btn:SetScript("OnLeave", function()
        label:SetTextColor(unpack(ns.COLORS.tabInactive))
    end)

    return btn
end

--------------------------------------------------------------------
-- Order list rows
--------------------------------------------------------------------
local function CreateOrderRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

    -- Background
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0)

    -- Left accent bar
    row.leftAccent = row:CreateTexture(nil, "ARTWORK", nil, 2)
    row.leftAccent:SetSize(2, ROW_HEIGHT)
    row.leftAccent:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.leftAccent:SetColorTexture(unpack(ns.COLORS.accent))
    row.leftAccent:Hide()

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)

    -- Item name
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 2)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Subtext (reagent state or count)
    row.subText = row:CreateFontString(nil, "OVERLAY")
    row.subText:SetFont(ns.FONT, 9, "")
    row.subText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -1)
    row.subText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Tip text (right side)
    row.tipText = row:CreateFontString(nil, "OVERLAY")
    row.tipText:SetFont(ns.FONT, 11, "")
    row.tipText:SetPoint("RIGHT", row, "RIGHT", -6, 2)
    row.tipText:SetJustifyH("RIGHT")
    row.tipText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Time text (right, below tip)
    row.timeText = row:CreateFontString(nil, "OVERLAY")
    row.timeText:SetFont(ns.FONT, 9, "")
    row.timeText:SetPoint("TOPRIGHT", row.tipText, "BOTTOMRIGHT", 0, -1)
    row.timeText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Divider
    row.divider = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 0)
    row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 0)
    row.divider:SetColorTexture(unpack(ns.COLORS.rowDivider))

    row:SetScript("OnEnter", function(self)
        if not self.isSelected then
            self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        end
    end)
    row:SetScript("OnLeave", function(self)
        if not self.isSelected then
            self.bg:SetColorTexture(1, 1, 1, 0)
        end
    end)
    row:SetScript("OnClick", function(self)
        if self.orderData then
            if self.isBucket then
                ProfOrders:DrillIntoBucket(self.orderData)
            else
                ProfOrders:SelectOrder(self.orderData)
            end
        end
    end)

    row:Hide()
    return row
end

--------------------------------------------------------------------
-- Scroll bar
--------------------------------------------------------------------
local function CreateScrollBar(parent, listFrame)
    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    track:SetWidth(8)
    track:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    track:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    track:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    track:SetBackdropColor(unpack(ns.COLORS.scrollTrack))

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(8)
    thumb:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    thumb:SetBackdropColor(unpack(ns.COLORS.scrollThumb))
    thumb:EnableMouse(true)
    thumb:SetMovable(true)
    track.thumb = thumb

    local bar = { track = track, thumb = thumb }

    function bar:Update(total, visible, offset)
        if total <= visible then
            thumb:Hide()
            return
        end
        thumb:Show()
        local trackH = track:GetHeight()
        local thumbH = math.max(20, (visible / total) * trackH)
        thumb:SetHeight(thumbH)
        local scrollRange = trackH - thumbH
        local scrollPct = offset / (total - visible)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(scrollPct * scrollRange))
    end

    -- Mouse wheel on list
    listFrame:EnableMouseWheel(true)
    listFrame:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #currentOrders - VISIBLE_ROWS)
        scrollOffset = math.max(0, math.min(maxOffset, scrollOffset - delta * 3))
        ProfOrders:RefreshList()
    end)

    return bar
end

--------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------
local function CreateDetailPanel(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(ns.COLORS.panelBg))
    f:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- "Select an order" placeholder
    f.emptyText = f:CreateFontString(nil, "OVERLAY")
    f.emptyText:SetFont(ns.FONT, 13, "")
    f.emptyText:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.emptyText:SetTextColor(unpack(ns.COLORS.mutedText))
    f.emptyText:SetText("Select an order to view details")

    -- Detail content container
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 50)
    f.content = content
    content:Hide()

    -- Item icon
    content.icon = content:CreateTexture(nil, "ARTWORK")
    content.icon:SetSize(DETAIL_ICON_SIZE, DETAIL_ICON_SIZE)
    content.icon:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)

    -- Quality pip (overlaid on icon, upper-left)
    content.qualityStars = content:CreateFontString(nil, "OVERLAY", nil, 7)
    content.qualityStars:SetFont(ns.FONT, 14, "")
    content.qualityStars:SetPoint("TOPLEFT", content.icon, "TOPLEFT", -2, 2)
    content.qualityStars:SetTextColor(unpack(ns.COLORS.brightText))

    -- Item name
    content.nameText = content:CreateFontString(nil, "OVERLAY")
    content.nameText:SetFont(ns.FONT, 14, "")
    content.nameText:SetPoint("TOPLEFT", content.icon, "TOPRIGHT", 8, -2)
    content.nameText:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    content.nameText:SetJustifyH("LEFT")
    content.nameText:SetWordWrap(false)
    content.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Customer name
    content.customerText = content:CreateFontString(nil, "OVERLAY")
    content.customerText:SetFont(ns.FONT, 11, "")
    content.customerText:SetPoint("TOPLEFT", content.nameText, "BOTTOMLEFT", 0, -2)
    content.customerText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Separator below header
    content.headerSep = content:CreateTexture(nil, "ARTWORK")
    content.headerSep:SetHeight(1)
    content.headerSep:SetPoint("TOPLEFT", content.icon, "BOTTOMLEFT", 0, -8)
    content.headerSep:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    content.headerSep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Info rows area
    local infoY = -(DETAIL_ICON_SIZE + 16)

    -- Tip
    content.tipLabel = content:CreateFontString(nil, "OVERLAY")
    content.tipLabel:SetFont(ns.FONT, 11, "")
    content.tipLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, infoY)
    content.tipLabel:SetText("Commission:")
    content.tipLabel:SetTextColor(unpack(ns.COLORS.headerText))

    content.tipValue = content:CreateFontString(nil, "OVERLAY")
    content.tipValue:SetFont(ns.FONT, 11, "")
    content.tipValue:SetPoint("LEFT", content.tipLabel, "RIGHT", 6, 0)
    content.tipValue:SetTextColor(unpack(ns.COLORS.goldText))
    infoY = infoY - 18

    -- Consortium cut
    content.cutLabel = content:CreateFontString(nil, "OVERLAY")
    content.cutLabel:SetFont(ns.FONT, 11, "")
    content.cutLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, infoY)
    content.cutLabel:SetText("Consortium Cut:")
    content.cutLabel:SetTextColor(unpack(ns.COLORS.headerText))

    content.cutValue = content:CreateFontString(nil, "OVERLAY")
    content.cutValue:SetFont(ns.FONT, 11, "")
    content.cutValue:SetPoint("LEFT", content.cutLabel, "RIGHT", 6, 0)
    content.cutValue:SetTextColor(unpack(ns.COLORS.redText))
    infoY = infoY - 18

    -- Time remaining
    content.timeLabel = content:CreateFontString(nil, "OVERLAY")
    content.timeLabel:SetFont(ns.FONT, 11, "")
    content.timeLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, infoY)
    content.timeLabel:SetText("Time Left:")
    content.timeLabel:SetTextColor(unpack(ns.COLORS.headerText))

    content.timeValue = content:CreateFontString(nil, "OVERLAY")
    content.timeValue:SetFont(ns.FONT, 11, "")
    content.timeValue:SetPoint("LEFT", content.timeLabel, "RIGHT", 6, 0)
    content.timeValue:SetTextColor(unpack(ns.COLORS.brightText))
    infoY = infoY - 18

    -- Min quality
    content.qualLabel = content:CreateFontString(nil, "OVERLAY")
    content.qualLabel:SetFont(ns.FONT, 11, "")
    content.qualLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, infoY)
    content.qualLabel:SetText("Min Quality:")
    content.qualLabel:SetTextColor(unpack(ns.COLORS.headerText))

    content.qualValue = content:CreateFontString(nil, "OVERLAY")
    content.qualValue:SetFont(ns.FONT, 11, "")
    content.qualValue:SetPoint("LEFT", content.qualLabel, "RIGHT", 6, 0)
    content.qualValue:SetTextColor(unpack(ns.COLORS.brightText))
    infoY = infoY - 18

    -- Reagent state
    content.reagentLabel = content:CreateFontString(nil, "OVERLAY")
    content.reagentLabel:SetFont(ns.FONT, 11, "")
    content.reagentLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, infoY)
    content.reagentLabel:SetText("Reagents:")
    content.reagentLabel:SetTextColor(unpack(ns.COLORS.headerText))

    content.reagentValue = content:CreateFontString(nil, "OVERLAY")
    content.reagentValue:SetFont(ns.FONT, 11, "")
    content.reagentValue:SetPoint("LEFT", content.reagentLabel, "RIGHT", 6, 0)
    infoY = infoY - 22

    -- Reagents header
    content.reagentsHeader = content:CreateFontString(nil, "OVERLAY")
    content.reagentsHeader:SetFont(ns.FONT, 10, "")
    content.reagentsHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 0, infoY)
    content.reagentsHeader:SetText("PROVIDED REAGENTS")
    content.reagentsHeader:SetTextColor(unpack(ns.COLORS.headerText))
    infoY = infoY - 4

    -- Reagent rows (pre-create pool)
    content.reagentRows = {}
    for i = 1, 12 do
        local rr = CreateFrame("Frame", nil, content)
        rr:SetHeight(REAGENT_ROW_HEIGHT)
        rr:SetPoint("TOPLEFT", content, "TOPLEFT", 0, infoY - (i - 1) * REAGENT_ROW_HEIGHT)
        rr:SetPoint("RIGHT", content, "RIGHT", 0, 0)

        rr.icon = rr:CreateTexture(nil, "ARTWORK")
        rr.icon:SetSize(REAGENT_ICON_SIZE, REAGENT_ICON_SIZE)
        rr.icon:SetPoint("LEFT", rr, "LEFT", 4, 0)

        rr.nameText = rr:CreateFontString(nil, "OVERLAY")
        rr.nameText:SetFont(ns.FONT, 10, "")
        rr.nameText:SetPoint("LEFT", rr.icon, "RIGHT", 4, 0)
        rr.nameText:SetPoint("RIGHT", rr, "RIGHT", -40, 0)
        rr.nameText:SetJustifyH("LEFT")
        rr.nameText:SetWordWrap(false)
        rr.nameText:SetTextColor(unpack(ns.COLORS.brightText))

        rr.qtyText = rr:CreateFontString(nil, "OVERLAY")
        rr.qtyText:SetFont(ns.FONT, 10, "")
        rr.qtyText:SetPoint("RIGHT", rr, "RIGHT", -4, 0)
        rr.qtyText:SetJustifyH("RIGHT")
        rr.qtyText:SetTextColor(unpack(ns.COLORS.mutedText))

        rr:Hide()
        content.reagentRows[i] = rr
    end

    -- Customer notes
    content.notesLabel = content:CreateFontString(nil, "OVERLAY")
    content.notesLabel:SetFont(ns.FONT, 10, "")
    content.notesLabel:SetText("CUSTOMER NOTES")
    content.notesLabel:SetTextColor(unpack(ns.COLORS.headerText))
    -- Position dynamically in RefreshDetail

    content.notesText = content:CreateFontString(nil, "OVERLAY")
    content.notesText:SetFont(ns.FONT, 11, "")
    content.notesText:SetTextColor(unpack(ns.COLORS.brightText))
    content.notesText:SetJustifyH("LEFT")
    content.notesText:SetWordWrap(true)
    content.notesText:SetWidth(1) -- set dynamically

    -- NPC Rewards section
    content.rewardsLabel = content:CreateFontString(nil, "OVERLAY")
    content.rewardsLabel:SetFont(ns.FONT, 10, "")
    content.rewardsLabel:SetText("PATRON REWARDS")
    content.rewardsLabel:SetTextColor(unpack(ns.COLORS.headerText))
    content.rewardsLabel:Hide()

    content.rewardsText = content:CreateFontString(nil, "OVERLAY")
    content.rewardsText:SetFont(ns.FONT, 11, "")
    content.rewardsText:SetTextColor(unpack(ns.COLORS.brightText))
    content.rewardsText:Hide()

    -- Recipe source info (unlearned recipes — vendor, zone, cost)
    content.recipeSourceFrame = CreateFrame("Frame", nil, content, "BackdropTemplate")
    content.recipeSourceFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    content.recipeSourceFrame:SetBackdropColor(0.12, 0.08, 0.02, 0.9)
    content.recipeSourceFrame:SetBackdropBorderColor(0.6, 0.45, 0.1, 0.8)
    content.recipeSourceFrame:Hide()

    content.recipeSourceLabel = content.recipeSourceFrame:CreateFontString(nil, "OVERLAY")
    content.recipeSourceLabel:SetFont(ns.FONT, 11, "")
    content.recipeSourceLabel:SetPoint("TOPLEFT", content.recipeSourceFrame, "TOPLEFT", 8, -6)
    content.recipeSourceLabel:SetTextColor(0.9, 0.3, 0.3)

    content.recipeSourceText = content.recipeSourceFrame:CreateFontString(nil, "OVERLAY")
    content.recipeSourceText:SetFont(ns.FONT, 11, "")
    content.recipeSourceText:SetPoint("TOPLEFT", content.recipeSourceLabel, "BOTTOMLEFT", 0, -4)
    content.recipeSourceText:SetPoint("RIGHT", content.recipeSourceFrame, "RIGHT", -8, 0)
    content.recipeSourceText:SetTextColor(0.9, 0.75, 0.3)
    content.recipeSourceText:SetJustifyH("LEFT")
    content.recipeSourceText:SetWordWrap(true)

    -- Action buttons (at bottom of detail panel)
    local btnArea = CreateFrame("Frame", nil, f)
    btnArea:SetHeight(40)
    btnArea:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 4)
    btnArea:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 4)
    f.btnArea = btnArea

    -- Claim / Start Order button
    f.claimBtn = ns.CreateButton(btnArea, "Claim Order", 110, 26)
    f.claimBtn:SetPoint("RIGHT", btnArea, "RIGHT", 0, 0)
    f.claimBtn:SetScript("OnClick", function()
        ProfOrders:OnClaimOrStart()
    end)

    -- Decline / Release button
    f.declineBtn = ns.CreateButton(btnArea, "Decline", 90, 26)
    f.declineBtn:SetPoint("RIGHT", f.claimBtn, "LEFT", -6, 0)
    f.declineBtn:SetScript("OnClick", function()
        ProfOrders:OnDeclineOrRelease()
    end)

    -- Fulfill button (only shown after crafting)
    f.fulfillBtn = ns.CreateButton(btnArea, "Complete Order", 120, 26)
    f.fulfillBtn:SetPoint("RIGHT", btnArea, "RIGHT", 0, 0)
    f.fulfillBtn:SetScript("OnClick", function()
        ProfOrders:OnFulfill()
    end)
    f.fulfillBtn:Hide()

    -- Claim capacity text
    f.claimCapText = btnArea:CreateFontString(nil, "OVERLAY")
    f.claimCapText:SetFont(ns.FONT, 10, "")
    f.claimCapText:SetPoint("LEFT", btnArea, "LEFT", 4, 0)
    f.claimCapText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Back button (for bucket drilldown)
    f.backBtn = ns.CreateButton(f, "< Back", 60, 22)
    f.backBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    f.backBtn:SetScript("OnClick", function()
        ProfOrders:BackFromBucket()
    end)
    f.backBtn:Hide()

    return f
end

--------------------------------------------------------------------
-- Left panel (list side)
--------------------------------------------------------------------
local function CreateLeftPanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(LEFT_PANEL_WIDTH)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)

    -- Order type tabs
    f.typeTabs = CreateOrderTypeTabs(f)

    -- Search bar
    searchBox = CreateSearchBar(f)
    searchBox:SetPoint("TOPLEFT", f.typeTabs, "BOTTOMLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, 0)
    searchBox:ClearAllPoints()
    searchBox:SetPoint("TOPLEFT", f.typeTabs, "BOTTOMLEFT", 4, -4)
    searchBox:SetPoint("RIGHT", f, "RIGHT", -14, 0)

    -- Sort button
    sortBtn = CreateSortButton(f)
    sortBtn:ClearAllPoints()
    sortBtn:SetPoint("TOPRIGHT", searchBox, "BOTTOMRIGHT", 0, -2)

    -- List container
    listFrame = CreateFrame("Frame", nil, f)
    listFrame:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -22)
    listFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0)

    -- Pre-create rows
    for i = 1, VISIBLE_ROWS do
        listRows[i] = CreateOrderRow(listFrame, i)
    end

    -- Scroll bar
    scrollBar = CreateScrollBar(f, listFrame)
    scrollBar.track:ClearAllPoints()
    scrollBar.track:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -(ORDER_TYPE_TAB_HEIGHT + SEARCH_HEIGHT + 24))
    scrollBar.track:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 0)

    -- Loading text
    f.loadingText = listFrame:CreateFontString(nil, "OVERLAY")
    f.loadingText:SetFont(ns.FONT, 12, "")
    f.loadingText:SetPoint("CENTER", listFrame, "CENTER", 0, 0)
    f.loadingText:SetTextColor(unpack(ns.COLORS.mutedText))
    f.loadingText:SetText("Loading orders...")
    f.loadingText:Hide()

    -- Empty text
    f.emptyText = listFrame:CreateFontString(nil, "OVERLAY")
    f.emptyText:SetFont(ns.FONT, 12, "")
    f.emptyText:SetPoint("CENTER", listFrame, "CENTER", 0, 0)
    f.emptyText:SetTextColor(unpack(ns.COLORS.mutedText))
    f.emptyText:SetText("No orders found")
    f.emptyText:Hide()

    -- Divider between left and right
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOP", f, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOM", f, "BOTTOMRIGHT", 0, 0)
    divider:SetColorTexture(unpack(ns.COLORS.rowDivider))

    return f
end

--------------------------------------------------------------------
-- CraftSim integration panel
--------------------------------------------------------------------
local CRAFTSIM_PANEL_HEIGHT = 240
local craftSimPanel
local craftSimQueueRows = {}
local CRAFTSIM_VISIBLE_ROWS = 6
local CRAFTSIM_ROW_HEIGHT = 22
local craftSimScrollOffset = 0

-- Column layout: {key, label, width, justifyH}
local CRAFTSIM_COLUMNS = {
    { key = "crafter",  label = "Crafter",       width = 55,  justifyH = "LEFT" },
    { key = "recipe",   label = "Recipe",        width = 0,   justifyH = "LEFT" },   -- flex
    { key = "result",   label = "Result",        width = 35,  justifyH = "CENTER" },
    { key = "profit",   label = "Ø Profit",      width = 90,  justifyH = "RIGHT" },
    { key = "cost",     label = "Craft Cost",    width = 85,  justifyH = "RIGHT" },
    { key = "tools",    label = "Tools",         width = 30,  justifyH = "CENTER" },
    { key = "max",      label = "Max",           width = 30,  justifyH = "CENTER" },
    { key = "queued",   label = "Qty",           width = 30,  justifyH = "CENTER" },
    { key = "status",   label = "Status",        width = 50,  justifyH = "CENTER" },
}

local function HasCraftSim()
    return CraftSimLib and CraftSimLib.CRAFTQ and CraftSimLib.CRAFTQ.craftQueue
end

local function CreateCraftSimPanel(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(ns.COLORS.panelBg))
    f:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- Header
    local header = f:CreateFontString(nil, "OVERLAY")
    header:SetFont(ns.FONT, 10, "")
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
    header:SetText("CRAFT QUEUE")
    header:SetTextColor(unpack(ns.COLORS.headerText))

    -- Summary text (right of header)
    f.profitText = f:CreateFontString(nil, "OVERLAY")
    f.profitText:SetFont(ns.FONT, 10, "")
    f.profitText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
    f.profitText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Column headers row
    local headerRow = CreateFrame("Frame", nil, f)
    headerRow:SetHeight(16)
    headerRow:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -20)
    headerRow:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -20)
    f.headerRow = headerRow

    -- Header separator
    local headerSep = f:CreateTexture(nil, "ARTWORK")
    headerSep:SetHeight(1)
    headerSep:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -1)
    headerSep:SetPoint("TOPRIGHT", headerRow, "BOTTOMRIGHT", 0, -1)
    headerSep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Build column header labels
    -- Fixed columns anchor from left and right; recipe column is flex
    local fixedLeft = 4   -- padding
    local fixedRight = 4
    -- Calculate flex width: we'll position columns absolutely
    -- Left-anchored: crafter
    -- Then recipe (flex)
    -- Then right-anchored columns from right edge: status, queued, max, tools, cost, profit, result
    f.colHeaders = {}
    for _, col in ipairs(CRAFTSIM_COLUMNS) do
        local lbl = headerRow:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(ns.FONT, 9, "")
        lbl:SetText(col.label)
        lbl:SetTextColor(unpack(ns.COLORS.mutedText))
        lbl:SetJustifyH(col.justifyH)
        f.colHeaders[col.key] = lbl
    end

    -- Queue list area (below header row + separator)
    local listArea = CreateFrame("Frame", nil, f)
    listArea:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
    listArea:SetPoint("TOPRIGHT", headerRow, "BOTTOMRIGHT", 0, -2)
    listArea:SetHeight(CRAFTSIM_VISIBLE_ROWS * CRAFTSIM_ROW_HEIGHT)
    f.listArea = listArea

    -- Pre-create queue rows with all columns
    for i = 1, CRAFTSIM_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, listArea)
        row:SetHeight(CRAFTSIM_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", listArea, "TOPLEFT", 0, -(i - 1) * CRAFTSIM_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", 0, -(i - 1) * CRAFTSIM_ROW_HEIGHT)

        -- Alternating row bg
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        if i % 2 == 0 then
            row.bg:SetColorTexture(1, 1, 1, 0.03)
        else
            row.bg:SetColorTexture(0, 0, 0, 0)
        end

        -- Crafter text
        row.crafterText = row:CreateFontString(nil, "OVERLAY")
        row.crafterText:SetFont(ns.FONT, 9, "")
        row.crafterText:SetJustifyH("LEFT")
        row.crafterText:SetWordWrap(false)

        -- Recipe icon + text
        row.recipeIcon = row:CreateTexture(nil, "ARTWORK")
        row.recipeIcon:SetSize(16, 16)

        row.recipeText = row:CreateFontString(nil, "OVERLAY")
        row.recipeText:SetFont(ns.FONT, 9, "")
        row.recipeText:SetJustifyH("LEFT")
        row.recipeText:SetWordWrap(false)
        row.recipeText:SetTextColor(unpack(ns.COLORS.brightText))

        -- Result icon
        row.resultIcon = row:CreateTexture(nil, "ARTWORK")
        row.resultIcon:SetSize(16, 16)

        -- Ø Profit text
        row.profitText = row:CreateFontString(nil, "OVERLAY")
        row.profitText:SetFont(ns.FONT, 9, "")
        row.profitText:SetJustifyH("RIGHT")

        -- Crafting Cost text
        row.costText = row:CreateFontString(nil, "OVERLAY")
        row.costText:SetFont(ns.FONT, 9, "")
        row.costText:SetJustifyH("RIGHT")

        -- Tools (checkmark/X)
        row.toolsText = row:CreateFontString(nil, "OVERLAY")
        row.toolsText:SetFont(ns.FONT, 9, "")
        row.toolsText:SetJustifyH("CENTER")

        -- Max
        row.maxText = row:CreateFontString(nil, "OVERLAY")
        row.maxText:SetFont(ns.FONT, 9, "")
        row.maxText:SetJustifyH("CENTER")

        -- Queued
        row.queuedText = row:CreateFontString(nil, "OVERLAY")
        row.queuedText:SetFont(ns.FONT, 9, "")
        row.queuedText:SetJustifyH("CENTER")
        row.queuedText:SetTextColor(unpack(ns.COLORS.brightText))

        -- Status
        row.statusText = row:CreateFontString(nil, "OVERLAY")
        row.statusText:SetFont(ns.FONT, 9, "")
        row.statusText:SetJustifyH("CENTER")

        row:Hide()
        craftSimQueueRows[i] = row
    end

    -- Position columns after listArea exists (deferred to OnShow so width is known)
    f:SetScript("OnShow", function(self)
        self:SetScript("OnShow", nil) -- one-time layout
        ProfOrders:LayoutCraftSimColumns()
    end)

    -- Mouse wheel scroll on list
    listArea:EnableMouseWheel(true)
    listArea:SetScript("OnMouseWheel", function(_, delta)
        if not HasCraftSim() then return end
        local items = CraftSimLib.CRAFTQ.craftQueue.craftQueueItems or {}
        local maxOff = math.max(0, #items - CRAFTSIM_VISIBLE_ROWS)
        craftSimScrollOffset = math.max(0, math.min(maxOff, craftSimScrollOffset - delta))
        ProfOrders:RefreshCraftSimQueue()
    end)

    -- Separator above buttons
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("LEFT", f, "LEFT", 6, 0)
    sep:SetPoint("RIGHT", f, "RIGHT", -6, 0)
    sep:SetPoint("BOTTOM", f, "BOTTOM", 0, 38)
    sep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Bottom buttons row
    local btnY = 8
    local btnH = 24
    local btnGap = 4

    -- Queue Work Orders
    f.queueWorkBtn = ns.CreateButton(f, "Queue Orders", 100, btnH)
    f.queueWorkBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, btnY)
    f.queueWorkBtn:SetScript("OnClick", function()
        if HasCraftSim() then
            CraftSimLib.CRAFTQ:QueueWorkOrders()
            C_Timer.After(0.5, function() ProfOrders:RefreshCraftSimQueue() end)
        end
    end)

    -- Create Shopping List
    f.shopListBtn = ns.CreateButton(f, "Shopping List", 100, btnH)
    f.shopListBtn:SetPoint("LEFT", f.queueWorkBtn, "RIGHT", btnGap, 0)
    f.shopListBtn:SetScript("OnClick", function()
        if HasCraftSim() then
            CraftSimLib.CRAFTQ:CreateAuctionatorShoppingList()
        end
    end)

    -- Clear All
    f.clearBtn = ns.CreateButton(f, "Clear", 50, btnH)
    f.clearBtn:SetPoint("LEFT", f.shopListBtn, "RIGHT", btnGap, 0)
    f.clearBtn:SetScript("OnClick", function()
        if HasCraftSim() then
            CraftSimLib.CRAFTQ:ClearAll()
            C_Timer.After(0.2, function() ProfOrders:RefreshCraftSimQueue() end)
        end
    end)

    -- Next: Claim (right side, prominent)
    f.nextClaimBtn = ns.CreateButton(f, "Next: Claim", 100, btnH)
    f.nextClaimBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, btnY)
    f.nextClaimBtn:SetScript("OnClick", function()
        if not HasCraftSim() then return end
        local profession = GetProfessionEnum()
        if not profession then return end

        -- First: check if there's already a claimed order we can act on directly
        local claimed = C_CraftingOrders.GetClaimedOrder and C_CraftingOrders.GetClaimedOrder()
        if claimed then
            if claimed.isFulfillable then
                -- Fulfill it and remove matching queue item
                pcall(C_CraftingOrders.FulfillOrder, claimed.orderID, "", profession)
                -- Find and remove from CraftSim queue
                local items = CraftSimLib.CRAFTQ.craftQueue.craftQueueItems or {}
                for _, item in ipairs(items) do
                    local rd = item.recipeData
                    if rd and rd.orderData and rd.orderData.orderID == claimed.orderID then
                        pcall(CraftSimLib.CRAFTQ.craftQueue.Remove, CraftSimLib.CRAFTQ.craftQueue, item)
                        break
                    end
                end
                -- Recalculate remaining items
                if CraftSimLib.CRAFTQ.UI and CraftSimLib.CRAFTQ.UI.UpdateDisplay then
                    pcall(CraftSimLib.CRAFTQ.UI.UpdateDisplay, CraftSimLib.CRAFTQ.UI)
                end
                C_Timer.After(1, function() ProfOrders:RefreshCraftSimQueue() end)
                return
            else
                -- Claimed but not fulfillable — craft it
                local items = CraftSimLib.CRAFTQ.craftQueue.craftQueueItems or {}
                for _, item in ipairs(items) do
                    local rd = item.recipeData
                    if rd and rd.orderData and rd.orderData.orderID == claimed.orderID then
                        pcall(rd.Craft, rd, 1)
                        C_Timer.After(1, function() ProfOrders:RefreshCraftSimQueue() end)
                        return
                    end
                end
            end
        end

        -- No claimed order — find next queue item to claim
        local items = CraftSimLib.CRAFTQ.craftQueue.craftQueueItems or {}
        for _, item in ipairs(items) do
            local rd = item.recipeData
            if rd and rd.orderData then
                pcall(C_CraftingOrders.ClaimOrder, rd.orderData.orderID, profession)
                C_Timer.After(1, function() ProfOrders:RefreshCraftSimQueue() end)
                return
            elseif rd and (item.allowedToCraft or item.canCraftOnce) then
                -- Non-order craft
                pcall(rd.Craft, rd, item.amount or 1)
                C_Timer.After(1, function() ProfOrders:RefreshCraftSimQueue() end)
                return
            end
        end
    end)

    -- "No CraftSim" fallback text
    f.noCraftSimText = f:CreateFontString(nil, "OVERLAY")
    f.noCraftSimText:SetFont(ns.FONT, 11, "")
    f.noCraftSimText:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.noCraftSimText:SetTextColor(unpack(ns.COLORS.mutedText))
    f.noCraftSimText:SetText("CraftSim not loaded")
    f.noCraftSimText:Hide()

    f:Hide()
    return f
end

--------------------------------------------------------------------
-- Column layout (called once after panel has width)
--------------------------------------------------------------------
function ProfOrders:LayoutCraftSimColumns()
    if not craftSimPanel then return end
    local panelWidth = craftSimPanel:GetWidth() - 8 -- 4px padding each side

    -- Calculate fixed column total and recipe flex width
    local fixedTotal = 0
    for _, col in ipairs(CRAFTSIM_COLUMNS) do
        if col.width > 0 then fixedTotal = fixedTotal + col.width end
    end
    local recipeWidth = math.max(80, panelWidth - fixedTotal - 20) -- 20 for recipe icon

    -- Position header labels and row cells
    -- Build absolute X offsets from left edge
    local xOffsets = {}
    local x = 4
    for _, col in ipairs(CRAFTSIM_COLUMNS) do
        xOffsets[col.key] = x
        if col.key == "recipe" then
            x = x + recipeWidth + 20 -- +20 for icon
        else
            x = x + col.width
        end
    end

    -- Position column headers
    for _, col in ipairs(CRAFTSIM_COLUMNS) do
        local lbl = craftSimPanel.colHeaders[col.key]
        lbl:ClearAllPoints()
        local colW = col.width > 0 and col.width or recipeWidth
        if col.key == "recipe" then
            lbl:SetPoint("LEFT", craftSimPanel.headerRow, "LEFT", xOffsets[col.key] + 20, 0) -- after icon space
            lbl:SetWidth(recipeWidth)
        else
            lbl:SetPoint("LEFT", craftSimPanel.headerRow, "LEFT", xOffsets[col.key], 0)
            lbl:SetWidth(colW)
        end
    end

    -- Position row cells
    for _, row in ipairs(craftSimQueueRows) do
        -- Crafter
        row.crafterText:ClearAllPoints()
        row.crafterText:SetPoint("LEFT", row, "LEFT", xOffsets.crafter, 0)
        row.crafterText:SetWidth(CRAFTSIM_COLUMNS[1].width)

        -- Recipe icon + text
        row.recipeIcon:ClearAllPoints()
        row.recipeIcon:SetPoint("LEFT", row, "LEFT", xOffsets.recipe, 0)
        row.recipeText:ClearAllPoints()
        row.recipeText:SetPoint("LEFT", row.recipeIcon, "RIGHT", 3, 0)
        row.recipeText:SetWidth(recipeWidth - 4)

        -- Result icon
        row.resultIcon:ClearAllPoints()
        row.resultIcon:SetPoint("LEFT", row, "LEFT", xOffsets.result + 8, 0)

        -- Profit
        row.profitText:ClearAllPoints()
        row.profitText:SetPoint("LEFT", row, "LEFT", xOffsets.profit, 0)
        row.profitText:SetWidth(CRAFTSIM_COLUMNS[4].width)

        -- Cost
        row.costText:ClearAllPoints()
        row.costText:SetPoint("LEFT", row, "LEFT", xOffsets.cost, 0)
        row.costText:SetWidth(CRAFTSIM_COLUMNS[5].width)

        -- Tools
        row.toolsText:ClearAllPoints()
        row.toolsText:SetPoint("LEFT", row, "LEFT", xOffsets.tools, 0)
        row.toolsText:SetWidth(CRAFTSIM_COLUMNS[6].width)

        -- Max
        row.maxText:ClearAllPoints()
        row.maxText:SetPoint("LEFT", row, "LEFT", xOffsets.max, 0)
        row.maxText:SetWidth(CRAFTSIM_COLUMNS[7].width)

        -- Queued
        row.queuedText:ClearAllPoints()
        row.queuedText:SetPoint("LEFT", row, "LEFT", xOffsets.queued, 0)
        row.queuedText:SetWidth(CRAFTSIM_COLUMNS[8].width)

        -- Status
        row.statusText:ClearAllPoints()
        row.statusText:SetPoint("LEFT", row, "LEFT", xOffsets.status, 0)
        row.statusText:SetWidth(CRAFTSIM_COLUMNS[9].width)
    end
end

--------------------------------------------------------------------
-- CraftSim queue refresh + show/hide
--------------------------------------------------------------------
function ProfOrders:RefreshCraftSimQueue()
    if not craftSimPanel then return end
    if not HasCraftSim() then
        craftSimPanel.noCraftSimText:Show()
        craftSimPanel.profitText:SetText("")
        for _, row in ipairs(craftSimQueueRows) do row:Hide() end
        return
    end
    craftSimPanel.noCraftSimText:Hide()

    -- Re-layout columns if not done yet (panel may not have had width on first show)
    if not craftSimPanel._laidOut then
        self:LayoutCraftSimColumns()
        craftSimPanel._laidOut = true
    end

    local items = CraftSimLib.CRAFTQ.craftQueue.craftQueueItems or {}
    local totalProfit = 0
    local totalCost = 0
    local totalItems = #items

    -- Populate visible rows
    for i = 1, CRAFTSIM_VISIBLE_ROWS do
        local row = craftSimQueueRows[i]
        local dataIdx = craftSimScrollOffset + i
        local item = items[dataIdx]

        if item then
            row:Show()
            local rd = item.recipeData
            if rd then
                local amt = item.amount or 1

                -- Crafter (class-colored)
                local crafterName = ""
                if rd.crafterData then
                    crafterName = rd.crafterData.name or ""
                    local dash = crafterName:find("-")
                    if dash then crafterName = crafterName:sub(1, dash - 1) end
                    -- Class color
                    if rd.crafterData.class then
                        local cc = C_ClassColor.GetClassColor(rd.crafterData.class)
                        if cc then
                            crafterName = cc:WrapTextInColorCode(crafterName)
                        end
                    end
                end
                row.crafterText:SetText(crafterName)

                -- Recipe icon + name
                if rd.recipeIcon then
                    row.recipeIcon:SetTexture(rd.recipeIcon)
                    row.recipeIcon:Show()
                else
                    row.recipeIcon:Hide()
                end
                local recipeName = rd.recipeName or "Unknown"
                -- Add order type indicator
                if rd.orderData then
                    recipeName = recipeName .. " |cff44aaff★ NPC|r"
                end
                row.recipeText:SetText(recipeName)

                -- Result icon
                local resultShown = false
                if rd.resultData and rd.resultData.expectedItem then
                    local ok, icon = pcall(function() return rd.resultData.expectedItem:GetItemIcon() end)
                    if ok and icon then
                        row.resultIcon:SetTexture(icon)
                        row.resultIcon:Show()
                        resultShown = true
                    end
                end
                if not resultShown then
                    row.resultIcon:Hide()
                end

                -- Ø Profit (per unit * amount)
                local profit = rd.averageProfitCached or 0
                local totalItemProfit = profit * amt
                if profit >= 0 then
                    row.profitText:SetText("|cff33cc33" .. FormatGold(math.floor(profit)) .. "|r")
                else
                    row.profitText:SetText("|cffcc3333-" .. FormatGold(math.floor(math.abs(profit))) .. "|r")
                end
                totalProfit = totalProfit + totalItemProfit

                -- Crafting Costs
                local craftCost = 0
                if rd.priceData then
                    if rd.orderData and rd.priceData.craftingCostsNoOrderReagents then
                        craftCost = rd.priceData.craftingCostsNoOrderReagents
                    elseif rd.priceData.craftingCosts then
                        craftCost = rd.priceData.craftingCosts
                    end
                end
                row.costText:SetText(FormatGold(math.floor(craftCost * amt)))
                row.costText:SetTextColor(unpack(ns.COLORS.mutedText))
                totalCost = totalCost + (craftCost * amt)

                -- Tools
                if item.gearEquipped then
                    row.toolsText:SetText("|cff33cc33✓|r")
                else
                    row.toolsText:SetText("|cffcc3333✗|r")
                end

                -- Max
                local maxCraftable = item.craftAbleAmount or 0
                if maxCraftable > 0 then
                    row.maxText:SetText("|cff33cc33" .. maxCraftable .. "|r")
                else
                    row.maxText:SetText("|cffcc33330|r")
                end

                -- Queued
                row.queuedText:SetText(tostring(amt))

                -- Status
                if item.allowedToCraft or item.canCraftOnce then
                    if rd.orderData then
                        row.statusText:SetText("|cff33cc33Claim|r")
                    else
                        row.statusText:SetText("|cff33cc33Ready|r")
                    end
                elseif not item.gearEquipped then
                    row.statusText:SetText("|cffcc3333Gear|r")
                elseif not item.learned then
                    row.statusText:SetText("|cffcc3333Learn|r")
                elseif not item.isCrafter then
                    row.statusText:SetText("|cffffff44Alt|r")
                else
                    row.statusText:SetText("|cffffff44Wait|r")
                end
            else
                row.crafterText:SetText("")
                row.recipeIcon:Hide()
                row.recipeText:SetText("?")
                row.resultIcon:Hide()
                row.profitText:SetText("")
                row.costText:SetText("")
                row.toolsText:SetText("")
                row.maxText:SetText("")
                row.queuedText:SetText("")
                row.statusText:SetText("")
            end
        else
            row:Hide()
        end
    end

    -- Summary line
    if totalItems > 0 then
        local profitStr
        if totalProfit >= 0 then
            profitStr = "|cff33cc33Ø " .. FormatGold(math.floor(totalProfit)) .. "|r"
        else
            profitStr = "|cffcc3333Ø -" .. FormatGold(math.floor(math.abs(totalProfit))) .. "|r"
        end
        craftSimPanel.profitText:SetText(totalItems .. " items | " .. profitStr .. " | Cost: " .. FormatGold(math.floor(totalCost)))
    else
        craftSimPanel.profitText:SetText("Queue empty")
    end

    -- Update Next button label — check claimed order first, then queue items
    local nextBtn = craftSimPanel.nextClaimBtn
    local claimed = C_CraftingOrders.GetClaimedOrder and C_CraftingOrders.GetClaimedOrder()
    if claimed then
        if claimed.isFulfillable then
            nextBtn.label:SetText("Complete")
        else
            nextBtn.label:SetText("Craft")
        end
    elseif totalItems > 0 then
        -- No claimed order but queue has items — next action is claim
        local hasOrder = false
        for _, item in ipairs(items) do
            if item.recipeData and item.recipeData.orderData then
                hasOrder = true
                break
            end
        end
        nextBtn.label:SetText(hasOrder and "Claim" or "Craft")
    else
        nextBtn.label:SetText("--")
    end
end

local function ShowCraftSimQueue()
    if not craftSimPanel then return false end
    if HasCraftSim() then
        craftSimPanel:Show()
        ProfOrders:RefreshCraftSimQueue()
        -- Hide CraftSim's own floating CraftQueue window to avoid duplication
        if CraftSimLib.CRAFTQ.frame and CraftSimLib.CRAFTQ.frame.frame then
            CraftSimLib.CRAFTQ.frame.frame:Hide()
        end
        return true
    else
        craftSimPanel:Show()
        craftSimPanel.noCraftSimText:Show()
        for _, row in ipairs(craftSimQueueRows) do row:Hide() end
        return false
    end
end

local function HideCraftSimQueue()
    if craftSimPanel then
        craftSimPanel:Hide()
    end
end

--------------------------------------------------------------------
-- Right panel (detail top + CraftSim bottom)
--------------------------------------------------------------------

local function CreateRightPanel(parent)
    -- Container for the whole right side
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", LEFT_PANEL_WIDTH + 1, 0)
    container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    -- CraftSim panel at bottom
    craftSimPanel = CreateCraftSimPanel(container)
    craftSimPanel:SetHeight(CRAFTSIM_PANEL_HEIGHT)
    craftSimPanel:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    craftSimPanel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)

    -- Detail panel fills above CraftSim
    local f = CreateDetailPanel(container)
    f:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", craftSimPanel, "TOPRIGHT", 0, -1)

    return f
end

--------------------------------------------------------------------
-- Init
--------------------------------------------------------------------
function ProfOrders:Init(parent)
    if initialized then
        parentFrame = parent
        return
    end
    parentFrame = parent

    -- Main container
    mainPanel = CreateFrame("Frame", nil, parent)
    mainPanel:SetAllPoints(parent)

    -- Left side (order list)
    leftPanel = CreateLeftPanel(mainPanel)

    -- Right side (order detail)
    rightPanel = CreateRightPanel(mainPanel)
    detailFrame = rightPanel

    -- Unavailable overlay (on top of everything)
    unavailableOverlay = CreateUnavailableOverlay(mainPanel)

    -- Event frame
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("CRAFTINGORDERS_UPDATE_ORDER_COUNT")
    eventFrame:RegisterEvent("CRAFTINGORDERS_CAN_REQUEST")
    eventFrame:RegisterEvent("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE")
    eventFrame:RegisterEvent("CRAFTINGORDERS_RELEASE_ORDER_RESPONSE")
    eventFrame:RegisterEvent("CRAFTINGORDERS_REJECT_ORDER_RESPONSE")
    eventFrame:RegisterEvent("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE")
    eventFrame:RegisterEvent("CRAFTINGORDERS_CLAIMED_ORDER_ADDED")
    eventFrame:RegisterEvent("CRAFTINGORDERS_CLAIMED_ORDER_REMOVED")
    eventFrame:RegisterEvent("CRAFTINGORDERS_CLAIMED_ORDER_UPDATED")
    eventFrame:RegisterEvent("CRAFTINGORDERS_UNEXPECTED_ERROR")
    eventFrame:RegisterEvent("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME")
    eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        ProfOrders:OnEvent(event, ...)
    end)

    initialized = true
    mainPanel:Hide()
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function ProfOrders:Show()
    if not mainPanel then return end
    mainPanel:Show()

    professionEnum = GetProfessionEnum()

    -- Check availability
    local available = IsAtCraftingTable()
    if available then
        unavailableOverlay:Hide()
        -- Refresh
        activeOrderType = Enum.CraftingOrderType.Npc
        UpdateOrderTypeTabHighlights()
        self:RequestOrders(true)  -- force: user opened tab
        self:UpdateClaimCapacity()
    else
        unavailableOverlay:Show()
    end

    -- Show embedded CraftSim queue panel
    ShowCraftSimQueue()
end

function ProfOrders:Hide()
    HideCraftSimQueue()
    if mainPanel then
        mainPanel:Hide()
    end
end

function ProfOrders:IsShown()
    return mainPanel and mainPanel:IsShown()
end

--------------------------------------------------------------------
-- Order type selection
--------------------------------------------------------------------
function ProfOrders:SelectOrderType(orderType)
    if activeOrderType == orderType then return end
    activeOrderType = orderType
    selectedOrder = nil
    selectedBucket = nil
    scrollOffset = 0
    currentOffset = 0
    currentOrders = {}

    UpdateOrderTypeTabHighlights()
    self:ClearDetail()
    self:RequestOrders(true)  -- force: user switched tabs
end

--------------------------------------------------------------------
-- Request orders from server (throttled)
--------------------------------------------------------------------
local lastRequestTime = 0
local REQUEST_COOLDOWN = 2  -- minimum seconds between server requests

function ProfOrders:RequestOrders(force)
    if not C_CraftingOrders or not C_CraftingOrders.RequestCrafterOrders then return end
    if not professionEnum then
        professionEnum = GetProfessionEnum()
        if not professionEnum then return end
    end

    -- Throttle: don't spam server
    local now = GetTime()
    if not force and (now - lastRequestTime) < REQUEST_COOLDOWN then return end
    lastRequestTime = now

    isLoading = true
    leftPanel.loadingText:Show()
    leftPanel.emptyText:Hide()

    -- If we're drilled into a bucket, request flat orders for that recipe
    local selectedAbility = nil
    if selectedBucket then
        selectedAbility = selectedBucket.skillLineAbilityID
    end

    local request = {
        orderType = activeOrderType,
        forCrafter = true,
        profession = professionEnum,
        selectedSkillLineAbility = selectedAbility,
        searchFavorites = false,
        initialNonPublicSearch = (selectedAbility == nil and activeOrderType ~= Enum.CraftingOrderType.Public),
        offset = currentOffset,
        primarySort = {
            sortType = primarySort.sortType,
            reversed = primarySort.reversed,
        },
        secondarySort = {
            sortType = secondarySort.sortType,
            reversed = secondarySort.reversed,
        },
        callback = C_FunctionContainers.CreateCallback(function(result, orderType, buckets, moreRows, offset, sorted)
            ProfOrders:OnOrdersReceived(result, orderType, buckets, moreRows, offset, sorted)
        end),
    }

    local ok, err = pcall(C_CraftingOrders.RequestCrafterOrders, request)
    if not ok then
        isLoading = false
        leftPanel.loadingText:Hide()
        leftPanel.emptyText:SetText("Error requesting orders")
        leftPanel.emptyText:Show()
    end
end

--------------------------------------------------------------------
-- Callback: orders received
--------------------------------------------------------------------
function ProfOrders:OnOrdersReceived(result, orderType, useBuckets, moreRows, offset, sorted)
    isLoading = false
    leftPanel.loadingText:Hide()

    if result ~= Enum.CraftingOrderResult.Ok then
        leftPanel.emptyText:SetText("Failed to load orders")
        leftPanel.emptyText:Show()
        currentOrders = {}
        self:RefreshList()
        return
    end

    displayBuckets = useBuckets
    expectMoreRows = moreRows

    if useBuckets then
        local ok, buckets = pcall(C_CraftingOrders.GetCrafterBuckets)
        currentOrders = ok and buckets or {}
    else
        local ok, orders = pcall(C_CraftingOrders.GetCrafterOrders)
        currentOrders = ok and orders or {}
    end

    scrollOffset = 0
    self:FilterAndRefreshList()
end

--------------------------------------------------------------------
-- Filter + refresh list
--------------------------------------------------------------------
local filteredOrders = {}

function ProfOrders:FilterAndRefreshList()
    wipe(filteredOrders)

    if searchText == "" then
        for _, order in ipairs(currentOrders) do
            table.insert(filteredOrders, order)
        end
    else
        local needle = searchText:lower()
        for _, order in ipairs(currentOrders) do
            local itemID = order.itemID
            local name = itemID and GetItemName(itemID) or ""
            if name:lower():find(needle, 1, true) then
                table.insert(filteredOrders, order)
            end
        end
    end

    self:RefreshList()
end

--------------------------------------------------------------------
-- Refresh list display
--------------------------------------------------------------------
function ProfOrders:RefreshList()
    local total = #filteredOrders

    leftPanel.emptyText:SetShown(total == 0 and not isLoading)
    if total == 0 and not isLoading then
        leftPanel.emptyText:SetText("No orders found")
    end

    for i = 1, VISIBLE_ROWS do
        local row = listRows[i]
        local dataIdx = scrollOffset + i
        local data = filteredOrders[dataIdx]

        if data then
            row:Show()
            row.orderData = data

            local itemID = data.itemID
            local icon = GetItemIcon(itemID)
            if icon then
                row.icon:SetTexture(icon)
                row.icon:Show()
            else
                row.icon:Hide()
            end

            row.nameText:SetText(GetItemName(itemID))

            if displayBuckets then
                -- Bucket view
                row.isBucket = true
                row.subText:SetText(data.numAvailable .. " orders")
                row.subText:SetTextColor(unpack(ns.COLORS.mutedText))
                row.tipText:SetText(FormatGold(data.tipAmountMax))
                row.timeText:SetText("")
                row.nameText:SetTextColor(unpack(ns.COLORS.brightText))
            else
                -- Flat order view
                row.isBucket = false
                row.tipText:SetText(FormatGold(data.tipAmount))
                row.timeText:SetText(FormatTimeLeft(data.expirationTime))

                -- Check if recipe is learned
                local isLearned = true
                if data.spellID then
                    local recipeInfo = C_TradeSkillUI.GetRecipeInfo(data.spellID)
                    if recipeInfo and not recipeInfo.learned then
                        isLearned = false
                    end
                end

                if not isLearned then
                    row.subText:SetText("|cffcc3333Recipe Unlearned|r")
                    row.nameText:SetTextColor(0.6, 0.6, 0.6)
                else
                    row.subText:SetText(GetReagentStateName(data.reagentState))
                    row.subText:SetTextColor(unpack(ns.COLORS.mutedText))
                    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))
                end
            end

            -- Selection highlight
            local isSelected = false
            if selectedOrder and not displayBuckets and data.orderID == selectedOrder.orderID then
                isSelected = true
            end
            row.isSelected = isSelected
            if isSelected then
                row.bg:SetColorTexture(unpack(ns.COLORS.rowSelected))
                row.leftAccent:Show()
            else
                row.bg:SetColorTexture(1, 1, 1, 0)
                row.leftAccent:Hide()
            end
        else
            row:Hide()
            row.orderData = nil
        end
    end

    -- Update scroll bar
    scrollBar:Update(total, VISIBLE_ROWS, scrollOffset)
end

--------------------------------------------------------------------
-- Select order (detail view)
--------------------------------------------------------------------
function ProfOrders:SelectOrder(orderInfo)
    selectedOrder = orderInfo
    self:RefreshList()
    self:RefreshDetail()
end

--------------------------------------------------------------------
-- Drill into bucket
--------------------------------------------------------------------
function ProfOrders:DrillIntoBucket(bucketInfo)
    selectedBucket = bucketInfo
    currentOffset = 0
    self:RequestOrders(true)  -- force: user action
    detailFrame.backBtn:Show()
end

function ProfOrders:BackFromBucket()
    selectedBucket = nil
    selectedOrder = nil
    currentOffset = 0
    detailFrame.backBtn:Hide()
    self:ClearDetail()
    self:RequestOrders(true)  -- force: user action
end

--------------------------------------------------------------------
-- Refresh detail panel
--------------------------------------------------------------------
function ProfOrders:RefreshDetail()
    local order = selectedOrder
    if not order then
        self:ClearDetail()
        return
    end

    local content = detailFrame.content
    detailFrame.emptyText:Hide()
    content:Show()

    -- Icon
    local icon = GetItemIcon(order.itemID)
    if icon then
        content.icon:SetTexture(icon)
        content.icon:Show()
    else
        content.icon:Hide()
    end

    -- Name
    content.nameText:SetText(GetItemName(order.itemID))

    -- Quality pip (minimum required tier)
    if order.minQuality and order.minQuality > 0 then
        content.qualityStars:SetText("|A:Professions-Icon-Quality-Tier" .. order.minQuality .. "-Small:0:0|a")
        content.qualityStars:Show()
    else
        content.qualityStars:Hide()
    end

    -- Customer
    if order.customerName then
        content.customerText:SetText("From: " .. order.customerName)
        content.customerText:Show()
    elseif order.npcCustomerCreatureID then
        content.customerText:SetText("Patron Order")
        content.customerText:Show()
    else
        content.customerText:SetText("Public Order")
        content.customerText:Show()
    end

    -- Tip
    content.tipValue:SetText(FormatGold(order.tipAmount or 0))

    -- Consortium cut
    if order.consortiumCut and order.consortiumCut > 0 then
        content.cutValue:SetText("-" .. FormatGold(order.consortiumCut))
        content.cutLabel:Show()
        content.cutValue:Show()
    else
        content.cutLabel:Hide()
        content.cutValue:Hide()
    end

    -- Time remaining
    content.timeValue:SetText(FormatTimeLeft(order.expirationTime))

    -- Min quality
    if order.minQuality and order.minQuality > 0 then
        content.qualValue:SetText("Tier " .. order.minQuality)
        content.qualLabel:Show()
        content.qualValue:Show()
    else
        content.qualLabel:Hide()
        content.qualValue:Hide()
    end

    -- Reagent state
    content.reagentValue:SetText(GetReagentStateName(order.reagentState))

    -- Provided reagents
    local reagents = order.reagents or {}
    local hasReagents = #reagents > 0
    content.reagentsHeader:SetShown(hasReagents)

    for i, rr in ipairs(content.reagentRows) do
        rr:Hide()
    end

    if hasReagents then
        for i, reagentData in ipairs(reagents) do
            if i > 12 then break end
            local rr = content.reagentRows[i]
            rr:Show()

            local reagentItemID = reagentData.reagentInfo and reagentData.reagentInfo.reagent and reagentData.reagentInfo.reagent.itemID
            if reagentItemID then
                local rIcon = GetItemIcon(reagentItemID)
                if rIcon then
                    rr.icon:SetTexture(rIcon)
                    rr.icon:Show()
                else
                    rr.icon:Hide()
                end
                rr.nameText:SetText(GetItemName(reagentItemID))
            else
                rr.icon:Hide()
                rr.nameText:SetText("Unknown Reagent")
            end

            local qty = reagentData.reagentInfo and reagentData.reagentInfo.quantity or 0
            rr.qtyText:SetText("x" .. qty)

            -- Color by source
            if reagentData.source == Enum.CraftingOrderReagentSource.Customer then
                rr.nameText:SetTextColor(unpack(ns.COLORS.greenText))
            else
                rr.nameText:SetTextColor(unpack(ns.COLORS.brightText))
            end
        end
    end

    -- Notes
    local notesY = self:GetNotesAnchorY(#reagents)
    if order.customerNotes and order.customerNotes ~= "" then
        content.notesLabel:ClearAllPoints()
        content.notesLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, notesY)
        content.notesLabel:Show()

        content.notesText:ClearAllPoints()
        content.notesText:SetPoint("TOPLEFT", content.notesLabel, "BOTTOMLEFT", 0, -4)
        content.notesText:SetWidth(content:GetWidth() - 20)
        content.notesText:SetText(order.customerNotes)
        content.notesText:Show()
    else
        content.notesLabel:Hide()
        content.notesText:Hide()
    end

    -- NPC rewards
    if order.npcOrderRewards and #order.npcOrderRewards > 0 then
        local rewardsStr = ""
        for _, reward in ipairs(order.npcOrderRewards) do
            local rewardLine
            if reward.itemLink and reward.itemLink ~= "" then
                -- Try to resolve item name + icon from the link
                local name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(reward.itemLink)
                if name then
                    rewardLine = (icon and ("|T" .. icon .. ":0|t ") or "") .. name
                else
                    -- Item not cached — request it, show itemID as placeholder
                    local itemID = GetItemInfoInstant(reward.itemLink)
                    if itemID then
                        C_Item.RequestLoadItemDataByID(itemID)
                        rewardLine = "Item:" .. itemID
                    end
                end
            end
            if not rewardLine and reward.currencyType then
                -- Currency reward (e.g., Artisan's Acuity)
                local info = C_CurrencyInfo.GetCurrencyInfo(reward.currencyType)
                if info then
                    local icon = info.iconFileID and ("|T" .. info.iconFileID .. ":0|t ") or ""
                    rewardLine = icon .. info.name
                else
                    rewardLine = "Currency " .. reward.currencyType
                end
            end
            if rewardLine then
                if reward.count and reward.count > 1 then
                    rewardLine = rewardLine .. " x" .. reward.count
                end
                rewardsStr = rewardsStr .. rewardLine .. "\n"
            end
        end
        content.rewardsLabel:ClearAllPoints()
        if content.notesText:IsShown() then
            content.rewardsLabel:SetPoint("TOPLEFT", content.notesText, "BOTTOMLEFT", 0, -8)
        else
            content.rewardsLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, notesY)
        end
        content.rewardsLabel:Show()
        content.rewardsText:ClearAllPoints()
        content.rewardsText:SetPoint("TOPLEFT", content.rewardsLabel, "BOTTOMLEFT", 0, -4)
        content.rewardsText:SetText(rewardsStr)
        content.rewardsText:Show()
    else
        content.rewardsLabel:Hide()
        content.rewardsText:Hide()
    end

    -- Recipe source info (for unlearned recipes)
    local isLearned = true
    if order.spellID then
        local recipeInfo = C_TradeSkillUI.GetRecipeInfo(order.spellID)
        if recipeInfo and not recipeInfo.learned then
            isLearned = false
        end
    end

    if not isLearned and order.spellID then
        local sourceText = C_TradeSkillUI.GetRecipeSourceText(order.spellID)
        content.recipeSourceLabel:SetText("Recipe Unlearned")
        content.recipeSourceText:SetText(sourceText or "Source unknown")

        -- Position below last visible section
        content.recipeSourceFrame:ClearAllPoints()
        local anchor
        if content.rewardsText:IsShown() then
            anchor = content.rewardsText
        elseif content.notesText:IsShown() then
            anchor = content.notesText
        elseif content.rewardsLabel:IsShown() then
            anchor = content.rewardsLabel
        else
            anchor = content.reagentValue
        end
        content.recipeSourceFrame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -8, -8)
        content.recipeSourceFrame:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        -- Size to fit content
        content.recipeSourceFrame:SetHeight(200)
        content.recipeSourceFrame:Show()
        local labelH = content.recipeSourceLabel:GetStringHeight() or 12
        local textH = content.recipeSourceText:GetStringHeight() or 14
        content.recipeSourceFrame:SetHeight(labelH + textH + 20)
    else
        content.recipeSourceFrame:Hide()
    end

    -- Update action buttons
    self:UpdateActionButtons()

    -- Claim capacity
    self:UpdateClaimCapacity()
end

function ProfOrders:GetNotesAnchorY(numReagents)
    -- Calculate Y position for notes based on header + info rows + reagent rows
    local y = -(DETAIL_ICON_SIZE + 16)  -- after header
    y = y - (18 * 4)                     -- 4 info rows (tip, cut, time, quality)
    y = y - 22                           -- reagent state row
    if numReagents > 0 then
        y = y - 16                       -- reagents header
        y = y - (numReagents * REAGENT_ROW_HEIGHT)
    end
    y = y - 8
    return y
end

--------------------------------------------------------------------
-- Clear detail
--------------------------------------------------------------------
function ProfOrders:ClearDetail()
    selectedOrder = nil
    if not detailFrame then return end
    detailFrame.emptyText:Show()
    detailFrame.content:Hide()
    detailFrame.claimBtn:Hide()
    detailFrame.declineBtn:Hide()
    detailFrame.fulfillBtn:Hide()
    detailFrame.claimCapText:SetText("")
end

--------------------------------------------------------------------
-- Action buttons
--------------------------------------------------------------------
function ProfOrders:UpdateActionButtons()
    local order = selectedOrder
    if not order then
        detailFrame.claimBtn:Hide()
        detailFrame.declineBtn:Hide()
        detailFrame.fulfillBtn:Hide()
        return
    end

    -- Get claimed order for this profession
    claimedOrder = nil
    if C_CraftingOrders.GetClaimedOrder then
        local ok, claimed = pcall(C_CraftingOrders.GetClaimedOrder)
        if ok then claimedOrder = claimed end
    end

    local isClaimed = claimedOrder and claimedOrder.orderID == order.orderID
    local hasAnyClaimed = claimedOrder ~= nil

    if isClaimed then
        -- This order is claimed by us
        if order.isFulfillable then
            -- Ready to fulfill
            detailFrame.claimBtn:Hide()
            detailFrame.declineBtn:Hide()
            detailFrame.fulfillBtn:Show()
        else
            -- Claimed but need to craft first — show Start crafting
            detailFrame.claimBtn:Show()
            detailFrame.claimBtn.label:SetText("Start Craft")
            detailFrame.declineBtn:Show()
            detailFrame.declineBtn.label:SetText("Release")
            detailFrame.fulfillBtn:Hide()
        end
    else
        -- Not claimed — show Claim button (disabled if already have a claimed order)
        detailFrame.claimBtn:Show()
        detailFrame.claimBtn.label:SetText("Claim Order")
        if hasAnyClaimed then
            detailFrame.claimBtn:Disable()
        else
            detailFrame.claimBtn:Enable()
        end
        detailFrame.declineBtn:Hide()
        detailFrame.fulfillBtn:Hide()
    end
end

--------------------------------------------------------------------
-- Claim capacity display
--------------------------------------------------------------------
function ProfOrders:UpdateClaimCapacity()
    if not professionEnum then return end
    if not C_CraftingOrders.GetOrderClaimInfo then return end
    local ok, claimInfo = pcall(C_CraftingOrders.GetOrderClaimInfo, professionEnum)
    if ok and claimInfo then
        local text = "Claims: " .. (claimInfo.claimsRemaining or "?")
        if claimInfo.secondsToRecharge then
            local mins = math.ceil(claimInfo.secondsToRecharge / 60)
            text = text .. " (next in " .. mins .. "m)"
        end
        detailFrame.claimCapText:SetText(text)
    end
end

--------------------------------------------------------------------
-- Action handlers
--------------------------------------------------------------------
function ProfOrders:OnClaimOrStart()
    local order = selectedOrder
    if not order or not professionEnum then return end

    -- Check if this order is already claimed by us
    if claimedOrder and claimedOrder.orderID == order.orderID then
        -- Start crafting — open the recipe in Blizzard's schematic form
        -- The user crafts via normal profession UI, then comes back to fulfill
        if order.spellID then
            C_TradeSkillUI.OpenRecipe(order.spellID)
        end
        return
    end

    -- Claim the order
    local ok, err = pcall(C_CraftingOrders.ClaimOrder, order.orderID, professionEnum)
    if not ok then
        print("|cffc8aa64KazCraft:|r Failed to claim order: " .. tostring(err))
    end
end

function ProfOrders:OnDeclineOrRelease()
    local order = selectedOrder
    if not order or not professionEnum then return end

    -- If claimed by us, release it
    if claimedOrder and claimedOrder.orderID == order.orderID then
        local ok, err = pcall(C_CraftingOrders.ReleaseOrder, order.orderID, professionEnum)
        if not ok then
            print("|cffc8aa64KazCraft:|r Failed to release order: " .. tostring(err))
        end
    else
        -- Reject (for personal/guild orders we haven't claimed)
        local ok, err = pcall(C_CraftingOrders.RejectOrder, order.orderID, "", professionEnum)
        if not ok then
            print("|cffc8aa64KazCraft:|r Failed to reject order: " .. tostring(err))
        end
    end
end

function ProfOrders:OnFulfill()
    local order = selectedOrder
    if not order or not professionEnum then return end

    local ok, err = pcall(C_CraftingOrders.FulfillOrder, order.orderID, "", professionEnum)
    if not ok then
        print("|cffc8aa64KazCraft:|r Failed to fulfill order: " .. tostring(err))
    end
end

--------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------
function ProfOrders:OnEvent(event, ...)
    if not mainPanel or not mainPanel:IsShown() then return end

    if event == "CRAFTINGORDERS_CLAIM_ORDER_RESPONSE" then
        local result, orderID = ...
        if result == Enum.CraftingOrderResult.Ok then
            print("|cffc8aa64KazCraft:|r Order claimed!")
            self:UpdateActionButtons()
            self:UpdateClaimCapacity()
        else
            print("|cffc8aa64KazCraft:|r Claim failed (code " .. tostring(result) .. ")")
        end

    elseif event == "CRAFTINGORDERS_CLAIMED_ORDER_ADDED" then
        -- Refresh to show the claimed state
        self:RequestOrders(true)

    elseif event == "CRAFTINGORDERS_CLAIMED_ORDER_REMOVED" then
        claimedOrder = nil
        self:UpdateActionButtons()
        self:RequestOrders(true)

    elseif event == "CRAFTINGORDERS_CLAIMED_ORDER_UPDATED" then
        -- Order state changed (e.g., crafting done, now fulfillable)
        if claimedOrder then
            local ok, updated = pcall(C_CraftingOrders.GetClaimedOrder)
            if ok and updated then
                claimedOrder = updated
                if selectedOrder and selectedOrder.orderID == updated.orderID then
                    selectedOrder = updated
                    self:RefreshDetail()
                end
            end
        end
        -- Refresh CraftSim queue (status may have changed)
        self:RefreshCraftSimQueue()

    elseif event == "CRAFTINGORDERS_RELEASE_ORDER_RESPONSE" then
        local result, orderID = ...
        if result == Enum.CraftingOrderResult.Ok then
            print("|cffc8aa64KazCraft:|r Order released.")
            selectedOrder = nil
            self:ClearDetail()
            self:RequestOrders(true)
        end

    elseif event == "CRAFTINGORDERS_REJECT_ORDER_RESPONSE" then
        local result, orderID = ...
        if result == Enum.CraftingOrderResult.Ok then
            print("|cffc8aa64KazCraft:|r Order rejected.")
            selectedOrder = nil
            self:ClearDetail()
            self:RequestOrders(true)
        end

    elseif event == "CRAFTINGORDERS_FULFILL_ORDER_RESPONSE" then
        local result, orderID = ...
        if result == Enum.CraftingOrderResult.Ok then
            print("|cffc8aa64KazCraft:|r Order completed! Payment received.")
            selectedOrder = nil
            claimedOrder = nil
            self:ClearDetail()
            self:RequestOrders(true)
            -- Refresh CraftSim queue (item should already be removed by our button handler)
            C_Timer.After(0.3, function() self:RefreshCraftSimQueue() end)
        else
            print("|cffc8aa64KazCraft:|r Fulfill failed (code " .. tostring(result) .. ")")
        end

    elseif event == "CRAFTINGORDERS_UPDATE_ORDER_COUNT" then
        -- Tab counts changed — don't auto-refresh, too aggressive on server
        -- User can switch tabs to refresh

    elseif event == "CRAFTINGORDERS_CAN_REQUEST" then
        -- Server throttle lifted — only request if we have a pending request
        if isLoading then
            self:RequestOrders(true)
        end

    elseif event == "CRAFTINGORDERS_UPDATE_CUSTOMER_NAME" then
        local customerName, orderID = ...
        -- Update the name if we're viewing this order
        if selectedOrder and selectedOrder.orderID == orderID then
            selectedOrder.customerName = customerName
            self:RefreshDetail()
        end

    elseif event == "CRAFTINGORDERS_UNEXPECTED_ERROR" then
        print("|cffc8aa64KazCraft:|r Crafting orders error occurred.")

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Reward item data loaded — refresh detail if viewing an order
        if selectedOrder then
            self:RefreshDetail()
        end
    end
end
