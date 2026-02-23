local addonName, ns = ...

local AHSell = {}
ns.AHSell = AHSell

-- Duration enum (1=12h, 2=24h, 3=48h)
local DURATIONS = {
    { value = 1, label = "12h" },
    { value = 2, label = "24h" },
    { value = 3, label = "48h" },
}

local LIST_ROW_HEIGHT = 22
local MAX_LIST_ROWS = 12

local BACKDROP_FLAT = {
    bgFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeSize = 1,
}

-- State
local container
local leftPanel, rightPanel
local postArea
local dropTarget
local itemIcon, itemNameText, itemQualityBadge
local qtyBox, maxBtn
local priceGold, priceSilver, priceCopper
local durationIdx = 3  -- default 48h
local durationBtns = {}
local depositText
local postBtn
local listingRows = {}
local listingContent, listingScroll
local listingHeader
local bagScroll, bagContent, bagPlaceholder
local bagIconPool = {}       -- reusable icon buttons
local bagHeaderPool = {}     -- reusable category header FontStrings
local selectedBagItemID = nil  -- currently highlighted bag icon
local sellItemLocation = nil
local sellItemID = nil
local sellItemKey = nil
local sellIsCommodity = false
local pendingPostArgs = nil
local EnsurePostWarningHooked  -- forward declaration

-- Cached clean values for PostItem — updated by OnTextChanged handlers.
local cachedUnitPrice = 0
local cachedQty = 1

-- On retail, PostItem SILENTLY FAILS if the price contains copper.
-- Prices must be whole silver (multiples of 100 copper), minimum 1s.
-- Auctionator has the same workaround (NormalizePrice).
local function NormalizePrice(copper)
    if copper % 100 ~= 0 then
        copper = copper + (100 - copper % 100)
    end
    if copper < 100 then copper = 100 end
    return copper
end

-- Get crafting quality tier (1-5) for an item, nil if non-crafted
-- Use shared helpers from Util.lua
local GetCraftingQuality = function(itemID) return ns.GetCraftingQuality(itemID) end
local GetQualityAtlas = function(tier) return ns.GetQualityAtlas(tier) end

--------------------------------------------------------------------
-- Duration radio helpers
--------------------------------------------------------------------
local function UpdateDurationButtons()
    for i, btn in ipairs(durationBtns) do
        if i == durationIdx then
            btn.label:SetTextColor(unpack(ns.COLORS.tabActive))
            btn:SetBackdropBorderColor(unpack(ns.COLORS.accent))
        else
            btn.label:SetTextColor(unpack(ns.COLORS.mutedText))
            btn:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
        end
    end
end

--------------------------------------------------------------------
-- Post button enable/disable
--------------------------------------------------------------------
function AHSell:UpdatePostButton()
    if not postBtn then return end
    if sellItemLocation then
        postBtn:Enable()
        postBtn:SetAlpha(1)
        postBtn.label:SetTextColor(unpack(ns.COLORS.btnDefault))
    else
        postBtn:Disable()
        postBtn:SetAlpha(0.4)
        postBtn.label:SetTextColor(unpack(ns.COLORS.mutedText))
    end
end

--------------------------------------------------------------------
-- Listing row factory
--------------------------------------------------------------------
local function CreateListingRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(LIST_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * LIST_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * LIST_ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row._defaultBgAlpha = (index % 2 == 0) and 0.03 or 0
    row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)

    -- Buyout price (left)
    row.priceText = row:CreateFontString(nil, "OVERLAY")
    row.priceText:SetFont(ns.FONT, 10, "")
    row.priceText:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.priceText:SetWidth(140)
    row.priceText:SetJustifyH("LEFT")
    row.priceText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Qty (center)
    row.qtyText = row:CreateFontString(nil, "OVERLAY")
    row.qtyText:SetFont(ns.FONT, 10, "")
    row.qtyText:SetPoint("RIGHT", row, "RIGHT", -90, 0)
    row.qtyText:SetWidth(40)
    row.qtyText:SetJustifyH("RIGHT")
    row.qtyText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Quality badge (small atlas)
    row.qualityIcon = row:CreateTexture(nil, "OVERLAY")
    row.qualityIcon:SetSize(14, 14)
    row.qualityIcon:SetPoint("RIGHT", row, "RIGHT", -55, 0)
    row.qualityIcon:Hide()

    -- Owned? (far right)
    row.ownerTag = row:CreateFontString(nil, "OVERLAY")
    row.ownerTag:SetFont(ns.FONT, 9, "")
    row.ownerTag:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.ownerTag:SetWidth(40)
    row.ownerTag:SetJustifyH("RIGHT")
    row.ownerTag:SetTextColor(unpack(ns.COLORS.greenText))
    row.ownerTag:Hide()

    row._unitPrice = 0
    row._craftQuality = nil

    row:SetScript("OnClick", function(self)
        if self._unitPrice and self._unitPrice > 0 then
            AHSell:SetInputPrice(self._unitPrice)
            AHSell:UpdateDeposit()
        end
    end)

    row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
    end)
    row:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(1, 1, 1, self._defaultBgAlpha)
    end)

    row:Hide()
    return row
end

