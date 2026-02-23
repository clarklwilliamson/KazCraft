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

-- State
local container
local leftPanel, rightPanel
local dropTarget
local itemIcon, itemNameText, itemTypeText
local qtyBox, priceGold, priceSilver, priceCopper
local durationIdx = 2  -- default 24h
local durationBtn
local depositText
local postBtn
local listingRows = {}
local listingContent, listingScroll
local listingHeader
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

    row.priceText = row:CreateFontString(nil, "OVERLAY")
    row.priceText:SetFont(ns.FONT, 10, "")
    row.priceText:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.priceText:SetWidth(120)
    row.priceText:SetJustifyH("LEFT")
    row.priceText:SetTextColor(unpack(ns.COLORS.goldText))

    row.qtyText = row:CreateFontString(nil, "OVERLAY")
    row.qtyText:SetFont(ns.FONT, 10, "")
    row.qtyText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.qtyText:SetWidth(60)
    row.qtyText:SetJustifyH("RIGHT")
    row.qtyText:SetTextColor(unpack(ns.COLORS.mutedText))

    row.ownerTag = row:CreateFontString(nil, "OVERLAY")
    row.ownerTag:SetFont(ns.FONT, 9, "")
    row.ownerTag:SetPoint("RIGHT", row.qtyText, "LEFT", -4, 0)
    row.ownerTag:SetTextColor(unpack(ns.COLORS.greenText))
    row.ownerTag:Hide()

    row._unitPrice = 0

    row:SetScript("OnClick", function(self)
        if self._unitPrice and self._unitPrice > 0 then
            local undercut = math.max(1, self._unitPrice - 1)
            AHSell:SetInputPrice(undercut)
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

    -- Left panel (post controls) — ~35% width
    leftPanel = CreateFrame("Frame", nil, container)
    leftPanel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    leftPanel:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    leftPanel:SetPoint("RIGHT", container, "LEFT", 250, 0)

    -- Right panel (listings) — ~65% width, with gap
    rightPanel = CreateFrame("Frame", nil, container, "BackdropTemplate")
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 8, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    rightPanel:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    rightPanel:SetBackdropColor(unpack(ns.COLORS.panelBg))
    rightPanel:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- === LEFT PANEL: Post controls ===

    -- Drop target area
    dropTarget = CreateFrame("Button", nil, leftPanel)
    dropTarget:SetSize(48, 48)
    dropTarget:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 10, -10)

    local dropBg = dropTarget:CreateTexture(nil, "BACKGROUND")
    dropBg:SetAllPoints()
    dropBg:SetColorTexture(unpack(ns.COLORS.panelBg))

    local dropBorder = CreateFrame("Frame", nil, dropTarget, "BackdropTemplate")
    dropBorder:SetAllPoints()
    dropBorder:SetBackdrop({
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    dropBorder:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    itemIcon = dropTarget:CreateTexture(nil, "ARTWORK")
    itemIcon:SetAllPoints()
    itemIcon:SetTexture(134400)
    itemIcon:SetAlpha(0.3)

    dropTarget:SetScript("OnEnter", function(self)
        if sellItemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(sellItemID)
            GameTooltip:Show()
        end
    end)
    dropTarget:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local dropLabel = dropTarget:CreateFontString(nil, "OVERLAY")
    dropLabel:SetFont(ns.FONT, 9, "")
    dropLabel:SetPoint("CENTER")
    dropLabel:SetText("Drop\nItem")
    dropLabel:SetTextColor(unpack(ns.COLORS.mutedText))
    dropLabel:SetJustifyH("CENTER")
    dropTarget._dropLabel = dropLabel

    dropTarget:SetScript("OnClick", function() AHSell:AcceptCursorItem() end)
    dropTarget:SetScript("OnReceiveDrag", function() AHSell:AcceptCursorItem() end)
    dropTarget:RegisterForClicks("LeftButtonUp")

    -- Item name + type
    itemNameText = leftPanel:CreateFontString(nil, "OVERLAY")
    itemNameText:SetFont(ns.FONT, 13, "")
    itemNameText:SetPoint("TOPLEFT", dropTarget, "TOPRIGHT", 8, -2)
    itemNameText:SetPoint("RIGHT", leftPanel, "RIGHT", -4, 0)
    itemNameText:SetJustifyH("LEFT")
    itemNameText:SetWordWrap(false)
    itemNameText:SetTextColor(unpack(ns.COLORS.brightText))
    itemNameText:SetText("No item selected")

    itemTypeText = leftPanel:CreateFontString(nil, "OVERLAY")
    itemTypeText:SetFont(ns.FONT, 10, "")
    itemTypeText:SetPoint("TOPLEFT", itemNameText, "BOTTOMLEFT", 0, -2)
    itemTypeText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Separator
    local sep1 = leftPanel:CreateTexture(nil, "ARTWORK")
    sep1:SetHeight(1)
    sep1:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 6, -68)
    sep1:SetPoint("TOPRIGHT", leftPanel, "TOPRIGHT", -6, -68)
    sep1:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Quantity
    local qtyLabel = leftPanel:CreateFontString(nil, "OVERLAY")
    qtyLabel:SetFont(ns.FONT, 10, "")
    qtyLabel:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 10, -78)
    qtyLabel:SetText("Quantity:")
    qtyLabel:SetTextColor(unpack(ns.COLORS.headerText))

    qtyBox = CreateFrame("EditBox", nil, leftPanel, "BackdropTemplate")
    qtyBox:SetSize(60, 22)
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 6, 0)
    qtyBox:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    qtyBox:SetBackdropColor(unpack(ns.COLORS.searchBg))
    qtyBox:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    qtyBox:SetFont(ns.FONT, 11, "")
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

    -- Duration
    local durLabel = leftPanel:CreateFontString(nil, "OVERLAY")
    durLabel:SetFont(ns.FONT, 10, "")
    durLabel:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", 0, -12)
    durLabel:SetText("Duration:")
    durLabel:SetTextColor(unpack(ns.COLORS.headerText))

    durationBtn = ns.CreateButton(leftPanel, DURATIONS[durationIdx].label, 48, 22)
    durationBtn:SetPoint("LEFT", durLabel, "RIGHT", 6, 0)
    durationBtn:SetScript("OnClick", function()
        durationIdx = (durationIdx % #DURATIONS) + 1
        durationBtn.label:SetText(DURATIONS[durationIdx].label)
        AHSell:UpdateDeposit()
    end)

    -- Price per unit
    local priceLabel = leftPanel:CreateFontString(nil, "OVERLAY")
    priceLabel:SetFont(ns.FONT, 10, "")
    priceLabel:SetPoint("TOPLEFT", durLabel, "BOTTOMLEFT", 0, -12)
    priceLabel:SetText("Price per unit:")
    priceLabel:SetTextColor(unpack(ns.COLORS.headerText))

    local function MakePriceBox(parent, anchor, w, suffix)
        local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        box:SetSize(w, 22)
        box:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
        box:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        box:SetBackdropColor(unpack(ns.COLORS.searchBg))
        box:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
        box:SetFont(ns.FONT, 11, "")
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
            AHSell:UpdateDeposit()
        end)

        local suf = box:CreateFontString(nil, "OVERLAY")
        suf:SetFont(ns.FONT, 10, "")
        suf:SetPoint("LEFT", box, "RIGHT", 2, 0)
        suf:SetText(suffix)
        suf:SetTextColor(unpack(ns.COLORS.mutedText))
        box._suffix = suf

        return box
    end

    priceGold = MakePriceBox(leftPanel, priceLabel, 60, "|cffffd700g|r")
    priceSilver = MakePriceBox(leftPanel, priceGold._suffix, 32, "|cffc7c7cfs|r")
    priceCopper = MakePriceBox(leftPanel, priceSilver._suffix, 32, "|cffeda55fc|r")

    -- Deposit
    local depLabel = leftPanel:CreateFontString(nil, "OVERLAY")
    depLabel:SetFont(ns.FONT, 10, "")
    depLabel:SetPoint("TOPLEFT", priceLabel, "BOTTOMLEFT", 0, -12)
    depLabel:SetText("Deposit:")
    depLabel:SetTextColor(unpack(ns.COLORS.headerText))

    depositText = leftPanel:CreateFontString(nil, "OVERLAY")
    depositText:SetFont(ns.FONT, 11, "")
    depositText:SetPoint("LEFT", depLabel, "RIGHT", 6, 0)
    depositText:SetTextColor(unpack(ns.COLORS.mutedText))
    depositText:SetText("\226\128\148")

    -- Post button (VP flat style)
    postBtn = ns.CreateButton(leftPanel, "Post Item", 120, 28)
    postBtn:SetPoint("BOTTOM", leftPanel, "BOTTOM", 0, 14)
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

        -- Do NOT call AuctionHouseFrame:SetScale() here.
        -- SetScale(1) on Blizzard's complex AH frame triggers layout/scripts
        -- that may consume the hardware event token before PostItem gets it.
        -- The AH session is open on the server regardless of client-side scale.
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

    -- Status text
    container.statusText = leftPanel:CreateFontString(nil, "OVERLAY")
    container.statusText:SetFont(ns.FONT, 10, "")
    container.statusText:SetPoint("BOTTOM", postBtn, "TOP", 0, 6)
    container.statusText:SetPoint("LEFT", leftPanel, "LEFT", 10, 0)
    container.statusText:SetPoint("RIGHT", leftPanel, "RIGHT", -4, 0)
    container.statusText:SetJustifyH("CENTER")
    container.statusText:SetTextColor(unpack(ns.COLORS.greenText))

    -- === RIGHT PANEL: Current listings ===

    listingHeader = rightPanel:CreateFontString(nil, "OVERLAY")
    listingHeader:SetFont(ns.FONT, 10, "")
    listingHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -6)
    listingHeader:SetText("Current Listings")
    listingHeader:SetTextColor(unpack(ns.COLORS.headerText))

    -- Column labels
    local colPrice = rightPanel:CreateFontString(nil, "OVERLAY")
    colPrice:SetFont(ns.FONT, 9, "")
    colPrice:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -22)
    colPrice:SetText("Price")
    colPrice:SetTextColor(unpack(ns.COLORS.headerText))

    local colQty = rightPanel:CreateFontString(nil, "OVERLAY")
    colQty:SetFont(ns.FONT, 9, "")
    colQty:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", -8, -22)
    colQty:SetText("Available")
    colQty:SetJustifyH("RIGHT")
    colQty:SetTextColor(unpack(ns.COLORS.headerText))

    -- Separator under header
    local listSep = rightPanel:CreateTexture(nil, "ARTWORK")
    listSep:SetHeight(1)
    listSep:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 4, -34)
    listSep:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", -4, -34)
    listSep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Scrollable listing area
    listingScroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    listingScroll:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 6, -36)
    listingScroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -18, 1)

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
    rightPanel.emptyText:SetFont(ns.FONT, 10, "")
    rightPanel.emptyText:SetPoint("CENTER", rightPanel, "CENTER", 0, 0)
    rightPanel.emptyText:SetText("Drop an item to see listings")
    rightPanel.emptyText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Hook post warning dialog once at init (NOT in OnClick — avoids
    -- touching Blizzard globals inside the hardware event chain)
    EnsurePostWarningHooked()
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function AHSell:Show()
    if not container then return end
    container:Show()
