local addonName, ns = ...

local AHShop = {}
ns.AHShop = AHShop

local ROW_HEIGHT = 28
local LISTING_ROW_HEIGHT = 24
local MAX_MAT_ROWS = 20
local MAX_LISTING_ROWS = 16
local LEFT_WIDTH_PCT = 0.52 -- left panel width ratio

-- Quality pip size for atlas markup
local PIP_SIZE = 12

-- State
local container
local leftPanel, rightPanel
local tabBar
local matContent, matRows, matScroll
local listContent, listRows, listScroll
local footerTotal
local rightHeader, rightEmpty
local activeFilter = nil
local currentMats = {}
local livePrices = {}
local pendingSearchItemID = nil
local selectedItemID = nil -- currently selected material for right panel
-- Purchased items tracked in KazCraftDB.shopPurchases (survives /reload)
-- Cleared on fresh AH open (new session = new list)

--------------------------------------------------------------------
-- Get quality pip markup for an itemID
--------------------------------------------------------------------
local function GetQualityPips(itemID)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetItemReagentQualityInfo then
        return ""
    end
    local qualityInfo = C_TradeSkillUI.GetItemReagentQualityInfo(itemID)
    if qualityInfo and qualityInfo.iconSmall then
        return " " .. CreateAtlasMarkup(qualityInfo.iconSmall, PIP_SIZE, PIP_SIZE)
    end
    return ""
end

