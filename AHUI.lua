local addonName, ns = ...

local AHUI = {}
ns.AHUI = AHUI

local FRAME_WIDTH = 750
local FRAME_HEIGHT = 540
local MIN_WIDTH, MIN_HEIGHT = 600, 400
local MAX_WIDTH, MAX_HEIGHT = 1000, 700

-- State
local mainFrame
local tabBar
local contentFrame
local goldText
local confirmDialog
local ahOpen = false
local activeTab = nil
local switchingToBlizzard = false

-- Tab definitions (order matters)
local TAB_DEFS = {
    { key = "shop",     label = "Shop",     module = function() return ns.AHShop end },
    { key = "browse",   label = "Browse",   module = function() return ns.AHBrowse end },
    { key = "sell",     label = "Sell",     module = function() return ns.AHSell end },
    { key = "auctions", label = "Auctions", module = function() return ns.AHAuctions end },
}

--------------------------------------------------------------------
-- Blizzard AH frame suppression (SetScale pattern)
--------------------------------------------------------------------
local function SuppressBlizzardAH()
    if not AuctionHouseFrame then return end
    AuctionHouseFrame:SetScale(0.001)
end

local function IsTabFrame(frame)
    -- PanelTabButtonTemplate tabs have .Left, .Right, .Text
    return frame:GetObjectType() == "Button" and frame.Text and frame.Left and frame.Right
end

local function ResizeTab(tab)
    if tab.Text then
        tab.Text:SetWidth(0)  -- reset so GetStringWidth measures natural width
    end
    PanelTemplates_TabResize(tab, 20, nil, 70)
end

local function RestoreBlizzardAH()
    if not AuctionHouseFrame then return end
    AuctionHouseFrame:SetScale(1)

    -- Defer tab fix — scale change needs a frame to propagate before
    -- GetStringWidth() returns correct values
    C_Timer.After(0, function()
        if not AuctionHouseFrame then return end

        -- Fix Blizzard's own tabs
        if AuctionHouseFrame.Tabs then
            for _, tab in ipairs(AuctionHouseFrame.Tabs) do
                ResizeTab(tab)
            end
        end

        -- Fix addon tabs (TSM via LibAHTab, Auctionator, Collectionator, etc.)
        -- These are parented to sub-frames of AuctionHouseFrame, not in .Tabs
        -- Scan children 2 levels deep for anything that looks like a tab
        for _, child in pairs({AuctionHouseFrame:GetChildren()}) do
            if IsTabFrame(child) then
                ResizeTab(child)
            end
            -- LibAHTab uses a rootFrame container — check one level deeper
            if child.GetChildren then
                for _, subChild in pairs({child:GetChildren()}) do
                    if IsTabFrame(subChild) then
                        ResizeTab(subChild)
                    end
                end
            end
        end

        PanelTemplates_UpdateTabs(AuctionHouseFrame)
    end)
end

--------------------------------------------------------------------
-- Confirm dialog (commodity purchase)
--------------------------------------------------------------------
local confirmItemID, confirmQty

