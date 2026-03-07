local addonName, ns = ...

--------------------------------------------------------------------
-- KazWishlist: Warband crafting wishlist
-- Two wish types:
--   1. Profession gear (auto-detected: slot empty + has profession)
--   2. Consumables (manual: itemID + target qty in warband bank)
--------------------------------------------------------------------

local Wishlist = {}
ns.Wishlist = Wishlist

--------------------------------------------------------------------
-- Profession slot mapping
--------------------------------------------------------------------
-- Prof index → { tool slot, accessory slots... }
local PROF_SLOTS = {
    [1] = { 20, 21, 22 },   -- Primary 1: tool + 2 accessories
    [2] = { 23, 24, 25 },   -- Primary 2: tool + 2 accessories
    -- [3] = { 26, 27 },     -- Cooking: tool + 1 accessory (disabled)
    -- [4] = { 28 },         -- Fishing: tool only (disabled)
}

local SLOT_NAMES = {
    [20] = "Tool",  [21] = "Accessory", [22] = "Accessory",
    [23] = "Tool",  [24] = "Accessory", [25] = "Accessory",
    [26] = "Tool",  [27] = "Accessory",
    [28] = "Tool",
}

-- DataStore profession indices
local DS_PROF_INDICES = {
    Profession1 = 1,
    Profession2 = 2,
    Cooking = 3,
    Fishing = 4,
}

--------------------------------------------------------------------
-- DB helpers
--------------------------------------------------------------------
local function EnsureDB()
    if not KazCraftDB then return end
    if not KazCraftDB.wishlist then
        KazCraftDB.wishlist = {
            consumables = {},  -- { [itemID] = targetQty }
        }
    end
    if not KazCraftDB.wishlist.consumables then
        KazCraftDB.wishlist.consumables = {}
    end
end

--------------------------------------------------------------------
-- Consumable wish management
--------------------------------------------------------------------
function Wishlist:AddConsumable(itemID, qty)
    EnsureDB()
    itemID = tonumber(itemID)
    qty = tonumber(qty) or 1
    if not itemID then return end
    KazCraftDB.wishlist.consumables[itemID] = qty
    local name = C_Item.GetItemNameByID(itemID) or ("Item " .. itemID)
    print("|cffc8aa64KazWish:|r Added " .. name .. " x" .. qty .. " to wishlist")
end

function Wishlist:RemoveConsumable(itemID)
    EnsureDB()
    itemID = tonumber(itemID)
    if not itemID then return end
    local name = C_Item.GetItemNameByID(itemID) or ("Item " .. itemID)
    KazCraftDB.wishlist.consumables[itemID] = nil
    print("|cffc8aa64KazWish:|r Removed " .. name .. " from wishlist")
end

function Wishlist:AddFromLink(link, qty)
    if not link then return false end
    local itemID = link:match("item:(%d+)")
    if not itemID then return false end
    self:AddConsumable(tonumber(itemID), qty)
    return true
end

--------------------------------------------------------------------
-- Count item in warband bank (live scan)
--------------------------------------------------------------------
local function CountInWarbandBank(itemID)
    local total = 0
    local tabIDs = C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Account)
    if not tabIDs then return 0 end
    for _, tabID in ipairs(tabIDs) do
        local numSlots = C_Container.GetContainerNumSlots(tabID)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(tabID, slot)
            if info and info.itemID == itemID then
                total = total + (info.stackCount or 1)
            end
        end
    end
    return total
end

--------------------------------------------------------------------
-- Count item in warband bank via DataStore (offline)
--------------------------------------------------------------------
local function CountInWarbandBankDS(itemID)
    if not DataStore or not DataStore.GetAccountBankTabItemCount then return 0 end
    local total = 0
    for tabID = 1, 5 do
        total = total + (DataStore:GetAccountBankTabItemCount(tabID, itemID) or 0)
    end
    return total
end

--------------------------------------------------------------------
-- Scan all characters for profession gear needs
--------------------------------------------------------------------
function Wishlist:ScanProfessionGear()
    local needs = {}  -- { { charName, charKey, profession, slotID, slotName } }

    if not DataStore then
        -- Fallback: current character only
        self:ScanCurrentCharGear(needs)
        return needs
    end

    -- Iterate all characters across all realms
    for account in pairs(DataStore:GetAccounts() or {}) do
        for realm in pairs(DataStore:GetRealms(account) or {}) do
            for charName, charKey in pairs(DataStore:GetCharacters(realm, account) or {}) do
                self:ScanCharGear(charKey, charName, needs)
            end
        end
    end

    return needs