--------------------------------------------------------------------
-- Material row factory (left panel)
--------------------------------------------------------------------
local function CreateMatRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")
    row:Hide()

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row._defaultBgAlpha = (index % 2 == 0) and 0.03 or 0
    row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)

    row.leftAccent = row:CreateTexture(nil, "ARTWORK", nil, 2)
    row.leftAccent:SetSize(2, ROW_HEIGHT)
    row.leftAccent:SetPoint("LEFT")
    row.leftAccent:SetColorTexture(unpack(ns.COLORS.accent))
    row.leftAccent:Hide()

    row.divider = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", 4, 0)
    row.divider:SetPoint("BOTTOMRIGHT", -4, 0)
    row.divider:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)

    -- Name (with quality pips)
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -130, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Need qty
    row.shortText = row:CreateFontString(nil, "OVERLAY")
    row.shortText:SetFont(ns.FONT, 11, "")
    row.shortText:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.shortText:SetWidth(36)
    row.shortText:SetJustifyH("RIGHT")

    -- AH price
    row.ahPrice = row:CreateFontString(nil, "OVERLAY")
    row.ahPrice:SetFont(ns.FONT, 10, "")
    row.ahPrice:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.ahPrice:SetWidth(68)
    row.ahPrice:SetJustifyH("RIGHT")
    row.ahPrice:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Hover
    row:SetScript("OnEnter", function(self)
        row.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        row.leftAccent:Show()
        if row._itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(row._itemID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        if row._itemID == selectedItemID then
            row.bg:SetColorTexture(unpack(ns.COLORS.rowSelected or ns.COLORS.rowHover))
            row.leftAccent:Show()
        else
            row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
            row.leftAccent:Hide()
        end
        GameTooltip:Hide()
    end)

    -- Click to select + search + auto-buy (must call StartCommoditiesPurchase from hardware event)
    row:SetScript("OnClick", function()
        if row._itemID then
            selectedItemID = row._itemID
            AHShop:HighlightSelectedRow()
            AHShop:SearchAndShowListings(row._itemID)
            -- Show confirm dialog immediately from hardware click
            for _, mat in ipairs(currentMats) do
                if mat.itemID == row._itemID and mat.short > 0 then
                    ns.AHUI:ShowConfirmDialog(row._itemID, mat.short)
                    break
                end
            end
        end
    end)

    return row
end

--------------------------------------------------------------------
-- Listing row factory (right panel — AH results)
--------------------------------------------------------------------
local function CreateListingRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(LISTING_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * LISTING_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * LISTING_ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")
    row:Hide()

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row._defaultBgAlpha = (index % 2 == 0) and 0.03 or 0
    row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)

    row.divider = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", 4, 0)
    row.divider:SetPoint("BOTTOMRIGHT", -4, 0)
    row.divider:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Price
    row.priceText = row:CreateFontString(nil, "OVERLAY")
    row.priceText:SetFont(ns.FONT, 11, "")
    row.priceText:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.priceText:SetWidth(100)
    row.priceText:SetJustifyH("LEFT")
    row.priceText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Quantity available
    row.qtyText = row:CreateFontString(nil, "OVERLAY")
    row.qtyText:SetFont(ns.FONT, 11, "")
    row.qtyText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.qtyText:SetWidth(60)
    row.qtyText:SetJustifyH("RIGHT")
    row.qtyText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Hover
    row:SetScript("OnEnter", function()
        row.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
    end)
    row:SetScript("OnLeave", function()
        row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
    end)

    -- Click to buy full needed quantity (Blizzard API buys across price tiers)
    row:SetScript("OnClick", function()
        if row._itemID and selectedItemID then
            for _, mat in ipairs(currentMats) do
                if mat.itemID == selectedItemID and mat.short > 0 then
                    ns.AHUI:ShowConfirmDialog(selectedItemID, mat.short)
                    break
                end
            end
        end
    end)

    return row
end

--------------------------------------------------------------------
-- Build UI
--------------------------------------------------------------------
function AHShop:Init(contentFrame)
    if container then return end
    container = CreateFrame("Frame", nil, contentFrame)
    container:SetAllPoints()
    container:Hide()
    matRows = {}
    listRows = {}

    -- Tab bar — alt filter
    local function BuildTabs()
        local tabs = {{ key = "all", label = "All Alts" }}
        local chars = ns.Data:GetQueuedCharacters()
        for _, charKey in ipairs(chars) do
            local name = charKey:match("^(.-)%-") or charKey
            table.insert(tabs, { key = charKey, label = name })
        end
        return tabs
    end

    tabBar = ns.CreateTabBar(container, BuildTabs(), function(key)
        activeFilter = (key == "all") and nil or key
        AHShop:Refresh()
    end)
    tabBar:ClearAllPoints()
    tabBar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)

    -- LEFT PANEL — material list
    leftPanel = CreateFrame("Frame", nil, container)
    leftPanel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -28)
    leftPanel:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 36)

    -- Column headers (left)
    local leftColHeader = CreateFrame("Frame", nil, leftPanel)
    leftColHeader:SetHeight(18)
    leftColHeader:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, 0)
    leftColHeader:SetPoint("TOPRIGHT", leftPanel, "TOPRIGHT", 0, 0)

    local function LeftColLabel(text, point, x, w)
        local fs = leftColHeader:CreateFontString(nil, "OVERLAY")
        fs:SetFont(ns.FONT, 9, "")
        fs:SetTextColor(unpack(ns.COLORS.headerText))
        fs:SetText(text)
        if point == "LEFT" then
            fs:SetPoint("LEFT", leftColHeader, "LEFT", x, 0)
        else
            fs:SetPoint("RIGHT", leftColHeader, "RIGHT", x, 0)
        end
        if w then fs:SetWidth(w) end
        fs:SetJustifyH(point)
    end

    LeftColLabel("Material", "LEFT", 34)
    LeftColLabel("Need", "RIGHT", -80, 36)
    LeftColLabel("Price", "RIGHT", -8, 68)

    matScroll = CreateFrame("ScrollFrame", nil, leftPanel, "UIPanelScrollFrameTemplate")
    matScroll:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, -18)
    matScroll:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -16, 0)

    matContent = CreateFrame("Frame", nil, matScroll)
    matContent:SetWidth(1)
    matContent:SetHeight(1)
    matScroll:SetScrollChild(matContent)

    matScroll:SetScript("OnSizeChanged", function(self)
        matContent:SetWidth(self:GetWidth())
    end)

    for i = 1, MAX_MAT_ROWS do
        matRows[i] = CreateMatRow(matContent, i)
    end

    -- RIGHT PANEL — AH listings
    rightPanel = CreateFrame("Frame", nil, container)
    rightPanel:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -28)
    rightPanel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 36)

    -- Vertical divider
    local divider = container:CreateTexture(nil, "ARTWORK", nil, 2)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, 0)
    divider:SetPoint("BOTTOMLEFT", rightPanel, "BOTTOMLEFT", 0, 0)
    divider:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Right header
    rightHeader = rightPanel:CreateFontString(nil, "OVERLAY")
    rightHeader:SetFont(ns.FONT, 10, "")
    rightHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -2)
    rightHeader:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", -8, -2)
    rightHeader:SetJustifyH("LEFT")
    rightHeader:SetTextColor(unpack(ns.COLORS.headerText))
    rightHeader:SetText("Click a material to search AH")

    -- Right column labels
    local rightColHeader = CreateFrame("Frame", nil, rightPanel)
    rightColHeader:SetHeight(14)
    rightColHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, -16)
    rightColHeader:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", 0, -16)

    local function RightColLabel(text, point, x, w)
        local fs = rightColHeader:CreateFontString(nil, "OVERLAY")
        fs:SetFont(ns.FONT, 9, "")
        fs:SetTextColor(unpack(ns.COLORS.headerText))
        fs:SetText(text)
        if point == "LEFT" then
            fs:SetPoint("LEFT", rightColHeader, "LEFT", x, 0)
        else
            fs:SetPoint("RIGHT", rightColHeader, "RIGHT", x, 0)
        end
        if w then fs:SetWidth(w) end
        fs:SetJustifyH(point)
    end

    RightColLabel("Unit Price", "LEFT", 8)
    RightColLabel("Available", "RIGHT", -8, 60)

    listScroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, -30)
    listScroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -16, 0)

    listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetWidth(1)
    listContent:SetHeight(1)
    listScroll:SetScrollChild(listContent)

    listScroll:SetScript("OnSizeChanged", function(self)
        listContent:SetWidth(self:GetWidth())
    end)

    for i = 1, MAX_LISTING_ROWS do
        listRows[i] = CreateListingRow(listContent, i)
    end

    -- Empty state for right panel
    rightEmpty = rightPanel:CreateFontString(nil, "OVERLAY")
    rightEmpty:SetFont(ns.FONT, 11, "")
    rightEmpty:SetPoint("CENTER", rightPanel, "CENTER", 0, 0)
    rightEmpty:SetTextColor(unpack(ns.COLORS.mutedText))
    rightEmpty:SetText("Select a material")

    -- Footer
    local footer = CreateFrame("Frame", nil, container, "BackdropTemplate")
    footer:SetHeight(32)
    footer:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    footer:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    footer:SetBackdropColor(unpack(ns.COLORS.footerBg))

    footerTotal = footer:CreateFontString(nil, "OVERLAY")
    footerTotal:SetFont(ns.FONT, 11, "")
    footerTotal:SetPoint("LEFT", footer, "LEFT", 8, 0)
    footerTotal:SetTextColor(unpack(ns.COLORS.mutedText))


    -- Size panels dynamically on show/resize
    local function SizePanels()
        local w = container:GetWidth()
        if w and w > 0 then
            leftPanel:SetWidth(math.floor(w * LEFT_WIDTH_PCT))
        end
    end

    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 1, 0)
    rightPanel:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMRIGHT", 1, 0)

    container:SetScript("OnSizeChanged", SizePanels)
    container:SetScript("OnShow", SizePanels)
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function AHShop:Show()
    if not container then return end
    wipe(livePrices)
    selectedItemID = nil
    self:Refresh()
    self:ClearListings()
    container:Show()

    -- CraftSim queue loads async — retry refresh after a delay if list is empty
    if #currentMats == 0 then
        C_Timer.After(1, function()
            if AHShop:IsShown() then AHShop:Refresh() end
        end)
        C_Timer.After(3, function()
            if AHShop:IsShown() then AHShop:Refresh() end
        end)
    end