--------------------------------------------------------------------
-- Build UI
--------------------------------------------------------------------
function AHSell:Init(contentFrame)
    if container then
        container:SetParent(contentFrame)
        container:SetAllPoints()
        return
    end
    container = CreateFrame("Frame", nil, contentFrame)
    container:SetAllPoints()
    container:Hide()

    ----------------------------------------------------------------
    -- Left panel (fixed 220px)
    ----------------------------------------------------------------
    leftPanel = CreateFrame("Frame", nil, container)
    leftPanel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    leftPanel:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)

    ----------------------------------------------------------------
    -- Posting area (top section, own backdrop)
    ----------------------------------------------------------------
    postArea = CreateFrame("Frame", nil, leftPanel, "BackdropTemplate")
    postArea:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 4, -4)
    postArea:SetPoint("TOPRIGHT", leftPanel, "TOPRIGHT", -4, -4)
    postArea:SetHeight(220)
    postArea:SetBackdrop(BACKDROP_FLAT)
    postArea:SetBackdropColor(15/255, 15/255, 15/255, 0.5)
    postArea:SetBackdropBorderColor(70/255, 65/255, 55/255, 1)

    -- Item slot (32x32)
    dropTarget = CreateFrame("Button", nil, postArea)
    dropTarget:SetSize(32, 32)
    dropTarget:SetPoint("TOPLEFT", postArea, "TOPLEFT", 10, -10)
    dropTarget:RegisterForClicks("LeftButtonUp")

    local dropBg = dropTarget:CreateTexture(nil, "BACKGROUND")
    dropBg:SetAllPoints()
    dropBg:SetColorTexture(unpack(ns.COLORS.panelBg))

    local dropBorder = CreateFrame("Frame", nil, dropTarget, "BackdropTemplate")
    dropBorder:SetAllPoints()
    dropBorder:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
    dropBorder:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    itemIcon = dropTarget:CreateTexture(nil, "ARTWORK")
    itemIcon:SetAllPoints()
    itemIcon:SetTexture(134400)
    itemIcon:SetAlpha(0.3)

    -- "Select item" label (beside icon, shown when empty)
    local selectLabel = postArea:CreateFontString(nil, "OVERLAY")
    selectLabel:SetFont(ns.FONT, 11, "")
    selectLabel:SetPoint("LEFT", dropTarget, "RIGHT", 8, 0)
    selectLabel:SetText("Select item")
    selectLabel:SetTextColor(unpack(ns.COLORS.mutedText))
    dropTarget._selectLabel = selectLabel

    dropTarget:SetScript("OnClick", function() AHSell:AcceptCursorItem() end)
    dropTarget:SetScript("OnReceiveDrag", function() AHSell:AcceptCursorItem() end)
    dropTarget:SetScript("OnEnter", function(self)
        if sellItemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(sellItemID)
            GameTooltip:Show()
        end
    end)
    dropTarget:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Item name (below icon)
    itemNameText = postArea:CreateFontString(nil, "OVERLAY")
    itemNameText:SetFont(ns.FONT, 11, "")
    itemNameText:SetPoint("TOPLEFT", dropTarget, "BOTTOMLEFT", 0, -4)
    itemNameText:SetPoint("RIGHT", postArea, "RIGHT", -24, 0)
    itemNameText:SetJustifyH("LEFT")
    itemNameText:SetWordWrap(false)
    itemNameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Crafting quality badge (next to item name)
    itemQualityBadge = postArea:CreateTexture(nil, "OVERLAY")
    itemQualityBadge:SetSize(17, 17)
    itemQualityBadge:SetPoint("LEFT", itemNameText, "RIGHT", 2, 0)
    itemQualityBadge:Hide()

    -- Quantity row
    local qtyLabel = postArea:CreateFontString(nil, "OVERLAY")
    qtyLabel:SetFont(ns.FONT, 10, "")
    qtyLabel:SetPoint("TOPLEFT", itemNameText, "BOTTOMLEFT", 0, -10)
    qtyLabel:SetText("Quantity:")
    qtyLabel:SetTextColor(unpack(ns.COLORS.headerText))

    qtyBox = CreateFrame("EditBox", nil, postArea, "BackdropTemplate")
    qtyBox:SetSize(50, 20)
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 6, 0)
    qtyBox:SetBackdrop(BACKDROP_FLAT)
    qtyBox:SetBackdropColor(unpack(ns.COLORS.searchBg))
    qtyBox:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    qtyBox:SetFont(ns.FONT, 10, "")
    qtyBox:SetTextColor(unpack(ns.COLORS.brightText))
    qtyBox:SetJustifyH("CENTER")
    qtyBox:SetAutoFocus(false)
    qtyBox:SetNumeric(true)
    qtyBox:SetMaxLetters(5)
    qtyBox:SetText("1")
    qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    qtyBox:SetScript("OnTextChanged", function()
        cachedQty = tonumber(qtyBox:GetText()) or 1
        if cachedQty < 1 then cachedQty = 1 end
        AHSell:UpdateDeposit()
    end)

    maxBtn = ns.CreateButton(postArea, "Max", 36, 20)
    maxBtn:SetPoint("LEFT", qtyBox, "RIGHT", 4, 0)
    maxBtn:SetScript("OnClick", function()
        if sellItemID then
            local count = C_Item.GetItemCount(sellItemID, false, false, false, false)
            qtyBox:SetText(tostring(math.min(count, 200)))
        end
    end)

    -- Duration row (three radio-style toggles)
    local durLabel = postArea:CreateFontString(nil, "OVERLAY")
    durLabel:SetFont(ns.FONT, 10, "")
    durLabel:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", 0, -8)
    durLabel:SetText("Duration:")
    durLabel:SetTextColor(unpack(ns.COLORS.headerText))

    for i, dur in ipairs(DURATIONS) do
        local btn = CreateFrame("Button", nil, postArea, "BackdropTemplate")
        btn:SetSize(36, 20)
        btn:SetBackdrop(BACKDROP_FLAT)
        btn:SetBackdropColor(20/255, 20/255, 20/255, 0.6)
        btn:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

        btn.label = btn:CreateFontString(nil, "OVERLAY")
        btn.label:SetFont(ns.FONT, 10, "")
        btn.label:SetPoint("CENTER")
        btn.label:SetText(dur.label)

        if i == 1 then
            btn:SetPoint("LEFT", durLabel, "RIGHT", 6, 0)
        else
            btn:SetPoint("LEFT", durationBtns[i - 1], "RIGHT", 4, 0)
        end

        btn:SetScript("OnClick", function()
            durationIdx = i
            UpdateDurationButtons()
            AHSell:UpdateDeposit()
        end)
        btn:SetScript("OnEnter", function(self)
            if durationIdx ~= i then
                self.label:SetTextColor(unpack(ns.COLORS.tabHover))
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if durationIdx ~= i then
                self.label:SetTextColor(unpack(ns.COLORS.mutedText))
            end
        end)

        durationBtns[i] = btn
    end
    UpdateDurationButtons()

    -- Price row
    local priceLabel = postArea:CreateFontString(nil, "OVERLAY")
    priceLabel:SetFont(ns.FONT, 10, "")
    priceLabel:SetPoint("TOPLEFT", durLabel, "BOTTOMLEFT", 0, -8)
    priceLabel:SetText("Price:")
    priceLabel:SetTextColor(unpack(ns.COLORS.headerText))

    local function MakePriceBox(anchor, w, suffix)
        local box = CreateFrame("EditBox", nil, postArea, "BackdropTemplate")
        box:SetSize(w, 20)
        box:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
        box:SetBackdrop(BACKDROP_FLAT)
        box:SetBackdropColor(unpack(ns.COLORS.searchBg))
        box:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
        box:SetFont(ns.FONT, 10, "")
        box:SetTextColor(unpack(ns.COLORS.brightText))
        box:SetJustifyH("RIGHT")
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(7)
        box:SetText("0")
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        box:SetScript("OnTextChanged", function()
            AHSell:UpdateCachedPrice()
        end)

        local suf = box:CreateFontString(nil, "OVERLAY")
        suf:SetFont(ns.FONT, 10, "")
        suf:SetPoint("LEFT", box, "RIGHT", 2, 0)
        suf:SetText(suffix)
        suf:SetTextColor(unpack(ns.COLORS.mutedText))
        box._suffix = suf

        return box
    end

    priceGold = MakePriceBox(priceLabel, 50, "|cffffd700g|r")
    priceSilver = MakePriceBox(priceGold._suffix, 28, "|cffc7c7cfs|r")
    priceCopper = MakePriceBox(priceSilver._suffix, 28, "|cffeda55fc|r")

    -- Deposit row
    local depLabel = postArea:CreateFontString(nil, "OVERLAY")
    depLabel:SetFont(ns.FONT, 10, "")
    depLabel:SetPoint("TOPLEFT", priceLabel, "BOTTOMLEFT", 0, -8)
    depLabel:SetText("Deposit:")
    depLabel:SetTextColor(unpack(ns.COLORS.headerText))

    depositText = postArea:CreateFontString(nil, "OVERLAY")
    depositText:SetFont(ns.FONT, 10, "")
    depositText:SetPoint("LEFT", depLabel, "RIGHT", 6, 0)
    depositText:SetTextColor(unpack(ns.COLORS.mutedText))
    depositText:SetText("\226\128\148")

    -- Post button (full width, bottom of posting area)
    postBtn = ns.CreateButton(postArea, "Post Item", 0, 26)
    postBtn:SetPoint("BOTTOMLEFT", postArea, "BOTTOMLEFT", 8, 8)
    postBtn:SetPoint("BOTTOMRIGHT", postArea, "BOTTOMRIGHT", -8, 8)
    postBtn:Disable()
    postBtn:SetAlpha(0.4)

    -- OnClick: ZERO method calls / GetText() / API reads before PostItem.
    -- Only plain local reads + the PostItem call.  This keeps the hardware
    -- event execution context completely free of taint.  cachedUnitPrice
    -- and cachedQty are updated by OnTextChanged handlers (separate context).
    postBtn:SetScript("OnClick", function()
        local loc = sellItemLocation
        if not loc then return end

        local price = NormalizePrice(cachedUnitPrice)
        local qty = cachedQty
        local dur = DURATIONS[durationIdx].value
        local isCommodity = sellIsCommodity

        local result
        if isCommodity then
            result = C_AuctionHouse.PostCommodity(loc, dur, qty, price)
        else
            result = C_AuctionHouse.PostItem(loc, dur, qty, nil, price)
        end

        if result then
            AHSell:SetStatus("|cff66ff66Posting...|r")
            pendingPostArgs = {
                isCommodity = isCommodity,
                item = loc, duration = dur,
                quantity = qty, unitPrice = price, buyout = price,
            }
            C_Timer.After(5, function()
                if container and container.statusText
                   and container.statusText:GetText():find("Posting") then
                    AHSell:SetStatus("|cffff6666Post timed out — try again.|r")
                end
            end)
        else
            AHSell:SetStatus("|cffff6666Post failed — see chat.|r")
        end
    end)

    -- Status text (above post button)
    container.statusText = postArea:CreateFontString(nil, "OVERLAY")
    container.statusText:SetFont(ns.FONT, 9, "")
    container.statusText:SetPoint("BOTTOM", postBtn, "TOP", 0, 4)
    container.statusText:SetPoint("LEFT", postArea, "LEFT", 8, 0)
    container.statusText:SetPoint("RIGHT", postArea, "RIGHT", -8, 0)
    container.statusText:SetJustifyH("CENTER")
    container.statusText:SetTextColor(unpack(ns.COLORS.greenText))

    ----------------------------------------------------------------
    -- Divider (between posting area and bag area)
    ----------------------------------------------------------------
    local divider = leftPanel:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", postArea, "BOTTOMLEFT", 0, -6)
    divider:SetPoint("TOPRIGHT", postArea, "BOTTOMRIGHT", 0, -6)
    divider:SetColorTexture(70/255, 65/255, 55/255, 1)

    ----------------------------------------------------------------
    -- Bag area (scrollable, fills remaining space)
    ----------------------------------------------------------------
    bagScroll = CreateFrame("ScrollFrame", nil, leftPanel, "UIPanelScrollFrameTemplate")
    bagScroll:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    bagScroll:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -16, 4)

    bagContent = CreateFrame("Frame", nil, bagScroll)
    bagContent:SetWidth(1)
    bagContent:SetHeight(1)
    bagScroll:SetScrollChild(bagContent)

    bagScroll:SetScript("OnSizeChanged", function(self)
        bagContent:SetWidth(self:GetWidth())
    end)

    bagPlaceholder = bagScroll:CreateFontString(nil, "OVERLAY")
    bagPlaceholder:SetFont(ns.FONT, 10, "")
    bagPlaceholder:SetPoint("TOP", bagScroll, "TOP", 0, -20)
    bagPlaceholder:SetText("Items will appear here")
    bagPlaceholder:SetTextColor(unpack(ns.COLORS.mutedText))

    ----------------------------------------------------------------
    -- Right panel (current listings)
    ----------------------------------------------------------------
    rightPanel = CreateFrame("Frame", nil, container, "BackdropTemplate")
    rightPanel:SetWidth(360)
    rightPanel:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)

    -- Left panel fills remaining space
    leftPanel:SetPoint("RIGHT", rightPanel, "LEFT", -4, 0)
    rightPanel:SetBackdrop(BACKDROP_FLAT)
    rightPanel:SetBackdropColor(unpack(ns.COLORS.panelBg))
    rightPanel:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- Header
    listingHeader = rightPanel:CreateFontString(nil, "OVERLAY")
    listingHeader:SetFont(ns.FONT, 11, "")
    listingHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -8)
    listingHeader:SetText("Current Listings")
    listingHeader:SetTextColor(unpack(ns.COLORS.headerText))

    -- Column headers
    local colBuyout = rightPanel:CreateFontString(nil, "OVERLAY")
    colBuyout:SetFont(ns.FONT, 9, "")
    colBuyout:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -26)
    colBuyout:SetText("Buyout")
    colBuyout:SetTextColor(unpack(ns.COLORS.headerText))

    local colAvail = rightPanel:CreateFontString(nil, "OVERLAY")
    colAvail:SetFont(ns.FONT, 9, "")
    colAvail:SetPoint("RIGHT", rightPanel, "RIGHT", -90, 0)
    colAvail:SetPoint("TOP", rightPanel, "TOP", 0, -26)
    colAvail:SetText("Qty")
    colAvail:SetWidth(40)
    colAvail:SetJustifyH("RIGHT")
    colAvail:SetTextColor(unpack(ns.COLORS.headerText))

    local colQual = rightPanel:CreateFontString(nil, "OVERLAY")
    colQual:SetFont(ns.FONT, 9, "")
    colQual:SetPoint("RIGHT", rightPanel, "RIGHT", -50, 0)
    colQual:SetPoint("TOP", rightPanel, "TOP", 0, -26)
    colQual:SetText("Qual")
    colQual:SetWidth(35)
    colQual:SetJustifyH("CENTER")
    colQual:SetTextColor(unpack(ns.COLORS.headerText))

    local colOwned = rightPanel:CreateFontString(nil, "OVERLAY")
    colOwned:SetFont(ns.FONT, 9, "")
    colOwned:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", -6, -26)
    colOwned:SetWidth(40)
    colOwned:SetText("Owned?")
    colOwned:SetJustifyH("RIGHT")
    colOwned:SetTextColor(unpack(ns.COLORS.headerText))

    -- Separator under columns
    local listSep = rightPanel:CreateTexture(nil, "ARTWORK")
    listSep:SetHeight(1)
    listSep:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 4, -38)
    listSep:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", -4, -38)
    listSep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Listing scroll area
    listingScroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    listingScroll:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 4, -40)
    listingScroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -20, 4)

    listingContent = CreateFrame("Frame", nil, listingScroll)
    listingContent:SetWidth(1)
    listingContent:SetHeight(1)
    listingScroll:SetScrollChild(listingContent)

    listingScroll:SetScript("OnSizeChanged", function(self)
        listingContent:SetWidth(self:GetWidth())
    end)

    for i = 1, MAX_LIST_ROWS do
        listingRows[i] = CreateListingRow(listingContent, i)
    end

    -- Empty state text
    rightPanel.emptyText = rightPanel:CreateFontString(nil, "OVERLAY")
    rightPanel.emptyText:SetFont(ns.FONT, 11, "")
    rightPanel.emptyText:SetPoint("CENTER", rightPanel, "CENTER", 0, 0)
    rightPanel.emptyText:SetText("Select an item to see listings")
    rightPanel.emptyText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Hook post warning dialog once at init
    EnsurePostWarningHooked()
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function AHSell:Show()
    if not container then return end
    container:Show()
    self:ScanBags()