end

function AHSell:Hide()
    if container then container:Hide() end
end

function AHSell:IsShown()
    return container and container:IsShown()
end


--------------------------------------------------------------------
-- Accept cursor item (drag & drop or click with item on cursor)
--------------------------------------------------------------------
function AHSell:AcceptCursorItem()
    -- Get cursor item, then create a FRESH ItemLocation from its bag/slot.
    -- C_Cursor's returned ItemLocation may carry internal metadata that
    -- taints HasRestrictions calls.  Extracting bag+slot and rebuilding
    -- guarantees a clean, untainted table — same pattern TSM/Auctionator use.
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
                if itemTypeText then
                    itemTypeText:SetText(sellIsCommodity and "Commodity" or "Item")
                end
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
    dropTarget._dropLabel:Hide()

    local qualityColor = ITEM_QUALITY_COLORS[itemQuality]
    if qualityColor then
        itemNameText:SetText(qualityColor.hex .. (itemName or "?") .. "|r")
    else
        itemNameText:SetText(itemName or "?")
    end

    itemTypeText:SetText(sellIsCommodity and "Commodity" or "Item")

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
-- Get price from input boxes (in copper)
--------------------------------------------------------------------
function AHSell:GetInputPrice()
    -- tonumber() strips secret taint from values that may have
    -- originated from C_AuctionHouse API returns
    local g = tonumber(priceGold:GetText()) or 0
    local s = tonumber(priceSilver:GetText()) or 0
    local c = tonumber(priceCopper:GetText()) or 0
    return (g * 10000) + (s * 100) + c