end

function AHShop:Hide()
    if container then container:Hide() end
end

function AHShop:IsShown()
    return container and container:IsShown()
end

--------------------------------------------------------------------
-- Highlight selected material row
--------------------------------------------------------------------
function AHShop:HighlightSelectedRow()
    for _, row in ipairs(matRows) do
        if row:IsShown() then
            if row._itemID == selectedItemID then
                row.bg:SetColorTexture(unpack(ns.COLORS.rowSelected or ns.COLORS.rowHover))
                row.leftAccent:Show()
            else
                row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
                row.leftAccent:Hide()
            end
        end
    end
end

--------------------------------------------------------------------
-- Refresh material list (left panel)
--------------------------------------------------------------------
function AHShop:Refresh()
    if not container then return end
    currentMats = ns.Data:GetMaterialList(activeFilter)

    -- Apply tracked purchases (GetItemCount may not reflect them yet)
    local purchases = KazCraftDB.shopPurchases
    if purchases then
        for _, mat in ipairs(currentMats) do
            if purchases[mat.itemID] then
                mat.have = mat.have + purchases[mat.itemID]
                mat.short = math.max(0, mat.need - mat.have)
            end
        end
    end

    -- Filter to only short, buyable materials (exclude soulbound)
    local shortMats = {}
    for _, mat in ipairs(currentMats) do
        if mat.short > 0 and not mat.soulbound then
            table.insert(shortMats, mat)
        end
    end
    currentMats = shortMats

    matContent:SetHeight(math.max(1, #currentMats * ROW_HEIGHT))

    local grandTotal = 0

    for i = 1, math.max(#currentMats, #matRows) do
        local row = matRows[i]
        if not row and i <= #currentMats then
            row = CreateMatRow(matContent, i)
            matRows[i] = row
        end
        if row then
            if i <= #currentMats then
                local mat = currentMats[i]
                row.icon:SetTexture(mat.icon)

                -- Name with quality pips
                local pips = GetQualityPips(mat.itemID)
                row.nameText:SetText(mat.itemName .. pips)

                row.shortText:SetText("x" .. mat.short)
                row.shortText:SetTextColor(unpack(ns.COLORS.redText))

                -- Use live AH price if available, else TSM
                local unitPrice = livePrices[mat.itemID] or mat.price
                if unitPrice > 0 then
                    row.ahPrice:SetText(ns.FormatGold(unitPrice))
                    if livePrices[mat.itemID] then
                        row.ahPrice:SetTextColor(unpack(ns.COLORS.goldText))
                    else
                        row.ahPrice:SetTextColor(unpack(ns.COLORS.mutedText))
                    end
                    grandTotal = grandTotal + (mat.short * unitPrice)
                else
                    row.ahPrice:SetText("\226\128\148")
                    row.ahPrice:SetTextColor(unpack(ns.COLORS.mutedText))
                end

                row._itemID = mat.itemID
                row:Show()

                -- Maintain selection highlight
                if mat.itemID == selectedItemID then
                    row.bg:SetColorTexture(unpack(ns.COLORS.rowSelected or ns.COLORS.rowHover))
                    row.leftAccent:Show()
                end
            else
                row:Hide()
            end
        end
    end

    if footerTotal then
        if grandTotal > 0 then
            footerTotal:SetText("Total: " .. ns.FormatGold(grandTotal))
        else
            footerTotal:SetText("No materials needed")
        end
    end

    -- Rebuild alt tabs
    if tabBar then
        local tabs = {{ key = "all", label = "All Alts" }}
        local chars = ns.Data:GetQueuedCharacters()
        for _, charKey in ipairs(chars) do
            local name = charKey:match("^(.-)%-") or charKey
            table.insert(tabs, { key = charKey, label = name })
        end
        for i, btn in ipairs(tabBar.buttons) do
            if tabs[i] then
                btn.label:SetText(tabs[i].label)
                btn.key = tabs[i].key
                btn:SetWidth(btn.label:GetStringWidth() + 16)
                btn:Show()
            else
                btn:Hide()
            end
        end
    end
end

--------------------------------------------------------------------
-- Right panel — listings display
--------------------------------------------------------------------
function AHShop:ClearListings()
    for _, row in ipairs(listRows) do
        row:Hide()
    end
    if rightEmpty then rightEmpty:Show() end
    if rightHeader then rightHeader:SetText("Click a material to search AH") end
    if listContent then listContent:SetHeight(1) end
end

function AHShop:ShowListings(itemID)
    if not itemID then return end

    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
    if not numResults or numResults == 0 then
        self:ClearListings()
        if rightHeader then
            local itemName = C_Item.GetItemNameByID(itemID) or ("Item:" .. itemID)
            rightHeader:SetText(itemName .. GetQualityPips(itemID) .. "  \226\128\148  No listings")
        end
        return
    end

    if rightEmpty then rightEmpty:Hide() end

    -- Header: item name + quality
    local itemName = C_Item.GetItemNameByID(itemID) or ("Item:" .. itemID)
    if rightHeader then
        rightHeader:SetText(itemName .. GetQualityPips(itemID) .. "  (" .. numResults .. " listings)")
    end

    -- Aggregate by price (commodities can have multiple at same price)
    local displayCount = math.min(numResults, MAX_LISTING_ROWS)
    listContent:SetHeight(math.max(1, displayCount * LISTING_ROW_HEIGHT))

    for i = 1, math.max(displayCount, #listRows) do
        local row = listRows[i]
        if not row and i <= displayCount then
            row = CreateListingRow(listContent, i)
            listRows[i] = row
        end
        if row then
            if i <= displayCount then
                local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
                if result then
                    row.priceText:SetText(ns.FormatGold(result.unitPrice))
                    row.qtyText:SetText("x" .. result.quantity)
                    row._itemID = itemID
                    row._unitPrice = result.unitPrice
                    row._available = result.quantity
                    row:Show()
                else
                    row:Hide()
                end
            else
                row:Hide()
            end
        end
    end

    -- Store lowest price
    local firstResult = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
    if firstResult and firstResult.unitPrice then
        livePrices[itemID] = firstResult.unitPrice
    end
end

--------------------------------------------------------------------
-- Search + show listings for selected material
--------------------------------------------------------------------
function AHShop:SearchAndShowListings(itemID)
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then
        print("|cffc8aa64KazCraft:|r Auction House is not open.")
        return
    end

    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        print("|cffc8aa64KazCraft:|r AH throttled, wait a moment...")
        return
    end

    pendingSearchItemID = itemID

    local itemKey = C_AuctionHouse.MakeItemKey(itemID)
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    C_AuctionHouse.SendSearchQuery(itemKey, sorts, true)
end

--------------------------------------------------------------------
-- AH event handlers
--------------------------------------------------------------------
function AHShop:OnCommoditySearchResults(eventItemID)
    local targetItemID = eventItemID or pendingSearchItemID
    if not targetItemID then return end

    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(targetItemID)
    if not numResults or numResults == 0 then return end

    local result = C_AuctionHouse.GetCommoditySearchResultInfo(targetItemID, 1)
    if not result or not result.unitPrice then return end

    -- Store live price
    livePrices[targetItemID] = result.unitPrice

    -- Update matching material row price
    for _, r in ipairs(matRows) do
        if r._itemID == targetItemID and r:IsShown() then
            r.ahPrice:SetText(ns.FormatGold(result.unitPrice))
            r.ahPrice:SetTextColor(unpack(ns.COLORS.goldText))
            break
        end
    end

    if pendingSearchItemID == targetItemID then
        pendingSearchItemID = nil
    end

    -- Show listings in right panel if this is the selected item
    if targetItemID == selectedItemID then
        self:ShowListings(targetItemID)
    end

    self:RecalcTotal()

end

function AHShop:RecalcTotal()
    local grandTotal = 0
    for _, mat in ipairs(currentMats) do
        local unitPrice = livePrices[mat.itemID] or mat.price
        grandTotal = grandTotal + (mat.short * unitPrice)
    end
    if footerTotal then
        if grandTotal > 0 then
            footerTotal:SetText("Total: " .. ns.FormatGold(grandTotal))
        else
            footerTotal:SetText("No materials needed")
        end
    end
end

function AHShop:OnThrottleReady()
    -- Reserved for future use
end

-- Called on AUCTION_HOUSE_SHOW — fresh session, clear purchase tracking
function AHShop:OnAHOpen()
    KazCraftDB.shopPurchases = {}
end


function AHShop:OnPurchaseSucceeded(itemID, qty)
    -- Track purchase in SavedVariables (survives /reload)
    if itemID and qty then
        if not KazCraftDB.shopPurchases then KazCraftDB.shopPurchases = {} end
        KazCraftDB.shopPurchases[itemID] = (KazCraftDB.shopPurchases[itemID] or 0) + qty
    end
    if self:IsShown() then
        self:Refresh()
    end
end
