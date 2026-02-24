local addonName, ns = ...

local frame = CreateFrame("Frame")
ns.eventFrame = frame

-- Current character identity
ns.charKey = nil
ns.currentProfName = nil

-- Default SavedVariables
local DB_DEFAULTS = {
    version = 1,
    queues = {},
    recipeCache = {},
    profPosition = {},
    ahPosition = {},
    profSize = nil,
    profCollapses = {},
    settings = {
        useBestQuality = true,
    },
    lastRecipeID = nil,
}

local function InitDB()
    if not KazCraftDB then
        KazCraftDB = CopyTable(DB_DEFAULTS)
    end
    for k, v in pairs(DB_DEFAULTS) do
        if KazCraftDB[k] == nil then
            KazCraftDB[k] = CopyTable(v)
        end
    end
end

local function SetCharKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    if name and realm then
        ns.charKey = name .. "-" .. realm
    end
end

-- Event handlers
local handlers = {}

function handlers.ADDON_LOADED(addon)
    if addon ~= addonName then return end
    InitDB()
    SetCharKey()
    frame:UnregisterEvent("ADDON_LOADED")
end

function handlers.TRADE_SKILL_SHOW()
    SetCharKey()

    -- Determine profession name
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    ns.currentProfInfo = profInfo
    ns.currentProfName = profInfo and profInfo.professionName or "Unknown"

    -- Background cache all recipes
    ns.Data:CacheAllRecipes(profInfo)

    -- Show our profession frame (replaces Blizzard ProfessionsFrame)
    if ns.ProfFrame then
        ns.ProfFrame:OnTradeSkillShow()
    end
end

function handlers.TRADE_SKILL_CLOSE()
    if ns.ProfFrame then
        ns.ProfFrame:OnTradeSkillClose()
    end
    ns.currentProfName = nil
end

function handlers.TRADE_SKILL_LIST_UPDATE()
    if ns.ProfFrame then
        ns.ProfFrame:OnTradeSkillListUpdate()
    end
end

function handlers.TRADE_SKILL_DATA_SOURCE_CHANGED()
    SetCharKey()
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    ns.currentProfInfo = profInfo
    ns.currentProfName = profInfo and profInfo.professionName or "Unknown"
    ns.Data:CacheAllRecipes(profInfo)
    if ns.ProfFrame then
        ns.ProfFrame:OnTradeSkillDataSourceChanged()
    end
end

function handlers.TRADE_SKILL_CRAFT_BEGIN()
    if ns.ProfFrame then
        ns.ProfFrame:OnCraftBegin()
    end
end

function handlers.UPDATE_TRADESKILL_CAST_STOPPED()
    if ns.ProfFrame then
        ns.ProfFrame:OnCraftStopped()
    end
end

function handlers.CRAFTING_DETAILS_UPDATE()
    if ns.ProfFrame and ns.ProfFrame:IsShown() and ns.ProfRecipes then
        ns.ProfRecipes:RefreshDetail()
    end
end

function handlers.AUCTION_HOUSE_SHOW()
    if ns.AHShop then ns.AHShop:OnAHOpen() end
    if ns.AHUI then
        ns.AHUI:Show()
    end
end

function handlers.AUCTION_HOUSE_CLOSED()
    if ns.AHUI then
        ns.AHUI:Hide()
    end
end

function handlers.BAG_UPDATE_DELAYED()
    if ns.ProfFrame and ns.ProfFrame:IsShown() then
        ns.ProfFrame:OnBagUpdate()
    end
    if ns.ProfessionUI and ns.ProfessionUI:IsShown() then
        ns.ProfessionUI:RefreshMaterials()
    end
    if ns.AHUI and ns.AHUI:IsShown() then
        ns.AHUI:Refresh()
    end
    if ns.AHSell and ns.AHSell:IsShown() then
        ns.AHSell:RefreshBags()
    end
end