end

function AHSell:SetInputPrice(copper)
    if not copper or copper <= 0 then return end
    -- tonumber + tostring to strip any secret taint from AH price data
    copper = tonumber(tostring(copper)) or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    priceGold:SetText(tostring(g))
    priceSilver:SetText(tostring(s))
    priceCopper:SetText(tostring(c))
    -- OnTextChanged fires from SetText, which calls UpdateCachedPrice
end

-- Recalculate cachedUnitPrice from the EditBox values.
-- Called by OnTextChanged (outside the hardware-event context) so any
-- taint from GetText() stays isolated from the PostItem OnClick path.
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

    local count = math.min(numResults, 50) -- cap at 50 display rows
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

            -- Highlight your own listings
            if info.numOwnerItems and info.numOwnerItems > 0 then
                row.ownerTag:SetText("you")
                row.ownerTag:Show()
                row.bg:SetColorTexture(0.15, 0.25, 0.15, 0.3)
            else
                row.ownerTag:Hide()
                row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
            end

            row:Show()
        else
            row:Hide()
        end
    end

    -- Hide excess rows
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

            -- Highlight your own listings
            if info.containsOwnerItem then
                row.ownerTag:SetText("you")
                row.ownerTag:Show()
                row.bg:SetColorTexture(0.15, 0.25, 0.15, 0.3)
            else
                row.ownerTag:Hide()
                row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
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
        -- Auto-undercut cheapest by 1 copper
        self:SetInputPrice(cheapest)
        self:UpdateDeposit()
    end
