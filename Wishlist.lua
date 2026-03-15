local addonName, ns = ...

--------------------------------------------------------------------
-- KazWishlist: Warband crafting wishlist
-- Two wish types:
--   1. Profession gear (auto-detected: slot empty + has profession)
--   2. Consumables (manual: itemID + target qty in warband bank)
--------------------------------------------------------------------

local Wishlist = {}
ns.Wishlist = Wishlist

-- Separate debug printer so /kaz dbg kazwish (or /kaz dbg wish) works
local WishPrint, WishDebug
if KazUtil and KazUtil.CreatePrinter then
    WishPrint, WishDebug = KazUtil.CreatePrinter("KazWish")
else
    WishPrint = function() end
    WishDebug = function() end
end

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
-- Expansion constant
--------------------------------------------------------------------
-- GetItemInfo expacID: Classic=0, TBC=1, ..., DF=9, TWW=10, Midnight=11
local CURRENT_EXPAC_ID = 11

--------------------------------------------------------------------
-- Quality constants
--------------------------------------------------------------------
local QUALITY_GREEN = 2   -- Uncommon
local QUALITY_BLUE  = 3   -- Rare
local QUALITY_EPIC  = 4   -- Epic

local QUALITY_NAMES = {
    [QUALITY_GREEN] = "Green",
    [QUALITY_BLUE]  = "Blue",
    [QUALITY_EPIC]  = "Epic",
}

local QUALITY_COLORS = {
    [QUALITY_GREEN] = "|cff1eff00",
    [QUALITY_BLUE]  = "|cff0070dd",
    [QUALITY_EPIC]  = "|cffa335ee",
}

--------------------------------------------------------------------
-- Gear plan states
--------------------------------------------------------------------
local STATE_EMPTY   = "empty"    -- No gear in slot, need base craft
local STATE_UPGRADE = "upgrade"  -- Have gear, can upgrade quality (recraft)
local STATE_QUEUED  = "queued"   -- Already in a character's craft queue
local STATE_READY   = "ready"    -- Have mats, ready to craft
local STATE_BLOCKED = "blocked"  -- Missing mats or no known crafter

local STATE_COLORS = {
    [STATE_EMPTY]   = "|cff808080",  -- Gray
    [STATE_UPGRADE] = "|cffffcc00",  -- Yellow
    [STATE_QUEUED]  = "|cff4499ff",  -- Blue
    [STATE_READY]   = "|cff00ff00",  -- Green
    [STATE_BLOCKED] = "|cffff6666",  -- Red
}

local STATE_LABELS = {
    [STATE_EMPTY]   = "Need base craft",
    [STATE_UPGRADE] = "Upgradeable",
    [STATE_QUEUED]  = "Queued",
    [STATE_READY]   = "Ready to craft",
    [STATE_BLOCKED] = "Blocked",
}

--------------------------------------------------------------------
-- DB helpers
--------------------------------------------------------------------
local function EnsureDB()
    if not KazCraftDB then return end
    if not KazCraftDB.wishlist then
        KazCraftDB.wishlist = {
            consumables = {},  -- { [itemID] = targetQty }
            targetQuality = QUALITY_GREEN,
        }
    end
    if not KazCraftDB.wishlist.consumables then
        KazCraftDB.wishlist.consumables = {}
    end
    if not KazCraftDB.wishlist.targetQuality then
        KazCraftDB.wishlist.targetQuality = QUALITY_GREEN
    end
    if not KazCraftDB.wishlist.gearPlans then
        KazCraftDB.wishlist.gearPlans = {}
    end
end

function Wishlist:GetTargetQuality()
    EnsureDB()
    return KazCraftDB.wishlist.targetQuality
end

function Wishlist:SetTargetQuality(quality)
    EnsureDB()
    KazCraftDB.wishlist.targetQuality = quality
end

function Wishlist:GetQualityName(quality)
    return QUALITY_NAMES[quality] or "Unknown"
end

function Wishlist:GetQualityColor(quality)
    return QUALITY_COLORS[quality] or "|cffffffff"
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
-- Gear plan management
--------------------------------------------------------------------

-- Set a gear plan for a character's slot
function Wishlist:SetGearPlan(charKey, slotID, targetItemID, targetQuality)
    EnsureDB()
    KazCraftDB.wishlist.gearPlans[charKey] = KazCraftDB.wishlist.gearPlans[charKey] or {}
    KazCraftDB.wishlist.gearPlans[charKey][slotID] = {
        targetItemID = targetItemID,
        targetQuality = targetQuality or QUALITY_EPIC,
        state = STATE_EMPTY,
        queuedTo = nil,
        queuedRecipeID = nil,
    }
end

-- Remove a gear plan
function Wishlist:RemoveGearPlan(charKey, slotID)
    EnsureDB()
    if KazCraftDB.wishlist.gearPlans[charKey] then
        KazCraftDB.wishlist.gearPlans[charKey][slotID] = nil
        if not next(KazCraftDB.wishlist.gearPlans[charKey]) then
            KazCraftDB.wishlist.gearPlans[charKey] = nil
        end
    end
end