function handlers.TRADE_SKILL_ITEM_CRAFTED_RESULT()
    -- Decrement the queued recipe we initiated via [Craft Next]
    if ns.lastCraftedRecipeID then
        ns.Data:DecrementQueue(ns.lastCraftedRecipeID)
        ns.lastCraftedRecipeID = nil
        if ns.ProfessionUI and ns.ProfessionUI:IsShown() then
            ns.ProfessionUI:RefreshAll()
        end
    end
    if ns.ProfFrame then
        ns.ProfFrame:OnCraftComplete()
    end
end

-- Throttled refresh when item data arrives (names/icons for materials)
local itemInfoPending = false
function handlers.GET_ITEM_INFO_RECEIVED()
    if itemInfoPending then return end
    itemInfoPending = true
    C_Timer.After(0.1, function()
        itemInfoPending = false
        if ns.ProfFrame and ns.ProfFrame:IsShown() then
            ns.ProfFrame:Refresh()
        end
        if ns.ProfessionUI and ns.ProfessionUI:IsShown() then
            ns.ProfessionUI:RefreshMaterials()
        end
        if ns.AHUI and ns.AHUI:IsShown() then
            ns.AHUI:Refresh()
        end
    end)
end

--------------------------------------------------------------------
-- AH event routing
--------------------------------------------------------------------

-- Browse results → AHBrowse
function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    if ns.AHBrowse then ns.AHBrowse:OnBrowseResultsUpdated() end
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED(addedResults)
    if ns.AHBrowse then ns.AHBrowse:OnBrowseResultsAdded(addedResults) end
end

-- Commodity search results → AHShop + AHBrowse + AHSell
function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
    if ns.AHShop and ns.AHShop:IsShown() then
        ns.AHShop:OnCommoditySearchResults(itemID)
    end
    if ns.AHBrowse and ns.AHBrowse:IsShown() then
        ns.AHBrowse:OnCommoditySearchResults(itemID)
    end
    if ns.AHSell and ns.AHSell:IsShown() then
        ns.AHSell:OnCommoditySearchResults(itemID)
    end
end

-- Item search results → AHBrowse + AHSell
function handlers.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
    if ns.AHBrowse and ns.AHBrowse:IsShown() then
        ns.AHBrowse:OnItemSearchResults(itemKey)
    end
    if ns.AHSell and ns.AHSell:IsShown() then
        ns.AHSell:OnItemSearchResults(itemKey)
    end
end

-- Commodity purchase flow → AHUI confirm dialog
function handlers.COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
    if ns.AHUI then ns.AHUI:OnCommodityPriceUpdated(unitPrice, totalPrice) end
end

function handlers.COMMODITY_PRICE_UNAVAILABLE()
    if ns.AHUI then ns.AHUI:OnCommodityPriceUnavailable() end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
    if ns.AHUI then ns.AHUI:OnCommodityPurchaseSucceeded() end
end

function handlers.COMMODITY_PURCHASE_FAILED()
    if ns.AHUI then ns.AHUI:OnCommodityPurchaseFailed() end
end

-- Owned auctions / bids → AHAuctions
function handlers.OWNED_AUCTIONS_UPDATED()
    if ns.AHAuctions then ns.AHAuctions:OnOwnedAuctionsUpdated() end
end

function handlers.BIDS_UPDATED()
    if ns.AHAuctions then ns.AHAuctions:OnBidsUpdated() end
end

-- Auction created → AHSell
function handlers.AUCTION_HOUSE_AUCTION_CREATED()
    if ns.AHSell then ns.AHSell:OnAuctionCreated() end
end

-- Post warning (price confirmation) → fires StaticPopup, our hook handles it
function handlers.AUCTION_HOUSE_POST_WARNING()
    -- StaticPopup will show; our hooked OnAccept in AHSell handles confirm
end

-- Post error
function handlers.AUCTION_HOUSE_POST_ERROR()
    if ns.AHSell then ns.AHSell:SetStatus("|cffff6666Server rejected post.|r") end
end

-- Auction canceled → AHAuctions
function handlers.AUCTION_CANCELED()
    if ns.AHAuctions then ns.AHAuctions:OnAuctionCanceled() end
end