local function CreateConfirmDialog(parent)
    local dialog = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    dialog:SetSize(300, 180)
    dialog:SetPoint("CENTER", parent, "CENTER", 0, 0)
    dialog:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    dialog:SetBackdropColor(20/255, 20/255, 20/255, 0.98)
    dialog:SetBackdropBorderColor(unpack(ns.COLORS.accent))
    dialog:SetFrameStrata("DIALOG")
    dialog:SetFrameLevel(200)
    dialog:EnableMouse(true)
    dialog:Hide()

    -- Title
    dialog.title = dialog:CreateFontString(nil, "OVERLAY")
    dialog.title:SetFont(ns.FONT, 13, "")
    dialog.title:SetPoint("TOP", dialog, "TOP", 0, -12)
    dialog.title:SetText("Confirm Purchase")
    dialog.title:SetTextColor(unpack(ns.COLORS.brightText))

    -- Item icon + name
    dialog.icon = dialog:CreateTexture(nil, "ARTWORK")
    dialog.icon:SetSize(28, 28)
    dialog.icon:SetPoint("TOPLEFT", dialog, "TOPLEFT", 16, -38)

    dialog.nameText = dialog:CreateFontString(nil, "OVERLAY")
    dialog.nameText:SetFont(ns.FONT, 11, "")
    dialog.nameText:SetPoint("LEFT", dialog.icon, "RIGHT", 8, 0)
    dialog.nameText:SetPoint("RIGHT", dialog, "RIGHT", -12, 0)
    dialog.nameText:SetJustifyH("LEFT")
    dialog.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Quantity
    dialog.qtyText = dialog:CreateFontString(nil, "OVERLAY")
    dialog.qtyText:SetFont(ns.FONT, 11, "")
    dialog.qtyText:SetPoint("TOPLEFT", dialog.icon, "BOTTOMLEFT", 0, -10)
    dialog.qtyText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Unit price
    dialog.unitLabel = dialog:CreateFontString(nil, "OVERLAY")
    dialog.unitLabel:SetFont(ns.FONT, 10, "")
    dialog.unitLabel:SetPoint("TOPLEFT", dialog.qtyText, "BOTTOMLEFT", 0, -4)
    dialog.unitLabel:SetText("Unit Price:")
    dialog.unitLabel:SetTextColor(unpack(ns.COLORS.headerText))

    dialog.unitText = dialog:CreateFontString(nil, "OVERLAY")
    dialog.unitText:SetFont(ns.FONT, 11, "")
    dialog.unitText:SetPoint("LEFT", dialog.unitLabel, "RIGHT", 6, 0)
    dialog.unitText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Total price
    dialog.totalLabel = dialog:CreateFontString(nil, "OVERLAY")
    dialog.totalLabel:SetFont(ns.FONT, 10, "")
    dialog.totalLabel:SetPoint("TOPLEFT", dialog.unitLabel, "BOTTOMLEFT", 0, -4)
    dialog.totalLabel:SetText("Total:")
    dialog.totalLabel:SetTextColor(unpack(ns.COLORS.headerText))

    dialog.totalText = dialog:CreateFontString(nil, "OVERLAY")
    dialog.totalText:SetFont(ns.FONT, 12, "")
    dialog.totalText:SetPoint("LEFT", dialog.totalLabel, "RIGHT", 6, 0)
    dialog.totalText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Status
    dialog.statusText = dialog:CreateFontString(nil, "OVERLAY")
    dialog.statusText:SetFont(ns.FONT, 10, "")
    dialog.statusText:SetPoint("BOTTOM", dialog, "BOTTOM", 0, 42)
    dialog.statusText:SetTextColor(unpack(ns.COLORS.mutedText))
    dialog.statusText:SetText("Requesting price quote...")

    -- Buy Now button (requires hardware event)
    dialog.buyBtn = ns.CreateButton(dialog, "Buy Now", 100, 26)
    dialog.buyBtn:SetPoint("BOTTOMRIGHT", dialog, "BOTTOM", -4, 10)
    dialog.buyBtn:SetScript("OnClick", function()
        if confirmItemID and confirmQty then
            C_AuctionHouse.ConfirmCommoditiesPurchase(confirmItemID, confirmQty)
            dialog.statusText:SetText("Purchasing...")
            dialog.buyBtn:Disable()
        end
    end)
    dialog.buyBtn:Disable()

    -- Cancel button
    dialog.cancelBtn = ns.CreateButton(dialog, "Cancel", 100, 26)
    dialog.cancelBtn:SetPoint("BOTTOMLEFT", dialog, "BOTTOM", 4, 10)
    dialog.cancelBtn:SetScript("OnClick", function()
        dialog:Hide()
    end)

    -- On hide: cancel commodity purchase ONLY if we didn't just succeed
    dialog:SetScript("OnHide", function()
        if not dialog._purchaseSucceeded then
            C_AuctionHouse.CancelCommoditiesPurchase()
        end
        dialog._purchaseSucceeded = nil
        confirmItemID = nil
        confirmQty = nil
    end)

    return dialog
end