-- Get a gear plan entry
function Wishlist:GetGearPlan(charKey, slotID)
    EnsureDB()
    return KazCraftDB.wishlist.gearPlans[charKey]
        and KazCraftDB.wishlist.gearPlans[charKey][slotID]
end

-- Evaluate current state of a gear plan entry
function Wishlist:EvaluateGearPlanState(charKey, slotID)
    local plan = self:GetGearPlan(charKey, slotID)
    if not plan then return nil end

    -- Check current equipment in slot
    local currentQuality = 0
    local currentItemID = nil
    if DataStore and DataStore.GetInventoryItem then
        local charName, realm = charKey:match("^(.-)%-(.+)$")
        if charName and realm then
            -- Find DS key
            for account in pairs(DataStore:GetAccounts() or {}) do
                local dsKey = account .. "." .. realm .. "." .. charName
                local item = DataStore:GetInventoryItem(dsKey, slotID)
                if item then
                    currentItemID = type(item) == "number" and item or nil
                    local link = type(item) == "string" and item or nil
                    if link then
                        currentQuality = select(3, C_Item.GetItemInfo(link)) or 0
                    elseif currentItemID then
                        currentQuality = C_Item.GetItemQualityByID(currentItemID) or 0
                    end
                    break
                end
            end
        end
    end

    -- If already queued, keep queued state unless queue entry is gone
    if plan.state == STATE_QUEUED and plan.queuedTo then
        local queue = ns.Data:GetCharacterQueue(plan.queuedTo)
        local stillQueued = false
        for _, entry in ipairs(queue) do
            if entry.recipeID == plan.queuedRecipeID then
                stillQueued = true
                break
            end
        end
        if stillQueued then return STATE_QUEUED end
        -- Queue entry gone — re-evaluate
        plan.queuedTo = nil
        plan.queuedRecipeID = nil
    end

    -- Already at target?
    if currentQuality >= plan.targetQuality then
        return "complete"
    end

    -- Find recipe for target item
    local recipeID = plan.targetItemID and ns.itemToRecipe and ns.itemToRecipe[plan.targetItemID]
    if not recipeID then
        plan.state = STATE_BLOCKED
        return STATE_BLOCKED
    end

    -- Anyone know the recipe?
    local cached = KazCraftDB.recipeCache[recipeID]
    if not cached or not cached.knownBy or not next(cached.knownBy) then
        plan.state = STATE_BLOCKED
        return STATE_BLOCKED
    end

    -- Determine if empty or upgrade
    if currentQuality == 0 then
        plan.state = STATE_EMPTY
    else
        plan.state = STATE_UPGRADE
    end

    return plan.state
end

-- Get all gear plans with current state, flattened for display
function Wishlist:GetAllGearPlans()
    EnsureDB()
    local results = {}

    for charKey, slots in pairs(KazCraftDB.wishlist.gearPlans) do
        local charName, realm = charKey:match("^(.-)%-(.+)$")
        local classColor = nil

        if DataStore and DataStore.GetCharacterClassColor then
            for account in pairs(DataStore:GetAccounts() or {}) do
                local dsKey = account .. "." .. realm .. "." .. charName
                local ok, color = pcall(DataStore.GetCharacterClassColor, DataStore, dsKey)
                if ok and color then
                    classColor = color
                    break
                end
            end
        end

        for slotID, plan in pairs(slots) do
            local state = self:EvaluateGearPlanState(charKey, slotID)
            if state ~= "complete" then
                local itemName = plan.targetItemID and
                    (C_Item.GetItemNameByID(plan.targetItemID) or ("Item " .. plan.targetItemID)) or "?"
                results[#results + 1] = {
                    charKey = charKey,
                    charName = charName or charKey,
                    classColor = classColor,
                    slotID = slotID,
                    slotName = SLOT_NAMES[slotID] or ("Slot " .. slotID),
                    targetItemID = plan.targetItemID,
                    targetQuality = plan.targetQuality,
                    state = state,
                    stateColor = STATE_COLORS[state] or "|cffffffff",
                    stateLabel = STATE_LABELS[state] or state,
                    queuedTo = plan.queuedTo,
                    plan = plan,
                }
            end
        end
    end

    -- Sort: blocked first, then empty, upgrade, queued, ready
    local stateOrder = { [STATE_BLOCKED]=1, [STATE_EMPTY]=2, [STATE_UPGRADE]=3, [STATE_QUEUED]=4, [STATE_READY]=5 }
    table.sort(results, function(a, b)
        local oa, ob = stateOrder[a.state] or 99, stateOrder[b.state] or 99
        if oa ~= ob then return oa < ob end
        if a.charName ~= b.charName then return a.charName < b.charName end
        return a.slotID < b.slotID
    end)

    return results
end