end

function Wishlist:ScanCharGear(charKey, charName, needs)
    if not DataStore or not DataStore.GetProfessions then return end
    if not DataStore.GetInventoryItem then return end

    local profs = DataStore:GetProfessions(charKey)
    if not profs then return end

    for dsIdx, slots in pairs(PROF_SLOTS) do
        local prof = profs[dsIdx]
        if prof and prof.Name then
            for _, slotID in ipairs(slots) do
                -- GetInventoryItem returns itemID (number) or itemLink (string), or nil
                local item = DataStore:GetInventoryItem(charKey, slotID)
                if not item then
                    needs[#needs + 1] = {
                        charName = charName,
                        charKey = charKey,
                        profession = prof.Name,
                        slotID = slotID,
                        slotName = SLOT_NAMES[slotID] or "Unknown",
                        classColor = DataStore:GetCharacterClassColor(charKey),
                    }
                end
            end
        end
    end
end

function Wishlist:ScanCurrentCharGear(needs)
    local charName = UnitName("player")
    local charKey = ns.charKey

    -- Check profession slots via GetInventoryItemID
    for dsIdx, slots in pairs(PROF_SLOTS) do
        -- Check if we have this profession
        local hasProfession = false
        local profName = "Unknown"

        if dsIdx <= 2 then
            local prof1, prof2 = GetProfessions()
            local profID = dsIdx == 1 and prof1 or prof2
            if profID then
                local name = GetProfessionInfo(profID)
                profName = name
                hasProfession = true
            end
        end

        if hasProfession then
            for _, slotID in ipairs(slots) do
                local itemID = GetInventoryItemID("player", slotID)
                if not itemID then
                    local _, classFile = UnitClass("player")
                    local color = RAID_CLASS_COLORS[classFile]
                    local colorStr = color and color:GenerateHexColorMarkup() or "|cffffffff"
                    needs[#needs + 1] = {
                        charName = charName,
                        charKey = charKey,
                        profession = profName,
                        slotID = slotID,
                        slotName = SLOT_NAMES[slotID] or "Unknown",
                        classColor = colorStr,
                    }
                end
            end
        end
    end
end

--------------------------------------------------------------------
-- Scan consumable wishes
--------------------------------------------------------------------
function Wishlist:ScanConsumables()
    EnsureDB()
    local results = {}  -- { { itemID, itemName, icon, target, have, need } }

    for itemID, targetQty in pairs(KazCraftDB.wishlist.consumables) do
        -- Check warband bank (live if at bank, DataStore otherwise)
        local have
        local bankOpen = ns.bankOpen or (C_Bank and C_Bank.IsOpen and C_Bank.IsOpen())
        if bankOpen then
            have = CountInWarbandBank(itemID)
        else
            have = CountInWarbandBankDS(itemID)
        end

        local need = math.max(0, targetQty - have)
        local name = C_Item.GetItemNameByID(itemID) or ("Item " .. itemID)
        local icon = C_Item.GetItemIconByID(itemID)

        results[#results + 1] = {
            itemID = itemID,
            itemName = name,
            icon = icon,
            target = targetQty,
            have = have,
            need = need,
        }
    end

    -- Sort: needs first, then alphabetical
    table.sort(results, function(a, b)
        if (a.need > 0) ~= (b.need > 0) then
            return a.need > 0
        end
        return a.itemName < b.itemName
    end)

    return results
end

