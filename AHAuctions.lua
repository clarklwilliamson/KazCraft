local addonName, ns = ...

local AHAuctions = {}
ns.AHAuctions = AHAuctions

local ROW_HEIGHT = 28
local MAX_ROWS = 14

-- State
local container
local subTabBar
local activeSubTab = "auctions" -- "auctions" or "bids"
local scrollFrame, scrollContent
local rows = {}
local cancelBtn
local selectedAuctionID = nil
local selectedRowIndex = nil

-- Time left band labels
local TIME_LEFT_LABELS = {
    [Enum.AuctionHouseTimeLeftBand.Short]    = "|cffff6666< 30m|r",
    [Enum.AuctionHouseTimeLeftBand.Medium]   = "|cffffff002h|r",
    [Enum.AuctionHouseTimeLeftBand.Long]     = "|cff66ff6612h|r",
    [Enum.AuctionHouseTimeLeftBand.VeryLong] = "|cff66ff6648h|r",
}

-- Auction status labels
local STATUS_LABELS = {
    [0] = "Active",   -- Enum.AuctionStatus.Active
    [1] = "|cff66ff66Sold|r",
}

--------------------------------------------------------------------
-- Row factory
--------------------------------------------------------------------
local function CreateAuctionRow(parent, index)
    local row = ns.CreateRow(parent, index, ROW_HEIGHT)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 6, 0)

    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -200, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    row.qtyText = row:CreateFontString(nil, "OVERLAY")
    row.qtyText:SetFont(ns.FONT, 10, "")
    row.qtyText:SetPoint("RIGHT", row, "RIGHT", -145, 0)
    row.qtyText:SetWidth(40)
    row.qtyText:SetJustifyH("RIGHT")
    row.qtyText:SetTextColor(unpack(ns.COLORS.mutedText))

    row.priceText = row:CreateFontString(nil, "OVERLAY")
    row.priceText:SetFont(ns.FONT, 10, "")
    row.priceText:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    row.priceText:SetWidth(80)
    row.priceText:SetJustifyH("RIGHT")
    row.priceText:SetTextColor(unpack(ns.COLORS.goldText))

    row.statusText = row:CreateFontString(nil, "OVERLAY")
    row.statusText:SetFont(ns.FONT, 10, "")
    row.statusText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.statusText:SetWidth(50)
    row.statusText:SetJustifyH("RIGHT")
    row.statusText:SetTextColor(unpack(ns.COLORS.mutedText))

    row:SetScript("OnClick", function(self)
        if self._auctionID then
            selectedAuctionID = self._auctionID
            selectedRowIndex = index
            AHAuctions:HighlightRow(index)
        end
    end)

    -- Override OnEnter/OnLeave for tooltip
    row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        self.leftAccent:Show()
        if self._itemKey then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemKey(self._itemKey.itemID,
                self._itemKey.itemLevel or 0,
                self._itemKey.itemSuffix or 0)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        -- Keep highlight if this row is selected
        if selectedRowIndex and selectedRowIndex == index then
            self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
            self.leftAccent:Show()
        else
            self.bg:SetColorTexture(1, 1, 1, self._defaultBgAlpha)
            self.leftAccent:Hide()
        end
        GameTooltip:Hide()
    end)

    return row
end