end

function AHSell:Hide()
    if container then container:Hide() end
end

function AHSell:IsShown()
    return container and container:IsShown()
end

--------------------------------------------------------------------
-- Bag scanning & icon grid
--------------------------------------------------------------------
local BAG_ICON_SIZE = 48
local BAG_ICON_GAP = 2
local CATEGORY_HEADER_HEIGHT = 18
local CATEGORY_GAP = 6

-- Category display order (classID → sort priority)
local CATEGORY_ORDER = {
    [0]  = 1,   -- Consumable
    [7]  = 2,   -- Tradeskill (Trade Goods)
    [9]  = 3,   -- Recipe
    [3]  = 4,   -- Gem
    [8]  = 5,   -- Item Enhancement
    [2]  = 6,   -- Weapon
    [4]  = 7,   -- Armor
    [17] = 8,   -- Profession
    [1]  = 9,   -- Container
    [16] = 10,  -- Glyph
    [18] = 11,  -- Housing
    [15] = 12,  -- Miscellaneous
    [12] = 13,  -- Quest (unlikely to be auctionable but just in case)
}

local function GetCategorySort(classID)
    return CATEGORY_ORDER[classID] or 99
end

-- Create or reuse an icon button from the pool
local function AcquireBagIcon(index)
    if bagIconPool[index] then return bagIconPool[index] end

    local btn = CreateFrame("Button", nil, bagContent)
    btn:SetSize(BAG_ICON_SIZE, BAG_ICON_SIZE)
    btn:RegisterForClicks("LeftButtonUp")

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetPoint("TOPLEFT", 1, -1)
    btn.icon:SetPoint("BOTTOMRIGHT", -1, 1)

    btn.border = btn:CreateTexture(nil, "OVERLAY")
    btn.border:SetAllPoints()
    btn.border:SetColorTexture(0, 0, 0, 0)

    -- Quality border (drawn as 4 edge textures for clean look)
    btn.qualBorder = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    btn.qualBorder:SetAllPoints()
    btn.qualBorder:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
    btn.qualBorder:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- Selection highlight border
    btn.selectBorder = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    btn.selectBorder:SetPoint("TOPLEFT", -1, 1)
    btn.selectBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    btn.selectBorder:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 2 })
    btn.selectBorder:SetBackdropBorderColor(unpack(ns.COLORS.accent))
    btn.selectBorder:Hide()

    btn.countText = btn:CreateFontString(nil, "OVERLAY")
    btn.countText:SetFont(ns.FONT, 9, "OUTLINE")
    btn.countText:SetPoint("BOTTOMRIGHT", -2, 2)
    btn.countText:SetJustifyH("RIGHT")
    btn.countText:SetTextColor(1, 1, 1)

    -- Crafting quality badge (top-left corner)
    btn.qualityBadge = btn:CreateTexture(nil, "OVERLAY", nil, 2)
    btn.qualityBadge:SetSize(14, 14)
    btn.qualityBadge:SetPoint("TOPLEFT", 1, -1)
    btn.qualityBadge:Hide()

    btn:SetScript("OnEnter", function(self)
        if self._itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self._itemLink)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    btn:SetScript("OnClick", function(self)
        if self._itemID then
            AHSell:SelectBagItem(self)
        end
    end)

    bagIconPool[index] = btn
    return btn