--------------------------------------------------------------------
-- Check what current character can craft from the wish list
--------------------------------------------------------------------
function Wishlist:GetCraftableWishes()
    if not ns.itemToRecipe then return {} end

    local craftable = {}
    local consumables = self:ScanConsumables()

    for _, wish in ipairs(consumables) do
        if wish.need > 0 then
            local recipeID = ns.itemToRecipe[wish.itemID]
            if recipeID then
                local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
                if recipeInfo and recipeInfo.learned then
                    wish.recipeID = recipeID
                    wish.recipeName = recipeInfo.name
                    craftable[#craftable + 1] = wish
                end
            end
        end
    end

    return craftable
end

--------------------------------------------------------------------
-- Slot type mapping for profession gear matching
--------------------------------------------------------------------
local TOOL_SLOTS = { [20] = true, [23] = true, [26] = true, [28] = true }
-- Accessories = everything else (21, 22, 24, 25, 27)

-- Map profession name → subclassID for ItemClass.Profession (19)
-- Used to match "this recipe outputs a Mining tool" to "Jengri needs a Mining Tool"
local PROF_SUBCLASS = {}
-- Built lazily on first use since Enum values may not be available at load

local function GetProfSubclass()
    if next(PROF_SUBCLASS) then return PROF_SUBCLASS end
    -- Enum.ItemProfessionSubclass (Retail 12.0)
    -- These map profession names to the item subclass that filters profession gear
    PROF_SUBCLASS["Blacksmithing"] = 0
    PROF_SUBCLASS["Leatherworking"] = 1
    PROF_SUBCLASS["Alchemy"] = 2
    PROF_SUBCLASS["Herbalism"] = 3
    PROF_SUBCLASS["Cooking"] = 4
    PROF_SUBCLASS["Mining"] = 5
    PROF_SUBCLASS["Tailoring"] = 6
    PROF_SUBCLASS["Engineering"] = 7
    PROF_SUBCLASS["Enchanting"] = 8
    PROF_SUBCLASS["Fishing"] = 9
    PROF_SUBCLASS["Skinning"] = 10
    PROF_SUBCLASS["Jewelcrafting"] = 11
    PROF_SUBCLASS["Inscription"] = 12
    return PROF_SUBCLASS
end

--------------------------------------------------------------------
-- Find craftable recipes for gear wishes
--------------------------------------------------------------------
function Wishlist:FindGearRecipes(gearNeeds)
    if not C_TradeSkillUI.IsTradeSkillReady() then return {} end

    -- Build index of what's needed: { [profession..slotType] = { need1, need2, ... } }
    local needed = {}
    for _, need in ipairs(gearNeeds) do
        local isTool = TOOL_SLOTS[need.slotID]
        local key = need.profession .. (isTool and ":tool" or ":acc")
        if not needed[key] then needed[key] = {} end
        needed[key][#needed[key] + 1] = need
    end

    -- Scan all known recipes for profession gear
    local results = {}  -- { { recipeID, recipeName, qty, needs = {...} } }
    local seen = {}  -- deduplicate by profession+slotType

    local allRecipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if not allRecipeIDs then return {} end

    for _, recipeID in ipairs(allRecipeIDs) do
        local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if recipeInfo and recipeInfo.learned then
            -- Check if output is profession gear
            local outputItemID = nil
            local cached = KazCraftDB.recipeCache and KazCraftDB.recipeCache[recipeID]
            if cached then
                outputItemID = cached.outputItemID
            else
                -- Try to get from schematic
                local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
                if schematic then outputItemID = schematic.outputItemID end
            end

            if outputItemID then
                local _, _, _, _, _, _, _, _, equipSlot, _, _, classID, subclassID = GetItemInfo(outputItemID)
                if classID == Enum.ItemClass.Profession then
                    local isTool = (equipSlot == "INVTYPE_PROFESSION_TOOL")
                    local isAcc = (equipSlot == "INVTYPE_PROFESSION_GEAR" or equipSlot == "INVTYPE_PROFESSION_ACCESSORY")

                    if isTool or isAcc then
                        -- Match profession by subclass
                        local profSubclasses = GetProfSubclass()
                        for profName, subID in pairs(profSubclasses) do
                            if subclassID == subID then
                                local slotType = isTool and "tool" or "acc"
                                local key = profName .. ":" .. slotType
                                if needed[key] and not seen[key] then
                                    seen[key] = true
                                    results[#results + 1] = {
                                        recipeID = recipeID,
                                        recipeName = recipeInfo.name,
                                        qty = #needed[key],
                                        needs = needed[key],
                                        profession = profName,
                                        slotType = slotType,
                                    }
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    return results
end

--------------------------------------------------------------------
-- Queue all craftable wishes into KazCraft queue
--------------------------------------------------------------------
function Wishlist:QueueCraftable()
    local queued = 0

    -- Gear wishes
    local gearNeeds = self:ScanProfessionGear()
    if #gearNeeds > 0 and C_TradeSkillUI.IsTradeSkillReady() then
        local gearRecipes = self:FindGearRecipes(gearNeeds)
        for _, entry in ipairs(gearRecipes) do
            ns.Data:AddToQueue(entry.recipeID, entry.qty)
            print(string.format("|cffc8aa64KazWish:|r Queued %s x%d (%s %s)",
                entry.recipeName, entry.qty, entry.profession,
                entry.slotType == "tool" and "Tool" or "Accessory"))
            queued = queued + entry.qty
        end
    end

    -- Consumable wishes
    local consumables = self:ScanConsumables()
    if ns.itemToRecipe then
        for _, wish in ipairs(consumables) do
            if wish.need > 0 then
                local recipeID = ns.itemToRecipe[wish.itemID]
                if recipeID then
                    local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
                    if recipeInfo and recipeInfo.learned then
                        ns.Data:AddToQueue(recipeID, wish.need)
                        print(string.format("|cffc8aa64KazWish:|r Queued %s x%d",
                            wish.itemName, wish.need))
                        queued = queued + wish.need
                    end
                end
            end
        end
    end

    if queued == 0 then
        print("|cffc8aa64KazWish:|r Nothing to queue — open a profession first for gear, or add consumables.")
    else
        print(string.format("|cffc8aa64KazWish:|r Queued %d items into KazCraft.", queued))
    end

    return queued
end

--------------------------------------------------------------------
-- Login announcement: what can you craft that someone needs?
--------------------------------------------------------------------
function Wishlist:AnnounceOnLogin()
    EnsureDB()

    -- Profession gear needs
    local gearNeeds = self:ScanProfessionGear()
    if #gearNeeds > 0 then
        local gearCount = #gearNeeds
        print("|cffc8aa64KazWish:|r " .. gearCount .. " profession gear slot" ..
            (gearCount > 1 and "s" or "") .. " empty across your characters. /kaz wish to view.")
    end

    -- Consumable needs
    local consumables = self:ScanConsumables()
    local needCount = 0
    for _, c in ipairs(consumables) do
        if c.need > 0 then needCount = needCount + 1 end
    end
    if needCount > 0 then
        print("|cffc8aa64KazWish:|r " .. needCount .. " consumable" ..
            (needCount > 1 and "s" or "") .. " below target. /kaz wish to view.")
    end
end

--------------------------------------------------------------------
-- Slash command handler
--------------------------------------------------------------------
function Wishlist:HandleSlashCommand(msg)
    msg = strtrim(msg or ""):lower()

    if msg == "" or msg == "list" then
        -- Toggle the UI
        if ns.WishlistUI then
            ns.WishlistUI:Toggle()
        end

    elseif msg:find("^add ") then
        -- /kaz wish add [item link] [qty]
        local link = msg:match("|c.-|h|r") or msg:match("|Hitem:.-|h.-|h")
        local qty = tonumber(msg:match("(%d+)%s*$"))
        if link then
            self:AddFromLink(link, qty)
        else
            print("|cffc8aa64KazWish:|r Drag an item or paste a link: /kaz wish add [item] [qty]")
        end

    elseif msg:find("^remove ") then
        local idStr = msg:match("^remove%s+(%d+)")
        if idStr then
            self:RemoveConsumable(tonumber(idStr))
        else
            print("|cffc8aa64KazWish:|r Usage: /kaz wish remove <itemID>")
        end

    elseif msg == "scan" or msg == "check" then
        local gearNeeds = self:ScanProfessionGear()
        if #gearNeeds == 0 then
            print("|cffc8aa64KazWish:|r All characters have profession gear equipped.")
        else
            print("|cffc8aa64KazWish:|r Empty profession gear slots:")
            for _, need in ipairs(gearNeeds) do
                local color = need.classColor or "|cffffffff"
                print(string.format("  %s%s|r — %s %s",
                    color, need.charName, need.profession, need.slotName))
            end
        end

        local consumables = self:ScanConsumables()
        local anyNeeded = false
        for _, c in ipairs(consumables) do
            if c.need > 0 then
                if not anyNeeded then
                    print("|cffc8aa64KazWish:|r Consumables below target:")
                    anyNeeded = true
                end
                print(string.format("  %s — have %d / %d (need %d)",
                    c.itemName, c.have, c.target, c.need))
            end
        end
        if not anyNeeded and next(KazCraftDB.wishlist.consumables) then
            print("|cffc8aa64KazWish:|r All consumables at target.")
        end

    elseif msg == "queue" then
        self:QueueCraftable()

    elseif msg == "help" then
        print("|cffc8aa64KazWish:|r Commands:")
        print("  /kaz wish — open wishlist window")
        print("  /kaz wish scan — print needs to chat")
        print("  /kaz wish queue — queue craftable items into KazCraft")
        print("  /kaz wish add [link] [qty] — add consumable")
        print("  /kaz wish remove [itemID] — remove consumable")

    else
        print("|cffc8aa64KazWish:|r Unknown command. /kaz wish help")
    end
end
