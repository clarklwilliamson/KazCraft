local addonName, ns = ...

local AHShop = {}
ns.AHShop = AHShop

local ROW_HEIGHT = 28
local MAX_ROWS = 16

-- State
local container       -- our content frame (parented to AHUI content area)
local tabBar
local matContent
local matRows = {}
local footerTotal
local activeFilter = nil -- nil = all alts, or charKey
local currentMats = {}
local livePrices = {}
local searchQueue = {}
local pendingSearchItemID = nil

--------------------------------------------------------------------
-- Row factory
--------------------------------------------------------------------
local function CreateMatRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
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

    -- Name
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -230, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Short qty
    row.shortText = row:CreateFontString(nil, "OVERLAY")
    row.shortText:SetFont(ns.FONT, 11, "")
    row.shortText:SetPoint("RIGHT", row, "RIGHT", -190, 0)
    row.shortText:SetWidth(36)
    row.shortText:SetJustifyH("RIGHT")

    -- AH price
    row.ahPrice = row:CreateFontString(nil, "OVERLAY")
    row.ahPrice:SetFont(ns.FONT, 10, "")
    row.ahPrice:SetPoint("RIGHT", row, "RIGHT", -118, 0)
    row.ahPrice:SetWidth(68)
    row.ahPrice:SetJustifyH("RIGHT")
    row.ahPrice:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Total cost
    row.totalCost = row:CreateFontString(nil, "OVERLAY")
    row.totalCost:SetFont(ns.FONT, 10, "")
    row.totalCost:SetPoint("RIGHT", row, "RIGHT", -50, 0)
    row.totalCost:SetWidth(68)
    row.totalCost:SetJustifyH("RIGHT")
    row.totalCost:SetTextColor(unpack(ns.COLORS.mutedText))

    -- [Search] button
    row.searchBtn = ns.CreateButton(row, "Search", 48, 20)
    row.searchBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    -- Hover + tooltip
    local enterFrame = CreateFrame("Frame", nil, row)
    enterFrame:SetAllPoints()
    enterFrame:SetScript("OnEnter", function(self)
        row.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        row.leftAccent:Show()
        if row._itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(row._itemID)
            GameTooltip:Show()
        end
    end)
    enterFrame:SetScript("OnLeave", function()
        row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
        row.leftAccent:Hide()
        GameTooltip:Hide()
    end)
    enterFrame:SetFrameLevel(row:GetFrameLevel())

    return row
end

--------------------------------------------------------------------
-- Build UI (called once from AHUI when Shop tab first selected)
--------------------------------------------------------------------
function AHShop:Init(contentFrame)
    if container then return end
    container = CreateFrame("Frame", nil, contentFrame)
    container:SetAllPoints()
    container:Hide()

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

    ColLabel("Material", "LEFT", 34)
    ColLabel("Need", "RIGHT", -190, 36)
    ColLabel("AH Price", "RIGHT", -118, 68)
    ColLabel("Total", "RIGHT", -50, 68)

    -- Material scroll area
    local matScroll = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    matScroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -48)
    matScroll:SetPoint("TOPRIGHT", container, "TOPRIGHT", -16, -48)
    matScroll:SetPoint("BOTTOM", container, "BOTTOM", 0, 36)

    matContent = CreateFrame("Frame", nil, matScroll)
    matContent:SetWidth(1)
    matContent:SetHeight(1)
    matScroll:SetScrollChild(matContent)

    -- Update content width after layout
    matScroll:SetScript("OnSizeChanged", function(self)
        matContent:SetWidth(self:GetWidth())
    end)

    for i = 1, MAX_ROWS do
        matRows[i] = CreateMatRow(matContent, i)
    end

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

    -- Search All button
    local searchAllBtn = ns.CreateButton(footer, "Search All", 80, 22)
    searchAllBtn:SetPoint("RIGHT", footer, "RIGHT", -6, 0)
    searchAllBtn:SetScript("OnClick", function()
        AHShop:SearchAll()
    end)

    -- Buy All button
    local buyAllBtn = ns.CreateButton(footer, "Buy All", 60, 22)
    buyAllBtn:SetPoint("RIGHT", searchAllBtn, "LEFT", -4, 0)
    buyAllBtn:SetScript("OnClick", function()
        AHShop:BuyAll()
    end)
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function AHShop:Show()
    if not container then return end
    wipe(livePrices)
    self:Refresh()
    container:Show()