end

-- Create or reuse a category header
local function AcquireBagHeader(index)
    if bagHeaderPool[index] then return bagHeaderPool[index] end

    local fs = bagContent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(ns.FONT, 11, "")
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(160/255, 150/255, 130/255)

    bagHeaderPool[index] = fs
    return fs
end

function AHSell:ScanBags()
    if not bagContent then return end

    -- Gather auctionable items grouped by classID
    local categories = {}  -- classID → { items }

    for bag = 0, 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
            if C_Item.DoesItemExist(location) then
                -- IsSellItemValid is the single best check (handles bound, quest, etc.)
                local auctionable = C_AuctionHouse.IsSellItemValid(location, false)
                if auctionable then
                    local slotInfo = C_Container.GetContainerItemInfo(bag, slot)
                    if slotInfo then
                        local itemName, itemLink, quality, _, _, _, _, _, _, texture, _, classID = C_Item.GetItemInfo(slotInfo.itemID)
                        if itemName and classID then
                            if not categories[classID] then
                                categories[classID] = {}
                            end
                            table.insert(categories[classID], {
                                itemID = slotInfo.itemID,
                                itemName = itemName,
                                itemLink = itemLink or slotInfo.hyperlink,
                                quality = quality or 1,
                                texture = texture or slotInfo.iconFileID or 134400,
                                count = slotInfo.stackCount or 1,
                                bag = bag,
                                slot = slot,
                                classID = classID,
                                craftQuality = GetCraftingQuality(slotInfo.itemID),
                            })
                        end
                    end
                end
            end
        end
    end

    -- Sort categories by display order
    local sortedCats = {}
    for classID, items in pairs(categories) do
        table.insert(sortedCats, { classID = classID, items = items })
    end
    table.sort(sortedCats, function(a, b)
        return GetCategorySort(a.classID) < GetCategorySort(b.classID)
    end)

    -- Deduplicate items within each category (aggregate stacks by itemID)
    for _, cat in ipairs(sortedCats) do
        local merged = {}
        local seen = {}
        for _, item in ipairs(cat.items) do
            if seen[item.itemID] then
                seen[item.itemID].count = seen[item.itemID].count + item.count
            else
                local entry = {
                    itemID = item.itemID,
                    itemName = item.itemName,
                    itemLink = item.itemLink,
                    quality = item.quality,
                    texture = item.texture,
                    count = item.count,
                    bag = item.bag,
                    slot = item.slot,
                    classID = item.classID,
                    craftQuality = item.craftQuality,
                }
                seen[item.itemID] = entry
                table.insert(merged, entry)
            end
        end
        -- Sort by name within category
        table.sort(merged, function(a, b) return (a.itemName or "") < (b.itemName or "") end)
        cat.items = merged
    end

    self:LayoutBagGrid(sortedCats)