-- Queue a gear plan item to the best crafter
function Wishlist:QueueGearPlan(charKey, slotID)
    local plan = self:GetGearPlan(charKey, slotID)
    if not plan then return false, "No plan" end

    local recipeID = plan.targetItemID and ns.itemToRecipe and ns.itemToRecipe[plan.targetItemID]
    if not recipeID then return false, "No recipe found" end

    local crafter, skill = ns.Data:GetBestCrafter(recipeID)
    if not crafter then return false, "No known crafter" end

    -- Queue to the best crafter (not current character)
    ns.Data:AddToQueue(recipeID, 1, crafter)

    -- Update plan state
    plan.state = STATE_QUEUED
    plan.queuedTo = crafter
    plan.queuedRecipeID = recipeID

    local skillStr = skill and (" (skill " .. skill .. ")") or ""
    local cached = KazCraftDB.recipeCache[recipeID]
    local recipeName = cached and cached.recipeName or ("Recipe " .. recipeID)
    print(string.format("|cffc8aa64KazWish:|r Queued %s to %s%s",
        recipeName, crafter, skillStr))

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
    local targetQ = self:GetTargetQuality()

    for dsIdx, slots in pairs(PROF_SLOTS) do
        local prof = profs[dsIdx]
        if prof and prof.Name then
            for _, slotID in ipairs(slots) do
                -- GetInventoryItem returns itemID (number) or itemLink (string), or nil
                local item = DataStore:GetInventoryItem(charKey, slotID)
                local currentQuality = 0
                local currentItemName = nil
                local currentItemLink = nil
                local isCurrentExpac = false
                if item then
                    local link = type(item) == "string" and item or nil
                    if link then
                        currentItemLink = link
                        local name, _, quality, _, _, _, _, _, _, _, _, _, _, _, expacID = C_Item.GetItemInfo(link)
                        currentItemName = name
                        currentQuality = quality or 0
                        -- Midnight = expansion 11 (12.0). TWW = 10, DF = 9, etc.
                        isCurrentExpac = expacID and expacID >= CURRENT_EXPAC_ID
                    else
                        currentQuality = C_Item.GetItemQualityByID(item) or 0
                        currentItemName = C_Item.GetItemNameByID(item)
                    end
                end

                -- Needs gear if: empty, outdated expansion, or below target quality
                local needsGear = (currentQuality == 0)
                    or (not isCurrentExpac)
                    or (currentQuality < targetQ)

                if needsGear then
                    needs[#needs + 1] = {
                        charName = charName,
                        charKey = charKey,
                        profession = prof.Name,
                        slotID = slotID,
                        slotName = SLOT_NAMES[slotID] or "Unknown",
                        classColor = DataStore:GetCharacterClassColor(charKey),
                        currentQuality = currentQuality,
                        currentItemName = currentItemName,
                        currentItemLink = currentItemLink,
                        outdated = (currentQuality > 0 and not isCurrentExpac),
                    }
                end
            end
        end
    end
end

function Wishlist:ScanCurrentCharGear(needs)
    local charName = UnitName("player")
    local charKey = ns.charKey
    local targetQ = self:GetTargetQuality()

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
                local currentQuality = 0
                local currentItemName = nil
                local currentItemLink = nil
                local isCurrentExpac = false
                if itemID then
                    local link = GetInventoryItemLink("player", slotID)
                    if link then
                        currentItemLink = link
                        local name, _, quality, _, _, _, _, _, _, _, _, _, _, _, expacID = C_Item.GetItemInfo(link)
                        currentItemName = name
                        currentQuality = quality or 0
                        isCurrentExpac = expacID and expacID >= CURRENT_EXPAC_ID
                    else
                        currentQuality = C_Item.GetItemQualityByID(itemID) or 0
                        currentItemName = C_Item.GetItemNameByID(itemID)
                    end
                end

                local needsGear = (currentQuality == 0)
                    or (not isCurrentExpac)
                    or (currentQuality < targetQ)

                if needsGear then
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
                        currentQuality = currentQuality,
                        currentItemName = currentItemName,
                        currentItemLink = currentItemLink,
                        outdated = (currentQuality > 0 and not isCurrentExpac),
                    }
                end
            end
        end
    end
end

--------------------------------------------------------------------
-- Slot type mapping for profession gear matching
--------------------------------------------------------------------
local TOOL_SLOTS = { [20] = true, [23] = true, [26] = true, [28] = true }
-- Accessories = everything else (21, 22, 24, 25, 27)

-- Map profession name → subclassID for ItemClass.Profession (19)
local PROF_SUBCLASS = {}