end

function AHShop:Hide()
    if container then container:Hide() end
    wipe(searchQueue)
end

function AHShop:IsShown()
    return container and container:IsShown()
end

--------------------------------------------------------------------
-- Refresh display
--------------------------------------------------------------------
function AHShop:Refresh()
    if not container then return end
    currentMats = ns.Data:GetMaterialList(activeFilter)

    -- Filter to only short materials
    local shortMats = {}
    for _, mat in ipairs(currentMats) do
        if mat.short > 0 then
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
                row.nameText:SetText(mat.itemName)

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
                    local lineCost = mat.short * unitPrice
                    row.totalCost:SetText(ns.FormatGold(lineCost))
                    grandTotal = grandTotal + lineCost
                else
                    row.ahPrice:SetText("\226\128\148")
                    row.ahPrice:SetTextColor(unpack(ns.COLORS.mutedText))
                    row.totalCost:SetText("\226\128\148")
                end

                -- Wire search button
                local itemID = mat.itemID
                row.searchBtn:SetScript("OnClick", function()
                    AHShop:SearchItem(itemID)
                end)

                row._itemID = itemID
                row:Show()
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

    -- Rebuild alt tabs if character list changed
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
-- AH Search — commodity price lookup
--------------------------------------------------------------------
function AHShop:SearchItem(itemID)
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

function AHShop:OnCommoditySearchResults(eventItemID)
    local targetItemID = eventItemID or pendingSearchItemID
    if not targetItemID then return end

    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(targetItemID)
    if not numResults or numResults == 0 then return end

    local result = C_AuctionHouse.GetCommoditySearchResultInfo(targetItemID, 1)
    if not result or not result.unitPrice then return end

    -- Store live price
    livePrices[targetItemID] = result.unitPrice

    -- Update matching row immediately
    for _, r in ipairs(matRows) do
        if r._itemID == targetItemID and r:IsShown() then
            r.ahPrice:SetText(ns.FormatGold(result.unitPrice))
            r.ahPrice:SetTextColor(unpack(ns.COLORS.goldText))
            for _, m in ipairs(currentMats) do
                if m.itemID == targetItemID then
                    r.totalCost:SetText(ns.FormatGold(m.short * result.unitPrice))
                    break
                end
            end
            break
        end
    end

    if pendingSearchItemID == targetItemID then
        pendingSearchItemID = nil
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

function AHShop:SearchAll()
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then
        print("|cffc8aa64KazCraft:|r Auction House is not open.")
        return
    end
    wipe(searchQueue)
    for _, mat in ipairs(currentMats) do
        table.insert(searchQueue, mat.itemID)
    end
    self:ProcessSearchQueue()
end

function AHShop:ProcessSearchQueue()
    if #searchQueue == 0 then return end
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then return end

    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        -- Will be called again from Core.lua on AUCTION_HOUSE_THROTTLED_SYSTEM_READY
        return
    end

    if pendingSearchItemID then
        C_Timer.After(0.3, function()
            AHShop:ProcessSearchQueue()
        end)
        return
    end

    local itemID = table.remove(searchQueue, 1)
    self:SearchItem(itemID)

    if #searchQueue > 0 then
        C_Timer.After(0.5, function()
            AHShop:ProcessSearchQueue()
        end)
    end
end

function AHShop:OnThrottleReady()
    if #searchQueue > 0 then
        self:ProcessSearchQueue()
    end
end

--------------------------------------------------------------------
-- Buy All — chain commodity purchases via AHUI confirm dialog
--------------------------------------------------------------------
function AHShop:BuyAll()
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then
        print("|cffc8aa64KazCraft:|r Auction House is not open.")
        return
    end
    for _, mat in ipairs(currentMats) do
        if mat.short > 0 and livePrices[mat.itemID] then
            ns.AHUI:ShowConfirmDialog(mat.itemID, mat.short)
            return
        end
    end
    print("|cffc8aa64KazCraft:|r Search first to get live prices.")
end

function AHShop:OnPurchaseSucceeded()
    C_Timer.After(0.5, function()
        if AHShop:IsShown() then
            AHShop:Refresh()
        end
    end)
end