end

function AHSell:OnItemSearchResults(itemKey)
    if not sellItemID or sellIsCommodity then return end
    if not sellItemKey then return end
    -- Filter: only process results for our sell item
    if itemKey and itemKey.itemID ~= sellItemKey.itemID then return end

    local cheapest = self:RefreshItemListings(sellItemKey)
    if cheapest then
        -- Auto-undercut cheapest by 1 copper
        self:SetInputPrice(cheapest)
        self:UpdateDeposit()
    end
end

--------------------------------------------------------------------
-- Post auction
--------------------------------------------------------------------

-- Hook Blizzard's post warning dialog so our cached args are used
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

-- Posting logic is now inline in the Post button's OnClick handler above.
-- This stub exists so external callers don't error.
function AHSell:PostItem()
end

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

    if itemIcon then
        itemIcon:SetTexture(134400)
        itemIcon:SetAlpha(0.3)
    end
    if dropTarget and dropTarget._dropLabel then
        dropTarget._dropLabel:Show()
    end
    if itemNameText then itemNameText:SetText("No item selected") end
    if itemTypeText then itemTypeText:SetText("") end
    if qtyBox then qtyBox:SetText("1") end
    if priceGold then priceGold:SetText("0") end
    if priceSilver then priceSilver:SetText("0") end
    if priceCopper then priceCopper:SetText("0") end
    if depositText then depositText:SetText("\226\128\148") end
    self:ClearListings()
    if rightPanel and rightPanel.emptyText then
        rightPanel.emptyText:SetText("Drop an item to see listings")
        rightPanel.emptyText:Show()
    end
    self:SetStatus("")
end

function AHSell:SetStatus(text)
    if container and container.statusText then
        container.statusText:SetText(text or "")
    end
end