end

function AHSell:LayoutBagGrid(sortedCats)
    if not bagContent then return end

    -- Get available width for icon wrapping
    local panelWidth = bagScroll:GetWidth()
    if panelWidth < 10 then panelWidth = 200 end
    local iconsPerRow = math.floor((panelWidth + BAG_ICON_GAP) / (BAG_ICON_SIZE + BAG_ICON_GAP))
    if iconsPerRow < 1 then iconsPerRow = 1 end

    -- Hide all pooled elements first
    for _, btn in ipairs(bagIconPool) do btn:Hide() end
    for _, fs in ipairs(bagHeaderPool) do fs:Hide() end

    local iconIdx = 0
    local headerIdx = 0
    local yOffset = 0
    local totalItems = 0

    for _, cat in ipairs(sortedCats) do
        if #cat.items > 0 then
            totalItems = totalItems + #cat.items

            -- Category header
            headerIdx = headerIdx + 1
            local header = AcquireBagHeader(headerIdx)
            local catName = C_Item.GetItemClassInfo(cat.classID) or ("Class " .. cat.classID)
            header:SetText(catName)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", bagContent, "TOPLEFT", 4, -yOffset)
            header:Show()
            yOffset = yOffset + CATEGORY_HEADER_HEIGHT

            -- Icon grid
            for i, item in ipairs(cat.items) do
                iconIdx = iconIdx + 1
                local btn = AcquireBagIcon(iconIdx)

                btn.icon:SetTexture(item.texture)
                btn._itemID = item.itemID
                btn._itemLink = item.itemLink
                btn._itemName = item.itemName
                btn._bag = item.bag
                btn._slot = item.slot
                btn._quality = item.quality
                btn._count = item.count
                btn._texture = item.texture
                btn._craftQuality = item.craftQuality

                -- Crafting quality badge
                local atlas = GetQualityAtlas(item.craftQuality)
                if atlas then
                    btn.qualityBadge:SetAtlas(atlas)
                    btn.qualityBadge:Show()
                else
                    btn.qualityBadge:Hide()
                end

                -- Stack count
                if item.count > 1 then
                    btn.countText:SetText(item.count)
                    btn.countText:Show()
                else
                    btn.countText:Hide()
                end

                -- Quality border color
                local qColor = ITEM_QUALITY_COLORS[item.quality]
                if qColor then
                    btn.qualBorder:SetBackdropBorderColor(qColor.r, qColor.g, qColor.b, 0.8)
                else
                    btn.qualBorder:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
                end

                -- Selection highlight
                if selectedBagItemID and selectedBagItemID == item.itemID then
                    btn.selectBorder:Show()
                else
                    btn.selectBorder:Hide()
                end

                -- Position in grid
                local col = (i - 1) % iconsPerRow
                local row = math.floor((i - 1) / iconsPerRow)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", bagContent, "TOPLEFT",
                    4 + col * (BAG_ICON_SIZE + BAG_ICON_GAP),
                    -(yOffset + row * (BAG_ICON_SIZE + BAG_ICON_GAP)))
                btn:Show()
            end

            local numRows = math.ceil(#cat.items / iconsPerRow)
            yOffset = yOffset + numRows * (BAG_ICON_SIZE + BAG_ICON_GAP) + CATEGORY_GAP
        end
    end

    bagContent:SetHeight(math.max(1, yOffset))

    -- Show/hide placeholder
    if bagPlaceholder then
        if totalItems == 0 then
            bagPlaceholder:SetText("No auctionable items")
            bagPlaceholder:Show()
        else
            bagPlaceholder:Hide()
        end
    end
end

function AHSell:SelectBagItem(btn)
    if not btn or not btn._itemID then return end

    local itemID = btn._itemID
    selectedBagItemID = itemID

    -- Update selection highlight on all icons
    for _, poolBtn in ipairs(bagIconPool) do
        if poolBtn:IsShown() then
            if poolBtn._itemID == selectedBagItemID then
                poolBtn.selectBorder:Show()
            else
                poolBtn.selectBorder:Hide()
            end
        end
    end

    -- Build a fresh ItemLocation from the bag/slot
    local location = ItemLocation:CreateFromBagAndSlot(btn._bag, btn._slot)
    if not C_Item.DoesItemExist(location) then
        -- Item may have moved — find it by itemID
        location = self:FindItemInBags(itemID)
        if not location then
            self:SetStatus("Item not found in bags.")
            return
        end
    end

    -- Store sell state
    sellItemLocation = location
    sellItemID = itemID
    sellItemKey = C_AuctionHouse.GetItemKeyFromItem(location)

    -- Commodity status
    local commStatus = C_AuctionHouse.GetItemCommodityStatus(location)
    if commStatus == 0 then
        C_Item.RequestLoadItemDataByID(itemID)
        C_Timer.After(0.5, function()
            if sellItemID == itemID and sellItemLocation then
                local retry = C_AuctionHouse.GetItemCommodityStatus(sellItemLocation)
                sellIsCommodity = (retry == 2)
                self:LookupCurrentPrice()
            end
        end)
        sellIsCommodity = false
    else
        sellIsCommodity = (commStatus == 2)
    end

    -- Update posting area display
    if itemIcon then
        itemIcon:SetTexture(btn._texture or 134400)
        itemIcon:SetAlpha(1)
    end
    if dropTarget and dropTarget._selectLabel then
        dropTarget._selectLabel:Hide()
    end

    -- Item name with quality color
    local qualityColor = ITEM_QUALITY_COLORS[btn._quality]
    if qualityColor and itemNameText then
        itemNameText:SetText(qualityColor.hex .. (btn._itemName or "?") .. "|r")
    elseif itemNameText then
        itemNameText:SetText(btn._itemName or "?")
    end

    -- Crafting quality badge
    if itemQualityBadge then
        local atlas = GetQualityAtlas(btn._craftQuality)
        if atlas then
            itemQualityBadge:SetAtlas(atlas)
            itemQualityBadge:Show()
        else
            itemQualityBadge:Hide()
        end
    end

    -- Quantity: default 1, max = stack count
    local stackCount = btn._count or 1
    if sellIsCommodity then
        qtyBox:SetText(tostring(stackCount))
    else
        qtyBox:SetText("1")
    end

    -- Clear price (will auto-fill from listings search)
    if priceGold then priceGold:SetText("0") end
    if priceSilver then priceSilver:SetText("0") end
    if priceCopper then priceCopper:SetText("0") end

    -- Enable post button
    self:UpdatePostButton()

    -- Search for current AH price + update listings
    self:ClearListings()
    self:LookupCurrentPrice()
    self:UpdateDeposit()
    self:SetStatus("")
end

function AHSell:RefreshBags()
    if self:IsShown() then
        self:ScanBags()
    end
end

--------------------------------------------------------------------
-- Accept cursor item (drag & drop or click with item on cursor)
--------------------------------------------------------------------
function AHSell:AcceptCursorItem()
    local cursorItem = C_Cursor.GetCursorItem()
    if not cursorItem then
        local infoType = GetCursorInfo()
        if infoType ~= "item" then return end
    end

    local location
    if cursorItem then
        local bag, slot = cursorItem:GetBagAndSlot()
        ClearCursor()
        if bag and slot then
            location = ItemLocation:CreateFromBagAndSlot(bag, slot)
        end
    end
    if not location then
        local _, itemID = GetCursorInfo()
        ClearCursor()
        location = self:FindItemInBags(itemID)
        if not location then
            self:SetStatus("Item not found in bags.")
            return
        end
    end

    local itemID = C_Item.GetItemID(location)
    if not itemID then
        self:SetStatus("Could not identify item.")
        return
    end

    sellItemLocation = location
    sellItemID = itemID
    sellItemKey = C_AuctionHouse.GetItemKeyFromItem(location)

    -- Check commodity status (0=unknown, 1=item, 2=commodity)
    local status = C_AuctionHouse.GetItemCommodityStatus(location)

    if status == 0 then
        C_Item.RequestLoadItemDataByID(itemID)
        C_Timer.After(0.5, function()
            if sellItemID == itemID and sellItemLocation then
                local retryStatus = C_AuctionHouse.GetItemCommodityStatus(sellItemLocation)
                sellIsCommodity = (retryStatus == 2)
                self:LookupCurrentPrice()
            end
        end)
        sellIsCommodity = false
    else
        sellIsCommodity = (status == 2)
    end

    -- Update display
    local itemName, _, itemQuality, _, _, _, _, _, _, itemTexture, vendorPrice = C_Item.GetItemInfo(itemID)
    itemIcon:SetTexture(itemTexture or 134400)
    itemIcon:SetAlpha(1)
    if dropTarget._selectLabel then dropTarget._selectLabel:Hide() end

    local qualityColor = ITEM_QUALITY_COLORS[itemQuality]
    if qualityColor then
        itemNameText:SetText(qualityColor.hex .. (itemName or "?") .. "|r")
    else
        itemNameText:SetText(itemName or "?")
    end

    -- Crafting quality badge (drag-drop path)
    if itemQualityBadge then
        local cqAtlas = GetQualityAtlas(GetCraftingQuality(itemID))
        if cqAtlas then
            itemQualityBadge:SetAtlas(cqAtlas)
            itemQualityBadge:Show()
        else
            itemQualityBadge:Hide()
        end
    end

    -- Set quantity to stack count for commodities
    if sellIsCommodity then
        local count = C_Item.GetItemCount(itemID, false, false, false, false)
        qtyBox:SetText(tostring(count))
    else
        qtyBox:SetText("1")
    end

    -- Set vendor sell price as initial fallback
    if vendorPrice and vendorPrice > 0 then
        self:SetInputPrice(vendorPrice)
    end

    -- Enable post button
    self:UpdatePostButton()

    -- Clear old listings and search for current AH price
    self:ClearListings()
    self:LookupCurrentPrice()
    self:UpdateDeposit()
    self:SetStatus("")
end

function AHSell:FindItemInBags(targetItemID)
    for bag = 0, 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == targetItemID then
                return ItemLocation:CreateFromBagAndSlot(bag, slot)
            end
        end
    end
    return nil
end

--------------------------------------------------------------------
-- Get / Set price from input boxes (in copper)
--------------------------------------------------------------------
function AHSell:GetInputPrice()
    local g = tonumber(priceGold:GetText()) or 0
    local s = tonumber(priceSilver:GetText()) or 0
    local c = tonumber(priceCopper:GetText()) or 0
    return (g * 10000) + (s * 100) + c
end

function AHSell:SetInputPrice(copper)
    if not copper or copper <= 0 then return end
    copper = tonumber(tostring(copper)) or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    priceGold:SetText(tostring(g))
    priceSilver:SetText(tostring(s))
    priceCopper:SetText(tostring(c))
end

function AHSell:UpdateCachedPrice()
    local g = tonumber(priceGold and priceGold:GetText() or "0") or 0
    local s = tonumber(priceSilver and priceSilver:GetText() or "0") or 0
    local c = tonumber(priceCopper and priceCopper:GetText() or "0") or 0
    cachedUnitPrice = (g * 10000) + (s * 100) + c
end

--------------------------------------------------------------------
-- Deposit calculation
--------------------------------------------------------------------
function AHSell:UpdateDeposit()
    if not sellItemLocation then
        if depositText then depositText:SetText("\226\128\148") end
        return
    end

    local qty = tonumber(qtyBox:GetText()) or 1
    local duration = DURATIONS[durationIdx].value
    local deposit

    if sellIsCommodity then
        deposit = C_AuctionHouse.CalculateCommodityDeposit(sellItemID, duration, qty)
    else
        deposit = C_AuctionHouse.CalculateItemDeposit(sellItemLocation, duration, qty)
    end

    if deposit and deposit > 0 then
        depositText:SetText(ns.FormatGold(deposit))
    else
        depositText:SetText("\226\128\148")
    end
end

--------------------------------------------------------------------
-- Listings display
--------------------------------------------------------------------
function AHSell:ClearListings()
    for _, row in ipairs(listingRows) do
        row:Hide()
    end
    if listingContent then
        listingContent:SetHeight(1)
    end
    if listingHeader then
        listingHeader:SetText("Current Listings")
    end
    if rightPanel and rightPanel.emptyText then
        rightPanel.emptyText:SetText("Searching...")
        rightPanel.emptyText:Show()
    end
end

function AHSell:RefreshCommodityListings(itemID)
    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
    if not numResults or numResults == 0 then
        if rightPanel and rightPanel.emptyText then
            rightPanel.emptyText:SetText("No listings found")
            rightPanel.emptyText:Show()
        end
        return
    end

    if rightPanel and rightPanel.emptyText then
        rightPanel.emptyText:Hide()
    end

    local count = math.min(numResults, 50)
    listingContent:SetHeight(math.max(1, count * LIST_ROW_HEIGHT))

    local cheapestPrice = nil

    for i = 1, count do
        local row = listingRows[i]
        if not row then
            row = CreateListingRow(listingContent, i)
            listingRows[i] = row
        end

        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if info then
            row._unitPrice = info.unitPrice or 0
            row.priceText:SetText(ns.FormatGold(row._unitPrice))
            row.qtyText:SetText("x" .. (info.quantity or 0))

            if not cheapestPrice and row._unitPrice > 0 then
                cheapestPrice = row._unitPrice
            end

            if info.numOwnerItems and info.numOwnerItems > 0 then
                row.ownerTag:SetText("You")
                row.ownerTag:Show()
                row.bg:SetColorTexture(0.15, 0.25, 0.15, 0.3)
            else
                row.ownerTag:Hide()
                row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
            end

            -- Quality badge (commodity = all same tier from sellItemID)
            local cq = GetCraftingQuality(itemID)
            local qa = GetQualityAtlas(cq)
            if qa and row.qualityIcon then
                row.qualityIcon:SetAtlas(qa)
                row.qualityIcon:Show()
            elseif row.qualityIcon then
                row.qualityIcon:Hide()
            end

            row:Show()
        else
            row:Hide()
        end
    end

    for i = count + 1, #listingRows do
        listingRows[i]:Hide()
    end

    if listingHeader then
        listingHeader:SetText("Current Listings (" .. numResults .. ")")
    end

    return cheapestPrice
end

function AHSell:RefreshItemListings(itemKey)
    local numResults = C_AuctionHouse.GetNumItemSearchResults(itemKey)
    if not numResults or numResults == 0 then
        if rightPanel and rightPanel.emptyText then
            rightPanel.emptyText:SetText("No listings found")
            rightPanel.emptyText:Show()
        end
        return
    end

    if rightPanel and rightPanel.emptyText then
        rightPanel.emptyText:Hide()
    end

    local count = math.min(numResults, 50)
    listingContent:SetHeight(math.max(1, count * LIST_ROW_HEIGHT))

    local cheapestPrice = nil

    for i = 1, count do
        local row = listingRows[i]
        if not row then
            row = CreateListingRow(listingContent, i)
            listingRows[i] = row
        end

        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if info then
            row._unitPrice = info.buyoutAmount or info.bidAmount or 0
            row.priceText:SetText(ns.FormatGold(row._unitPrice))
            row.qtyText:SetText("x" .. (info.quantity or 1))

            if not cheapestPrice and row._unitPrice > 0 then
                cheapestPrice = row._unitPrice
            end

            if info.containsOwnerItem then
                row.ownerTag:SetText("You")
                row.ownerTag:Show()
                row.bg:SetColorTexture(0.15, 0.25, 0.15, 0.3)
            else
                row.ownerTag:Hide()
                row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
            end

            -- Quality badge (item search = same itemKey, same quality)
            local iq = GetCraftingQuality(itemKey and itemKey.itemID)
            local iqa = GetQualityAtlas(iq)
            if iqa and row.qualityIcon then
                row.qualityIcon:SetAtlas(iqa)
                row.qualityIcon:Show()
            elseif row.qualityIcon then
                row.qualityIcon:Hide()
            end

            row:Show()
        else
            row:Hide()
        end
    end

    for i = count + 1, #listingRows do
        listingRows[i]:Hide()
    end

    if listingHeader then
        listingHeader:SetText("Current Listings (" .. numResults .. ")")
    end

    return cheapestPrice
end

--------------------------------------------------------------------
-- Lookup current AH price for the selected item
--------------------------------------------------------------------
function AHSell:LookupCurrentPrice()
    if not sellItemID or not sellItemKey then return end
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then return end

    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(0.5, function()
            AHSell:LookupCurrentPrice()
        end)
        return
    end

    local sorts = {
        { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
        { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
    }
    C_AuctionHouse.SendSearchQuery(sellItemKey, sorts, sellIsCommodity)
end

function AHSell:OnCommoditySearchResults(itemID)
    if not sellItemID or sellItemID ~= itemID then return end
    if not sellIsCommodity then return end

    local cheapest = self:RefreshCommodityListings(itemID)
    if cheapest then
        self:SetInputPrice(cheapest)
        self:UpdateDeposit()
    end
end

function AHSell:OnItemSearchResults(itemKey)
    if not sellItemID or sellIsCommodity then return end
    if not sellItemKey then return end
    if itemKey and itemKey.itemID ~= sellItemKey.itemID then return end

    local cheapest = self:RefreshItemListings(sellItemKey)
    if cheapest then
        self:SetInputPrice(cheapest)
        self:UpdateDeposit()
    end
end

--------------------------------------------------------------------
-- Post warning hook
--------------------------------------------------------------------
EnsurePostWarningHooked = function()
    local dlg = StaticPopupDialogs["AUCTION_HOUSE_POST_WARNING"]
    if not dlg then
        StaticPopupDialogs["AUCTION_HOUSE_POST_WARNING"] = {
            text = "This item's price is significantly different from the current market price. Post anyway?",
            button1 = ACCEPT,
            button2 = CANCEL,
            showAlert = true,
            hideOnEscape = 1,
            timeout = 0,
            whileDead = 1,
        }
        dlg = StaticPopupDialogs["AUCTION_HOUSE_POST_WARNING"]
    end

    dlg.OnAccept = function()
        if pendingPostArgs then
            if pendingPostArgs.isCommodity then
                C_AuctionHouse.ConfirmPostCommodity(
                    pendingPostArgs.item, pendingPostArgs.duration,
                    pendingPostArgs.quantity, pendingPostArgs.unitPrice)
            else
                C_AuctionHouse.ConfirmPostItem(
                    pendingPostArgs.item, pendingPostArgs.duration,
                    pendingPostArgs.quantity, pendingPostArgs.buyout, pendingPostArgs.buyout)
            end
            pendingPostArgs = nil
        end
    end

    dlg.OnCancel = function()
        pendingPostArgs = nil
    end
end

--------------------------------------------------------------------
-- Events
--------------------------------------------------------------------
function AHSell:OnAuctionCreated()
    self:SetStatus("|cff66ff66Auction posted!|r")
    pendingPostArgs = nil
    C_Timer.After(1.5, function()
        if AHSell:IsShown() then
            AHSell:ClearForm()
        end
    end)
end

function AHSell:ClearForm()
    sellItemLocation = nil
    sellItemID = nil
    sellItemKey = nil
    sellIsCommodity = false
    selectedBagItemID = nil

    if itemIcon then
        itemIcon:SetTexture(134400)
        itemIcon:SetAlpha(0.3)
    end
    if dropTarget and dropTarget._selectLabel then
        dropTarget._selectLabel:Show()
    end
    if itemNameText then itemNameText:SetText("") end
    if itemQualityBadge then itemQualityBadge:Hide() end
    if qtyBox then qtyBox:SetText("1") end
    if priceGold then priceGold:SetText("0") end
    if priceSilver then priceSilver:SetText("0") end
    if priceCopper then priceCopper:SetText("0") end
    if depositText then depositText:SetText("\226\128\148") end
    self:UpdatePostButton()
    self:ClearListings()
    if rightPanel and rightPanel.emptyText then
        rightPanel.emptyText:SetText("Select an item to see listings")
        rightPanel.emptyText:Show()
    end
    -- Clear bag selection highlights
    for _, poolBtn in ipairs(bagIconPool) do
        if poolBtn.selectBorder then poolBtn.selectBorder:Hide() end
    end
    self:SetStatus("")
    -- Refresh bag grid (item counts changed after posting)
    self:ScanBags()
end

function AHSell:SetStatus(text)
    if container and container.statusText then
        container.statusText:SetText(text or "")
    end
end