--------------------------------------------------------------------
-- Main frame
--------------------------------------------------------------------
local function CreateMainFrame()
    mainFrame = ns.CreateFlatFrame("KazCraftAHFrame", FRAME_WIDTH, FRAME_HEIGHT)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetFrameLevel(100)
    mainFrame:Hide()

    -- Resizable
    mainFrame:SetResizable(true)
    mainFrame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)

    -- Restore saved size
    if KazCraftDB.ahSize then
        mainFrame:SetSize(KazCraftDB.ahSize[1], KazCraftDB.ahSize[2])
    end

    -- Close button
    local closeBtn = ns.CreateCloseButton(mainFrame)
    closeBtn:SetScript("OnClick", function()
        AHUI:Hide()
    end)

    -- WoW UI button (switch back to Blizzard's AH)
    local wowBtn = ns.CreateButton(mainFrame, "WoW UI", 54, 20)
    wowBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, 0)
    wowBtn:SetScript("OnClick", function()
        AHUI:SwitchToBlizzard()
    end)

    -- ESC key support
    table.insert(UISpecialFrames, "KazCraftAHFrame")
    mainFrame:SetScript("OnHide", function()
        if switchingToBlizzard then
            switchingToBlizzard = false
            return
        end
        -- Close the AH session entirely (don't just restore Blizzard's frame).
        -- Restore scale so tabs aren't broken next time, then hide Blizzard's
        -- frame and close the AH connection.
        if ahOpen then
            ahOpen = false
            RestoreBlizzardAH()
            if AuctionHouseFrame then AuctionHouseFrame:Hide() end
            C_AuctionHouse.CloseAuctionHouse()
        end
    end)

    -- Title
    mainFrame.titleText = mainFrame:CreateFontString(nil, "OVERLAY")
    mainFrame.titleText:SetFont(ns.FONT, 13, "")
    mainFrame.titleText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -8)
    mainFrame.titleText:SetText("Auction House")
    mainFrame.titleText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Separator under title
    local sep = mainFrame:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -28)
    sep:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -6, -28)
    sep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Tab bar
    local tabDefs = {}
    for _, def in ipairs(TAB_DEFS) do
        table.insert(tabDefs, { key = def.key, label = def.label })
    end

    tabBar = ns.CreateTabBar(mainFrame, tabDefs, function(key)
        AHUI:SelectTab(key)
    end)
    tabBar:ClearAllPoints()
    tabBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -32)
    tabBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -32)

    -- Content area (tabs populate this)
    contentFrame = CreateFrame("Frame", nil, mainFrame)
    contentFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -62)
    contentFrame:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -6, -62)
    contentFrame:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 36)

    -- Footer
    local footer = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    footer:SetHeight(32)
    footer:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 1, 1)
    footer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -1, 1)
    footer:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    footer:SetBackdropColor(unpack(ns.COLORS.footerBg))

    -- Gold display
    goldText = footer:CreateFontString(nil, "OVERLAY")
    goldText:SetFont(ns.FONT, 11, "")
    goldText:SetPoint("LEFT", footer, "LEFT", 8, 0)
    goldText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Resize grip (bottom-right corner)
    local resizeGrip = CreateFrame("Button", nil, mainFrame)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    resizeGrip:EnableMouse(true)

    local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTex:SetSize(16, 16)
    gripTex:SetPoint("CENTER")
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gripTex:SetVertexColor(120/255, 110/255, 90/255)
    resizeGrip.gripTex = gripTex

    resizeGrip:SetScript("OnEnter", function(self)
        self.gripTex:SetVertexColor(200/255, 180/255, 140/255)
    end)
    resizeGrip:SetScript("OnLeave", function(self)
        self.gripTex:SetVertexColor(120/255, 110/255, 90/255)
    end)
    resizeGrip:SetScript("OnMouseDown", function()
        mainFrame:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        mainFrame:StopMovingOrSizing()
        local w, h = mainFrame:GetSize()
        KazCraftDB.ahSize = { math.floor(w + 0.5), math.floor(h + 0.5) }
    end)

    -- Confirm dialog
    confirmDialog = CreateConfirmDialog(mainFrame)

    -- Save/restore position
    function mainFrame:SavePosition()
        local point, _, relPoint, x, y = self:GetPoint()
        KazCraftDB.ahPosition = { point, relPoint, x, y }
    end

    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SavePosition()
    end)

    -- Restore position
    local pos = KazCraftDB.ahPosition
    if pos and pos[1] then
        mainFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

--------------------------------------------------------------------
-- Tab selection — lazy-init each module
--------------------------------------------------------------------
function AHUI:SelectTab(key)
    activeTab = key

    -- Hide all tab modules
    for _, def in ipairs(TAB_DEFS) do
        local mod = def.module()
        if mod and mod.Hide then
            mod:Hide()
        end
    end

    -- Find and show selected tab
    for _, def in ipairs(TAB_DEFS) do
        if def.key == key then
            local mod = def.module()
            if mod then
                if mod.Init then
                    mod:Init(contentFrame)
                end
                if mod.Show then
                    mod:Show()
                end
            end
            break
        end
    end
end

function AHUI:GetContentFrame()
    return contentFrame
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function AHUI:Show()
    ahOpen = true
    if not mainFrame then
        CreateMainFrame()
    end

    -- Suppress Blizzard AH
    SuppressBlizzardAH()

    -- Update gold
    self:UpdateGold()

    -- Select Shop tab by default
    if tabBar then
        tabBar:Select("shop")
    end
    self:SelectTab("shop")

    mainFrame:Show()

end

function AHUI:Hide()
    ahOpen = false
    -- Hide confirm dialog first
    if confirmDialog and confirmDialog:IsShown() then
        confirmDialog:Hide()
    end
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    end
end

function AHUI:IsShown()
    return mainFrame and mainFrame:IsShown()
end

function AHUI:IsAHOpen()
    return ahOpen
end