--------------------------------------------------------------------
-- Build UI
--------------------------------------------------------------------
function AHAuctions:Init(contentFrame)
    if container then return end
    container = CreateFrame("Frame", nil, contentFrame)
    container:SetAllPoints()
    container:Hide()

    -- Sub-tab bar
    local subTabs = {
        { key = "auctions", label = "My Auctions" },
        { key = "bids",     label = "My Bids" },
    }
    subTabBar = ns.CreateTabBar(container, subTabs, function(key)
        activeSubTab = key
        selectedAuctionID = nil
        selectedRowIndex = nil
        AHAuctions:Refresh()
    end)
    subTabBar:ClearAllPoints()
    subTabBar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    subTabBar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)

    -- Column headers
    local colHeader = CreateFrame("Frame", nil, container)
    colHeader:SetHeight(18)
    colHeader:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -30)
    colHeader:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -30)

    local function ColLabel(text, point, x, w)
        local fs = colHeader:CreateFontString(nil, "OVERLAY")
        fs:SetFont(ns.FONT, 9, "")
        fs:SetTextColor(unpack(ns.COLORS.headerText))
        fs:SetText(text)
        if point == "LEFT" then
            fs:SetPoint("LEFT", colHeader, "LEFT", x, 0)
        else
            fs:SetPoint("RIGHT", colHeader, "RIGHT", x, 0)
        end
        if w then fs:SetWidth(w) end
        fs:SetJustifyH(point)
    end

    ColLabel("Item", "LEFT", 34)
    ColLabel("Qty", "RIGHT", -145, 40)
    ColLabel("Price", "RIGHT", -60, 80)
    ColLabel("Status", "RIGHT", -6, 50)

    -- Scroll area
    scrollFrame = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -48)
    scrollFrame:SetPoint("TOPRIGHT", container, "TOPRIGHT", -16, -48)
    scrollFrame:SetPoint("BOTTOM", container, "BOTTOM", 0, 36)

    scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetWidth(1)
    scrollContent:SetHeight(1)
    scrollFrame:SetScrollChild(scrollContent)

    scrollFrame:SetScript("OnSizeChanged", function(self)
        scrollContent:SetWidth(self:GetWidth())
    end)

    for i = 1, MAX_ROWS do
        rows[i] = CreateAuctionRow(scrollContent, i)
    end

    -- Footer
    local footer = CreateFrame("Frame", nil, container, "BackdropTemplate")
    footer:SetHeight(32)
    footer:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    footer:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    footer:SetBackdropColor(unpack(ns.COLORS.footerBg))

    container.countText = footer:CreateFontString(nil, "OVERLAY")
    container.countText:SetFont(ns.FONT, 10, "")
    container.countText:SetPoint("LEFT", footer, "LEFT", 8, 0)
    container.countText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Cancel button (auctions only)
    cancelBtn = ns.CreateButton(footer, "Cancel Auction", 110, 22)
    cancelBtn:SetPoint("RIGHT", footer, "RIGHT", -6, 0)
    cancelBtn:SetScript("OnClick", function()
        AHAuctions:CancelSelected()
    end)

    -- Refresh button
    local refreshBtn = ns.CreateButton(footer, "Refresh", 60, 22)
    refreshBtn:SetPoint("RIGHT", cancelBtn, "LEFT", -4, 0)
    refreshBtn:SetScript("OnClick", function()
        AHAuctions:QueryData()
    end)
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function AHAuctions:Show()
    if not container then return end
    container:Show()
    self:QueryData()
end

function AHAuctions:Hide()
    if container then container:Hide() end
end

function AHAuctions:IsShown()
    return container and container:IsShown()
end

--------------------------------------------------------------------
-- Query server for data
--------------------------------------------------------------------
function AHAuctions:QueryData()
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then return end

    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

    if activeSubTab == "auctions" then
        C_AuctionHouse.QueryOwnedAuctions(sorts)
    else
        C_AuctionHouse.QueryBids(sorts, {})
    end
end

--------------------------------------------------------------------
-- Refresh display
--------------------------------------------------------------------
function AHAuctions:Refresh()
    if not scrollContent then return end

    if activeSubTab == "auctions" then
        self:RefreshAuctions()
        cancelBtn:Show()
    else
        self:RefreshBids()
        cancelBtn:Hide()
    end
end