local function GetProfSubclass()
    if next(PROF_SUBCLASS) then return PROF_SUBCLASS end
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
-- Enrich gear needs with crafter info from recipeCache
-- Works offline — no profession window required
--------------------------------------------------------------------
function Wishlist:EnrichNeedsWithCrafters(needs)
    local profSubclasses = GetProfSubclass()
    local subclassToProf = {}
    for profName, subID in pairs(profSubclasses) do
        subclassToProf[subID] = profName
    end

    -- Build gear recipe lookup: { ["Mining:tool"] = { {recipeID, recipeName, knownBy, crafterProf}, ... } }
    -- Key is the TARGET profession (what the gear is FOR), not the crafter's profession
    local gearRecipes = {}
    local gearRecipeCount = 0
    local totalRecipes = 0
    local profGearRecipes = 0
    for recipeID, cached in pairs(KazCraftDB.recipeCache or {}) do
        totalRecipes = totalRecipes + 1
        if cached.outputItemID then
            local _, _, _, equipSlot, _, classID, subclassID = C_Item.GetItemInfoInstant(cached.outputItemID)
            if classID == Enum.ItemClass.Profession and subclassID then
                profGearRecipes = profGearRecipes + 1
                local targetProf = subclassToProf[subclassID]
                if targetProf then
                    local isTool = (equipSlot == "INVTYPE_PROFESSION_TOOL")
                    local isAcc = (equipSlot == "INVTYPE_PROFESSION_GEAR" or equipSlot == "INVTYPE_PROFESSION_ACCESSORY")
                    if isTool or isAcc then
                        local key = targetProf .. ":" .. (isTool and "tool" or "acc")
                        if not gearRecipes[key] then gearRecipes[key] = {} end
                        gearRecipes[key][#gearRecipes[key] + 1] = {
                            recipeID = recipeID,
                            recipeName = cached.recipeName,
                            knownBy = cached.knownBy or {},
                            crafterProf = cached.professionName or "",
                        }
                        gearRecipeCount = gearRecipeCount + 1
                    end
                end
            end
        end
    end

    WishDebug("EnrichNeedsWithCrafters:", totalRecipes, "total recipes,", profGearRecipes, "profession gear,", gearRecipeCount, "with knownBy")

    -- If zero crafters tagged, force a DataStore rescan
    if gearRecipeCount == 0 and profGearRecipes > 0 then
        WishDebug("All profession gear recipes have empty knownBy — forcing ScanKnownRecipes")
        ns.Data:ScanKnownRecipes()
        -- Rebuild after rescan
        gearRecipeCount = 0
        for key in pairs(gearRecipes) do gearRecipes[key] = nil end
        for recipeID, cached in pairs(KazCraftDB.recipeCache or {}) do
            if cached.outputItemID then
                local _, _, _, equipSlot, _, classID, subclassID = C_Item.GetItemInfoInstant(cached.outputItemID)
                if classID == Enum.ItemClass.Profession and subclassID then
                    local targetProf = subclassToProf[subclassID]
                    if targetProf then
                        local isTool = (equipSlot == "INVTYPE_PROFESSION_TOOL")
                        local isAcc = (equipSlot == "INVTYPE_PROFESSION_GEAR" or equipSlot == "INVTYPE_PROFESSION_ACCESSORY")
                        if isTool or isAcc then
                            local hasKnownBy = cached.knownBy and next(cached.knownBy)
                            if hasKnownBy then
                                local key = targetProf .. ":" .. (isTool and "tool" or "acc")
                                if not gearRecipes[key] then gearRecipes[key] = {} end
                                gearRecipes[key][#gearRecipes[key] + 1] = {
                                    recipeID = recipeID,
                                    recipeName = cached.recipeName,
                                    knownBy = cached.knownBy,
                                    crafterProf = cached.professionName or "",
                                }
                                gearRecipeCount = gearRecipeCount + 1
                            end
                        end
                    end
                end
            end
        end
        WishDebug("After rescan:", gearRecipeCount, "recipes with knownBy")
    end

    for key, recipes in pairs(gearRecipes) do
        local crafterCount = 0
        for _, r in ipairs(recipes) do
            for _ in pairs(r.knownBy) do crafterCount = crafterCount + 1 end
        end
        WishDebug("  ", key, ":", #recipes, "recipes,", crafterCount, "crafter entries")
    end

    -- Build profession → character lookup from DataStore (fallback when knownBy is empty)
    local profCrafters = {}  -- { ["Engineering"] = { "Shuwa-Blackrock", ... } }
    if DataStore and DataStore.GetProfession1 then
        for account in pairs(DataStore:GetAccounts() or {}) do
            for realm in pairs(DataStore:GetRealms(account) or {}) do
                for charName, dsKey in pairs(DataStore:GetCharacters(realm, account) or {}) do
                    local kazKey = charName .. "-" .. realm
                    for i = 1, 2 do
                        local _, _, _, profName
                        if i == 1 then
                            _, _, _, profName = DataStore:GetProfession1(dsKey)
                        else
                            _, _, _, profName = DataStore:GetProfession2(dsKey)
                        end
                        if profName then
                            if not profCrafters[profName] then profCrafters[profName] = {} end
                            profCrafters[profName][#profCrafters[profName] + 1] = kazKey
                        end
                    end
                end
            end
        end
    end

    -- Enrich each need
    local skills = KazCraftDB.professionSkills or {}
    for _, need in ipairs(needs) do
        local isTool = TOOL_SLOTS[need.slotID]
        local key = need.profession .. ":" .. (isTool and "tool" or "acc")
        local recipes = gearRecipes[key]

        if recipes then
            -- Collect crafters: prefer knownBy, fall back to profession lookup
            local crafterSet = {}
            local crafterProfName = recipes[1].crafterProf
            for _, recipe in ipairs(recipes) do
                for charKey in pairs(recipe.knownBy) do
                    crafterSet[charKey] = true
                end
            end

            -- Fallback: if knownBy is empty, find anyone with the crafter profession
            if not next(crafterSet) and crafterProfName and profCrafters[crafterProfName] then
                for _, charKey in ipairs(profCrafters[crafterProfName]) do
                    crafterSet[charKey] = true
                end
            end

            -- Find best crafter — use the CRAFTER'S profession skill, not the target profession
            local bestCrafter = nil
            local bestSkill = -1
            local crafterNames = {}
            for charKey in pairs(crafterSet) do
                local cName = charKey:match("^(.-)%-") or charKey
                local charSkills = skills[charKey]
                local skill = charSkills and charSkills[crafterProfName] or 0
                crafterNames[#crafterNames + 1] = cName .. (skill > 0 and (" (" .. skill .. ")") or "")
                if skill > bestSkill then
                    bestSkill = skill
                    bestCrafter = charKey
                end
            end

            need.craftable = true
            need.crafterText = table.concat(crafterNames, ", ")
            need.bestCrafter = bestCrafter
            need.bestCrafterSkill = bestSkill > 0 and bestSkill or nil
            need.recipeID = recipes[1].recipeID
        else
            need.craftable = false
            need.crafterText = nil
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
-- Build set of profession:slotType combos the current toon can craft
-- Scans learned recipes in the current expansion's skill line
--------------------------------------------------------------------
function Wishlist:GetCraftableGearSlots()
    local result = {}

    local profSubclasses = GetProfSubclass()
    local subclassToProf = {}
    for profName, subID in pairs(profSubclasses) do
        subclassToProf[subID] = profName
    end

    -- Filter to current expansion — require valid profession data
    local childProfInfo = C_TradeSkillUI.GetChildProfessionInfo()
    local childProfID = childProfInfo and childProfInfo.professionID
    if not childProfID or childProfID == 0 then
        return result
    end

    local allRecipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if allRecipeIDs then
        for _, recipeID in ipairs(allRecipeIDs) do
            local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
            if recipeInfo and recipeInfo.learned
                and (not childProfID or C_TradeSkillUI.IsRecipeInSkillLine(recipeID, childProfID)) then
                local outputItemID = nil
                local cached = KazCraftDB and KazCraftDB.recipeCache and KazCraftDB.recipeCache[recipeID]
                if cached then
                    outputItemID = cached.outputItemID
                else
                    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
                    if schematic then outputItemID = schematic.outputItemID end
                end

                if outputItemID then
                    local _, _, _, equipSlot, _, classID, subclassID = C_Item.GetItemInfoInstant(outputItemID)
                    if classID == Enum.ItemClass.Profession and subclassID then
                        local profName = subclassToProf[subclassID]
                        if profName then
                            local isTool = (equipSlot == "INVTYPE_PROFESSION_TOOL")
                            local isAcc = (equipSlot == "INVTYPE_PROFESSION_GEAR" or equipSlot == "INVTYPE_PROFESSION_ACCESSORY")
                            if isTool then
                                result[profName .. ":tool"] = true
                            elseif isAcc then
                                result[profName .. ":acc"] = true
                            end
                        end
                    end
                end
            end
        end
    end

    WishDebug("KazWish craftable slots:")
    for k in pairs(result) do
        WishDebug("  ", k)
    end

    return result
end

--------------------------------------------------------------------
-- Scan all chars but filter to gear the current toon can craft
--------------------------------------------------------------------
function Wishlist:ScanCraftableGearNeeds()
    local allNeeds = self:ScanProfessionGear()
    local craftable = self:GetCraftableGearSlots()

    -- If no recipe data yet, fall back to current char only
    if not next(craftable) then
        local needs = {}
        self:ScanCurrentCharGear(needs)
        return needs
    end

    local filtered = {}
    for _, need in ipairs(allNeeds) do
        local isTool = TOOL_SLOTS[need.slotID]
        local key = need.profession .. ":" .. (isTool and "tool" or "acc")
        if craftable[key] then
            filtered[#filtered + 1] = need
        end
    end
    return filtered
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
    -- Collect ALL candidates per profession+slotType, then pick best match for target quality
    local candidates = {}  -- { [key] = { {recipeID, recipeName, outputQuality, ...}, ... } }

    local allRecipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if not allRecipeIDs then return {} end

    -- Filter to current expansion's skill line (Midnight > TWW > etc.)
    local childProfInfo = C_TradeSkillUI.GetChildProfessionInfo()
    local childProfID = childProfInfo and childProfInfo.professionID

    local targetQ = self:GetTargetQuality()

    for _, recipeID in ipairs(allRecipeIDs) do
        local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if recipeInfo and recipeInfo.learned
            and (not childProfID or C_TradeSkillUI.IsRecipeInSkillLine(recipeID, childProfID)) then
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
                -- Use GetItemInfoInstant for classID/equipSlot (always synchronous)
                local _, _, _, equipSlot, _, classID, subclassID = C_Item.GetItemInfoInstant(outputItemID)
                if classID == Enum.ItemClass.Profession then
                    local isTool = (equipSlot == "INVTYPE_PROFESSION_TOOL")
                    local isAcc = (equipSlot == "INVTYPE_PROFESSION_GEAR" or equipSlot == "INVTYPE_PROFESSION_ACCESSORY")

                    if isTool or isAcc then
                        -- Get rarity: prefer first qualityItemID (R1 = base tier), then fallback
                        local rarityItemID = outputItemID
                        if cached and cached.qualityItemIDs and cached.qualityItemIDs[1] then
                            rarityItemID = cached.qualityItemIDs[1]
                        end
                        local _, _, outputRarity = GetItemInfo(rarityItemID)
                        if not outputRarity then
                            outputRarity = C_Item.GetItemQualityByID(rarityItemID)
                        end
                        if not outputRarity then
                            -- Last resort: try the base outputItemID
                            _, _, outputRarity = GetItemInfo(outputItemID)
                        end

                        -- Match profession by subclass
                        local profSubclasses = GetProfSubclass()
                        for profName, subID in pairs(profSubclasses) do
                            if subclassID == subID then
                                local slotType = isTool and "tool" or "acc"
                                local key = profName .. ":" .. slotType
                                if needed[key] then
                                    if not candidates[key] then candidates[key] = {} end
                                    candidates[key][#candidates[key] + 1] = {
                                        recipeID = recipeID,
                                        recipeName = recipeInfo.name,
                                        profession = profName,
                                        slotType = slotType,
                                        outputQuality = outputRarity or 1,
                                    }
                                    WishDebug("KazWish candidate:", recipeInfo.name,
                                        "rarity:", tostring(outputRarity), "key:", key)
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Pick best recipe per key: closest to target quality without exceeding it
    -- e.g., target Green(2): prefer quality 2 recipe over quality 4
    local results = {}
    for key, cands in pairs(candidates) do
        table.sort(cands, function(a, b)
            -- Prefer recipe whose output quality is <= target and closest to it
            local aDist = (a.outputQuality <= targetQ) and (targetQ - a.outputQuality) or 100
            local bDist = (b.outputQuality <= targetQ) and (targetQ - b.outputQuality) or 100
            if aDist ~= bDist then return aDist < bDist end
            -- Fallback: prefer lower quality (cheaper)
            return a.outputQuality < b.outputQuality
        end)
        local best = cands[1]
        WishDebug("KazWish pick:", key, "->", best.recipeName,
            "rarity:", best.outputQuality, "from", #cands, "candidates, target:", targetQ)
        results[#results + 1] = {
            recipeID = best.recipeID,
            recipeName = best.recipeName,
            qty = #needed[key],
            needs = needed[key],
            profession = best.profession,
            slotType = best.slotType,
        }
    end

    return results
end

--------------------------------------------------------------------
-- Queue all craftable wishes into KazCraft queue
--------------------------------------------------------------------
function Wishlist:QueueCraftable()
    local queued = 0

    -- Gear wishes — enriched with crafter info from cache (no profession window needed)
    local gearNeeds = self:ScanProfessionGear()
    self:EnrichNeedsWithCrafters(gearNeeds)

    -- Debug: show what we found
    local craftableCount = 0
    local uncraftableKeys = {}
    for _, need in ipairs(gearNeeds) do
        if need.craftable then
            craftableCount = craftableCount + 1
        else
            local isTool = TOOL_SLOTS[need.slotID]
            local key = need.profession .. ":" .. (isTool and "tool" or "acc")
            uncraftableKeys[key] = (uncraftableKeys[key] or 0) + 1
        end
    end
    WishDebug("QueueCraftable:", #gearNeeds, "needs,", craftableCount, "craftable")
    for key, count in pairs(uncraftableKeys) do
        WishDebug("  No recipe for:", key, "(" .. count .. " slots)")
    end

    -- Group by best crafter + recipeID to batch
    local gearBatch = {}  -- { [crafterKey..recipeID] = { recipeID, crafter, count, recipeName, profession, slotType } }
    for _, need in ipairs(gearNeeds) do
        if need.craftable and need.recipeID and need.bestCrafter then
            local batchKey = need.bestCrafter .. ":" .. need.recipeID
            if not gearBatch[batchKey] then
                local isTool = TOOL_SLOTS[need.slotID]
                gearBatch[batchKey] = {
                    recipeID = need.recipeID,
                    crafter = need.bestCrafter,
                    count = 0,
                    recipeName = need.recipeName or ("Recipe " .. need.recipeID),
                    profession = need.profession,
                    slotType = isTool and "Tool" or "Accessory",
                }
            end
            gearBatch[batchKey].count = gearBatch[batchKey].count + 1
        end
    end

    for _, batch in pairs(gearBatch) do
        ns.Data:AddToQueue(batch.recipeID, batch.count, batch.crafter)
        local crafterName = batch.crafter:match("^(.-)%-") or batch.crafter
        local skillStr = ""
        local skills = KazCraftDB.professionSkills or {}
        local charSkills = skills[batch.crafter]
        if charSkills and charSkills[batch.profession] then
            skillStr = " (" .. charSkills[batch.profession] .. ")"
        end
        print(string.format("|cffc8aa64KazWish:|r Queued %s x%d → %s%s (%s %s)",
            batch.recipeName, batch.count, crafterName, skillStr,
            batch.profession, batch.slotType))
        queued = queued + batch.count
    end

    -- Consumable wishes
    local consumables = self:ScanConsumables()
    if ns.itemToRecipe then
        for _, wish in ipairs(consumables) do
            if wish.need > 0 then
                local recipeID = ns.itemToRecipe[wish.itemID]
                if recipeID then
                    -- Queue to best crafter for this recipe
                    local crafter = ns.Data:GetBestCrafter(recipeID)
                    if crafter then
                        ns.Data:AddToQueue(recipeID, wish.need, crafter)
                        local crafterName = crafter:match("^(.-)%-") or crafter
                        print(string.format("|cffc8aa64KazWish:|r Queued %s x%d → %s",
                            wish.itemName, wish.need, crafterName))
                        queued = queued + wish.need
                    end
                end
            end
        end
    end

    if queued == 0 then
        -- Diagnostic: show what couldn't be matched
        local noRecipe = {}
        local noCrafter = {}
        for _, need in ipairs(gearNeeds) do
            local isTool = TOOL_SLOTS[need.slotID]
            local key = need.profession .. " " .. (isTool and "Tool" or "Acc")
            if not need.craftable then
                noRecipe[key] = true
            elseif not need.bestCrafter then
                noCrafter[key] = true
            end
        end
        local noRecipeList = {}
        for key in pairs(noRecipe) do noRecipeList[#noRecipeList + 1] = key end
        local noCrafterList = {}
        for key in pairs(noCrafter) do noCrafterList[#noCrafterList + 1] = key end

        if #noRecipeList > 0 then
            print("|cffc8aa64KazWish:|r No recipes cached for: " .. table.concat(noRecipeList, ", "))
            print("|cffc8aa64KazWish:|r Open each crafter's profession to populate the cache.")
        end
        if #noCrafterList > 0 then
            print("|cffc8aa64KazWish:|r Recipes found but no crafter tagged for: " .. table.concat(noCrafterList, ", "))
            print("|cffc8aa64KazWish:|r Log into each crafter and open their profession once.")
        end
        if #noRecipeList == 0 and #noCrafterList == 0 and #gearNeeds == 0 then
            print("|cffc8aa64KazWish:|r Nothing to queue — all slots at target quality.")
        end
    else
        print(string.format("|cffc8aa64KazWish:|r Queued %d items into KazCraft.", queued))
        if ns.ProfessionUI and ns.ProfessionUI.RefreshQueue then
            ns.ProfessionUI:RefreshQueue()
        end
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
        local emptyCount = 0
        for _, need in ipairs(gearNeeds) do
            if (need.currentQuality or 0) == 0 then emptyCount = emptyCount + 1 end
        end
        local upgradeCount = gearCount - emptyCount
        local parts = {}
        if emptyCount > 0 then parts[#parts + 1] = emptyCount .. " empty" end
        if upgradeCount > 0 then parts[#parts + 1] = upgradeCount .. " upgradeable" end
        local targetQ = self:GetTargetQuality()
        print("|cffc8aa64KazWish:|r " .. table.concat(parts, ", ") ..
            " profession gear slots (target: " .. QUALITY_COLORS[targetQ] .. QUALITY_NAMES[targetQ] ..
            "|r). /kaz wish to view.")
    end

    -- Gear plan needs
    local plans = self:GetAllGearPlans()
    if #plans > 0 then
        local stateCount = {}
        for _, p in ipairs(plans) do
            stateCount[p.state] = (stateCount[p.state] or 0) + 1
        end
        local parts2 = {}
        if stateCount[STATE_EMPTY] then parts2[#parts2 + 1] = stateCount[STATE_EMPTY] .. " empty" end
        if stateCount[STATE_UPGRADE] then parts2[#parts2 + 1] = stateCount[STATE_UPGRADE] .. " upgradeable" end
        if stateCount[STATE_QUEUED] then parts2[#parts2 + 1] = stateCount[STATE_QUEUED] .. " queued" end
        if stateCount[STATE_BLOCKED] then parts2[#parts2 + 1] = stateCount[STATE_BLOCKED] .. " blocked" end
        if #parts2 > 0 then
            print("|cffc8aa64KazWish:|r Gear plans: " .. table.concat(parts2, ", ") .. ". /kaz wish plans")
        end
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
        local targetQ = self:GetTargetQuality()
        if #gearNeeds == 0 then
            print("|cffc8aa64KazWish:|r All profession gear at " ..
                QUALITY_COLORS[targetQ] .. QUALITY_NAMES[targetQ] .. "|r or better.")
        else
            print("|cffc8aa64KazWish:|r Profession gear needs (target: " ..
                QUALITY_COLORS[targetQ] .. QUALITY_NAMES[targetQ] .. "|r):")
            for _, need in ipairs(gearNeeds) do
                local color = need.classColor or "|cffffffff"
                local cq = need.currentQuality or 0
                local status = cq == 0 and "|cffff6666Empty|r"
                    or (QUALITY_COLORS[cq] .. QUALITY_NAMES[cq] .. "|r")
                print(string.format("  %s%s|r — %s %s [%s]",
                    color, need.charName, need.profession, need.slotName, status))
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

    elseif msg:find("^who ") then
        -- /kaz wish who [item link or itemID]
        local link = msg:match("|c.-|h|r") or msg:match("|Hitem:.-|h.-|h")
        local itemID
        if link then
            itemID = tonumber(link:match("item:(%d+)"))
        else
            itemID = tonumber(msg:match("^who%s+(%d+)"))
        end
        if itemID then
            local crafters = ns.Data:GetCraftersForItem(itemID)
            if crafters and #crafters > 0 then
                local names = {}
                for _, c in ipairs(crafters) do
                    local entry = c.coloredName
                    if c.skill then entry = entry .. " (" .. c.skill .. ")" end
                    table.insert(names, entry)
                end
                print("|cffc8aa64KazWish:|r Crafted by: " .. table.concat(names, ", "))
            else
                print("|cffc8aa64KazWish:|r No known crafters for that item.")
            end
        else
            print("|cffc8aa64KazWish:|r Usage: /kaz wish who [item link]")
        end

    elseif msg == "plans" then
        -- Show all gear plans with states
        local plans = self:GetAllGearPlans()
        if #plans == 0 then
            print("|cffc8aa64KazWish:|r No gear plans set. Use /kaz wish plan [char-realm] [slotID] [itemID] [quality]")
        else
            print("|cffc8aa64KazWish:|r Gear plans:")
            for _, p in ipairs(plans) do
                local color = p.classColor or "|cffffffff"
                local qColor = QUALITY_COLORS[p.targetQuality] or "|cffffffff"
                local qName = QUALITY_NAMES[p.targetQuality] or "R" .. p.targetQuality
                local extra = ""
                if p.state == STATE_QUEUED and p.queuedTo then
                    extra = " → " .. p.queuedTo
                end
                print(string.format("  %s%s|r %s — %s%s|r [%s%s|r]%s",
                    color, p.charName, p.slotName,
                    qColor, qName,
                    p.stateColor, p.stateLabel, extra))
            end
        end

    elseif msg:find("^plan ") then
        -- /kaz wish plan Char-Realm slotID itemID [quality]
        local args = msg:match("^plan%s+(.*)")
        local charKey, slotStr, itemStr, qualStr = args:match("^(%S+)%s+(%d+)%s+(%d+)%s*(%d*)")
        if charKey and slotStr and itemStr then
            local slotID = tonumber(slotStr)
            local targetItemID = tonumber(itemStr)
            local targetQuality = tonumber(qualStr) or QUALITY_EPIC
            self:SetGearPlan(charKey, slotID, targetItemID, targetQuality)
            local itemName = C_Item.GetItemNameByID(targetItemID) or ("Item " .. targetItemID)
            print(string.format("|cffc8aa64KazWish:|r Set plan: %s slot %d → %s R%d",
                charKey, slotID, itemName, targetQuality))
        else
            print("|cffc8aa64KazWish:|r Usage: /kaz wish plan Char-Realm slotID itemID [quality]")
        end

    elseif msg:find("^best ") then
        -- /kaz wish best [item link or recipeID]
        local link = msg:match("|c.-|h|r") or msg:match("|Hitem:.-|h.-|h")
        local recipeID
        if link then
            local itemID = tonumber(link:match("item:(%d+)"))
            recipeID = itemID and ns.itemToRecipe and ns.itemToRecipe[itemID]
        else
            recipeID = tonumber(msg:match("^best%s+(%d+)"))
        end
        if recipeID then
            local crafter, skill = ns.Data:GetBestCrafter(recipeID)
            if crafter then
                local skillStr = skill and (" (skill " .. skill .. ")") or ""
                local cached = KazCraftDB.recipeCache[recipeID]
                local name = cached and cached.recipeName or ("Recipe " .. recipeID)
                print("|cffc8aa64KazWish:|r Best crafter for " .. name .. ": " .. crafter .. skillStr)
            else
                print("|cffc8aa64KazWish:|r No known crafter for that recipe.")
            end
        else
            print("|cffc8aa64KazWish:|r Usage: /kaz wish best [item link]")
        end

    elseif msg == "queue" then
        self:QueueCraftable()

    elseif msg == "help" then
        print("|cffc8aa64KazWish:|r Commands:")
        print("  /kaz wish — open wishlist window")
        print("  /kaz wish scan — print needs to chat")
        print("  /kaz wish plans — show gear plans with states")
        print("  /kaz wish plan [char] [slot] [itemID] [quality] — set gear plan")
        print("  /kaz wish queue — queue craftable items into KazCraft")
        print("  /kaz wish who [link] — show who can craft an item (with skill)")
        print("  /kaz wish best [link] — show best crafter for an item")
        print("  /kaz wish add [link] [qty] — add consumable")
        print("  /kaz wish remove [itemID] — remove consumable")

    else
        print("|cffc8aa64KazWish:|r Unknown command. /kaz wish help")
    end
end