--------------------------------------------------------------------
-- Refresh (called from Core.lua on BAG_UPDATE etc)
--------------------------------------------------------------------
function AHUI:Refresh()
    if not self:IsShown() then return end
    -- Refresh active tab
    for _, def in ipairs(TAB_DEFS) do
        if def.key == activeTab then
            local mod = def.module()
            if mod and mod.Refresh and mod:IsShown() then
                mod:Refresh()
            end
            break
        end
    end
end

--------------------------------------------------------------------
-- Gold display
--------------------------------------------------------------------
function AHUI:UpdateGold()
    if goldText then
        goldText:SetText(GetCoinTextureString(GetMoney()))
    end
end

--------------------------------------------------------------------
-- WoW UI switch buttons
--------------------------------------------------------------------
function AHUI:SwitchToBlizzard()
    switchingToBlizzard = true
    if mainFrame then mainFrame:Hide() end
    RestoreBlizzardAH()
    -- Don't close AH connection — just show Blizzard's frame

    -- Add "KazCraft" button to Blizzard's AH if not already there
    self:EnsureBlizzardSwitchButton()
end

function AHUI:EnsureBlizzardSwitchButton()
    if not AuctionHouseFrame then return end
    if AuctionHouseFrame._kazButton then return end

    local btn = ns.CreateButton(AuctionHouseFrame, "KazCraft", 70, 22)
    btn:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -30, -4)
    btn:SetFrameStrata("HIGH")
    btn:SetScript("OnClick", function()
        SuppressBlizzardAH()
        if not mainFrame then CreateMainFrame() end
        AHUI:UpdateGold()
        if tabBar then tabBar:Select(activeTab or "shop") end
        AHUI:SelectTab(activeTab or "shop")
        mainFrame:Show()
    end)
    AuctionHouseFrame._kazButton = btn
end

--------------------------------------------------------------------
-- Confirm dialog for commodity purchases
--------------------------------------------------------------------
function AHUI:ShowConfirmDialog(itemID, qty)
    if not mainFrame then return end
    if not confirmDialog then
        confirmDialog = CreateConfirmDialog(mainFrame)
    end

    confirmItemID = itemID
    confirmQty = qty

    -- Item info
    local itemName, _, itemQuality, _, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(itemID)
    confirmDialog.icon:SetTexture(itemTexture or 134400)
    local qualityColor = ITEM_QUALITY_COLORS[itemQuality]
    if qualityColor then
        confirmDialog.nameText:SetText(qualityColor.hex .. (itemName or "?") .. "|r")
    else
        confirmDialog.nameText:SetText(itemName or "?")
    end

    confirmDialog.qtyText:SetText("Quantity: " .. qty)
    confirmDialog.unitText:SetText("...")
    confirmDialog.totalText:SetText("...")
    confirmDialog.statusText:SetText("Requesting price quote...")
    confirmDialog.buyBtn:Disable()

    confirmDialog:Show()

    -- Request price quote from server
    C_AuctionHouse.StartCommoditiesPurchase(itemID, qty)
end

function AHUI:OnCommodityPriceUpdated(unitPrice, totalPrice)
    if not confirmDialog or not confirmDialog:IsShown() then return end

    confirmDialog.unitText:SetText(ns.FormatGold(unitPrice))
    confirmDialog.totalText:SetText(ns.FormatGold(totalPrice))
    confirmDialog.statusText:SetText("Ready to purchase")
    confirmDialog.buyBtn:Enable()
end

function AHUI:OnCommodityPriceUnavailable()
    if not confirmDialog or not confirmDialog:IsShown() then return end

    confirmDialog.statusText:SetText("|cffff6666Price unavailable — item sold out?|r")
    confirmDialog.buyBtn:Disable()
end

function AHUI:OnCommodityPurchaseSucceeded()
    if confirmDialog and confirmDialog:IsShown() then
        -- Flag so OnHide doesn't call CancelCommoditiesPurchase
        confirmDialog._purchaseSucceeded = true
        confirmDialog.statusText:SetText("|cff4dff4dPurchase complete!|r")
        confirmDialog.buyBtn:Disable()
        PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
        -- Brief delay before hiding — let server finish delivery to bags
        C_Timer.After(0.3, function()
            if confirmDialog:IsShown() then
                confirmDialog:Hide()
            end
        end)
    end

    -- Notify Shop tab with what was purchased
    local purchasedItemID, purchasedQty = confirmItemID, confirmQty
    if ns.AHShop and ns.AHShop.OnPurchaseSucceeded then
        ns.AHShop:OnPurchaseSucceeded(purchasedItemID, purchasedQty)
    end
end

function AHUI:OnCommodityPurchaseFailed()
    if confirmDialog and confirmDialog:IsShown() then
        confirmDialog.statusText:SetText("|cffff6666Purchase failed.|r")
        confirmDialog.buyBtn:Disable()
    end
end