function AHAuctions:RefreshAuctions()
    local ownedAuctions = C_AuctionHouse.GetOwnedAuctions()
    local count = #ownedAuctions

    scrollContent:SetHeight(math.max(1, count * ROW_HEIGHT))

    for i = 1, math.max(count, #rows) do
        local row = rows[i]
        if not row and i <= count then
            row = CreateAuctionRow(scrollContent, i)
            rows[i] = row
        end
        if row then
            if i <= count then
                local auction = ownedAuctions[i]
                local keyInfo = C_AuctionHouse.GetItemKeyInfo(auction.itemKey)

                if keyInfo then
                    row.icon:SetTexture(keyInfo.iconFileID or 134400)
                    local qualityColor = ITEM_QUALITY_COLORS[keyInfo.quality]
                    if qualityColor then
                        row.nameText:SetText(qualityColor.hex .. (keyInfo.itemName or "?") .. "|r")
                    else
                        row.nameText:SetText(keyInfo.itemName or "?")
                    end
                else
                    row.icon:SetTexture(134400)
                    row.nameText:SetText("Item " .. auction.itemKey.itemID)
                end

                row.qtyText:SetText("x" .. (auction.quantity or 1))

                local price = auction.buyoutAmount or auction.bidAmount or 0
                row.priceText:SetText(ns.FormatGold(price))

                local statusLabel = STATUS_LABELS[auction.status] or "Active"
                if auction.status == 0 and auction.timeLeft then
                    statusLabel = TIME_LEFT_LABELS[auction.timeLeft] or "Active"
                end
                row.statusText:SetText(statusLabel)

                row._auctionID = auction.auctionID
                row._itemKey = auction.itemKey
                row:Show()
            else
                row._auctionID = nil
                row._itemKey = nil
                row:Hide()
            end
        end
    end

    if container.countText then
        container.countText:SetText(count .. " auction" .. (count ~= 1 and "s" or ""))
    end

    -- Re-highlight previously selected auction (if it still exists)
    self:RestoreSelection()
end

function AHAuctions:RefreshBids()
    local bids = C_AuctionHouse.GetBids()
    local count = #bids

    scrollContent:SetHeight(math.max(1, count * ROW_HEIGHT))

    for i = 1, math.max(count, #rows) do
        local row = rows[i]
        if not row and i <= count then
            row = CreateAuctionRow(scrollContent, i)
            rows[i] = row
        end
        if row then
            if i <= count then
                local bid = bids[i]
                local keyInfo = C_AuctionHouse.GetItemKeyInfo(bid.itemKey)

                if keyInfo then
                    row.icon:SetTexture(keyInfo.iconFileID or 134400)
                    local qualityColor = ITEM_QUALITY_COLORS[keyInfo.quality]
                    if qualityColor then
                        row.nameText:SetText(qualityColor.hex .. (keyInfo.itemName or "?") .. "|r")
                    else
                        row.nameText:SetText(keyInfo.itemName or "?")
                    end
                else
                    row.icon:SetTexture(134400)
                    row.nameText:SetText("Item " .. bid.itemKey.itemID)
                end

                row.qtyText:SetText("")

                local price = bid.bidAmount or bid.minBid or 0
                row.priceText:SetText(ns.FormatGold(price))

                row.statusText:SetText(TIME_LEFT_LABELS[bid.timeLeft] or "?")

                row._auctionID = bid.auctionID
                row._itemKey = bid.itemKey
                row:Show()
            else
                row._auctionID = nil
                row._itemKey = nil
                row:Hide()
            end
        end
    end

    if container.countText then
        container.countText:SetText(count .. " bid" .. (count ~= 1 and "s" or ""))
    end

    -- Re-highlight previously selected bid (if it still exists)
    self:RestoreSelection()
end

--------------------------------------------------------------------
-- Row highlight
--------------------------------------------------------------------
function AHAuctions:HighlightRow(index)
    for i, row in ipairs(rows) do
        if row:IsShown() then
            if i == index then
                row.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
                row.leftAccent:Show()
            else
                row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
                row.leftAccent:Hide()
            end
        end
    end
end

-- After a refresh, find the previously selected auctionID in the new
-- row list and re-apply the highlight.  Clears selection if it no
-- longer exists (e.g. after cancel).
function AHAuctions:RestoreSelection()
    if not selectedAuctionID then return end
    for i, row in ipairs(rows) do
        if row:IsShown() and row._auctionID == selectedAuctionID then
            selectedRowIndex = i
            self:HighlightRow(i)
            return
        end
    end
    -- Auction no longer in list — clear selection
    selectedAuctionID = nil
    selectedRowIndex = nil
end

--------------------------------------------------------------------
-- Cancel auction
--------------------------------------------------------------------
function AHAuctions:CancelSelected()
    if not selectedAuctionID then
        print("|cffc8aa64KazCraft:|r Select an auction first.")
        return
    end
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then return end

    if not C_AuctionHouse.CanCancelAuction(selectedAuctionID) then
        print("|cffc8aa64KazCraft:|r Cannot cancel this auction.")
        return
    end

    C_AuctionHouse.CancelAuction(selectedAuctionID)
    -- Don't clear selection here — RestoreSelection will clear it
    -- after refresh if the auction no longer exists
end

--------------------------------------------------------------------
-- Event handlers (called from Core.lua)
--------------------------------------------------------------------
function AHAuctions:OnOwnedAuctionsUpdated()
    if self:IsShown() and activeSubTab == "auctions" then
        self:RefreshAuctions()
    end
end

function AHAuctions:OnBidsUpdated()
    if self:IsShown() and activeSubTab == "bids" then
        self:RefreshBids()
    end
end

function AHAuctions:OnAuctionCanceled()
    if self:IsShown() then
        self:QueryData()
    end
end