-- Throttle ready → AHShop search queue
function handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    if ns.AHShop then ns.AHShop:OnThrottleReady() end
end

-- Gold update
function handlers.PLAYER_MONEY()
    if ns.AHUI then ns.AHUI:UpdateGold() end
end

-- Register events
frame:SetScript("OnEvent", function(self, event, ...)
    if handlers[event] then
        handlers[event](...)
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
frame:RegisterEvent("TRADE_SKILL_CRAFT_BEGIN")
frame:RegisterEvent("UPDATE_TRADESKILL_CAST_STOPPED")
frame:RegisterEvent("CRAFTING_DETAILS_UPDATE")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
-- AH events
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
frame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
frame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
frame:RegisterEvent("COMMODITY_PRICE_UPDATED")
frame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
frame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
frame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
frame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
frame:RegisterEvent("BIDS_UPDATED")
frame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
frame:RegisterEvent("AUCTION_CANCELED")
frame:RegisterEvent("AUCTION_HOUSE_POST_WARNING")
frame:RegisterEvent("AUCTION_HOUSE_POST_ERROR")
frame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
frame:RegisterEvent("PLAYER_MONEY")

-- Slash commands
SLASH_KAZCRAFT1 = "/kc"
SLASH_KAZCRAFT2 = "/kazcraft"
SlashCmdList["KAZCRAFT"] = function(msg)
    msg = strtrim(msg):lower()

    if msg == "" or msg == "toggle" then
        if ns.ProfFrame and ns.ProfFrame:IsShown() then
            ns.ProfFrame:Hide()
        elseif ns.AHUI and ns.AHUI:IsShown() then
            ns.AHUI:Hide()
        else
            print("|cff" .. "c8aa64" .. "KazCraft:|r Use at a profession table or auction house.")
        end

    elseif msg == "list" or msg == "queue" then
        local queue = ns.Data:GetCharacterQueue()
        if #queue == 0 then
            print("|cffc8aa64KazCraft:|r Queue is empty.")
            return
        end
        print("|cffc8aa64KazCraft:|r Queue for " .. (ns.charKey or "?") .. ":")
        for i, entry in ipairs(queue) do
            local cached = KazCraftDB.recipeCache[entry.recipeID]
            local name = cached and cached.recipeName or ("Recipe " .. entry.recipeID)
            print(string.format("  %d. %s x%d", i, name, entry.quantity))
        end

    elseif msg == "clear" then
        ns.Data:ClearQueue()
        print("|cffc8aa64KazCraft:|r Queue cleared.")
        if ns.ProfFrame and ns.ProfFrame:IsShown() then
            ns.ProfFrame:Refresh()
        end
        if ns.ProfessionUI and ns.ProfessionUI:IsShown() then
            ns.ProfessionUI:RefreshAll()
        end

    elseif msg == "shop" or msg == "mats" then
        local mats = ns.Data:GetMaterialList()
        if #mats == 0 then
            print("|cffc8aa64KazCraft:|r No materials needed (all queues empty).")
            return
        end
        print("|cffc8aa64KazCraft:|r Shopping list (all alts):")
        for _, mat in ipairs(mats) do
            if mat.short > 0 then
                local priceStr = mat.price > 0 and (" @ " .. ns.FormatGold(mat.price)) or ""
                print(string.format("  |cffff6666%s|r x%d (have %d, need %d)%s",
                    mat.itemName, mat.short, mat.have, mat.need, priceStr))
            end
        end
        local total = ns.Data:GetTotalCost()
        if total > 0 then
            print("  Total cost: " .. ns.FormatGold(total))
        end

    elseif msg == "help" then
        print("|cffc8aa64KazCraft:|r Commands:")
        print("  /kc — toggle panel")
        print("  /kc list — show queue")
        print("  /kc clear — clear queue")
        print("  /kc shop — print shopping list")
    else
        print("|cffc8aa64KazCraft:|r Unknown command. /kc help for usage.")
    end
end
KAZ_COMMANDS["craft"] = { handler = SlashCmdList["KAZCRAFT"], alias = "/kc", desc = "Profession + AH" }
