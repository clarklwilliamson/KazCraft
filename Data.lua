local addonName, ns = ...

ns.Data = {}
local Data = ns.Data

-- Cache a single recipe schematic into SavedVariables
function Data:CacheSchematic(recipeID, profName)
    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematic then return end

    local reagents = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        if slot.reagentType == Enum.CraftingReagentType.Basic and slot.required then
            -- slot.reagents contains quality tiers (R1/R2/R3) of the same mat
            -- Take first itemID only — any tier satisfies the requirement
            -- GetItemCount sums all quality tiers in inventory automatically
            local firstReagent = slot.reagents[1]
            if firstReagent and firstReagent.itemID then
                table.insert(reagents, {
                    itemID = firstReagent.itemID,
                    quantity = slot.quantityRequired,
                })
            end
        end
    end

    -- Quality variant itemIDs (e.g., R1/R2/R3/R4/R5 versions of the output)
    local qualityItemIDs = C_TradeSkillUI.GetRecipeQualityItemIDs(recipeID)

    KazCraftDB.recipeCache[recipeID] = {
        recipeName = schematic.name,
        icon = schematic.icon,
        professionName = profName or "",
        reagents = reagents,
        outputItemID = schematic.outputItemID,
        qualityItemIDs = qualityItemIDs or nil,
    }

    return KazCraftDB.recipeCache[recipeID]
end

-- Background-cache all learned recipes when profession opens (20/frame)
function Data:CacheAllRecipes(profInfo)
    if self._caching then return end
    if not profInfo or not profInfo.profession then return end
    self._caching = true

    local profName = profInfo.professionName or ""
    local recipeIDs = C_TradeSkillUI.GetProfessionSpells(profInfo.profession)
    if not recipeIDs or #recipeIDs == 0 then
        self._caching = false
        return
    end

    local idx = 1
    local total = #recipeIDs
    local batchSize = 20

    C_Timer.NewTicker(0, function(ticker)
        if not C_TradeSkillUI.IsTradeSkillReady() then
            ticker:Cancel()
            self._caching = false
            return
        end

        local batchEnd = math.min(idx + batchSize - 1, total)
        for i = idx, batchEnd do
            local id = recipeIDs[i]
            if not KazCraftDB.recipeCache[id] then
                self:CacheSchematic(id, profName)
            end
        end

        idx = batchEnd + 1
        if idx > total then
            ticker:Cancel()
            self._caching = false
            self:BuildItemToRecipeIndex()
        end
    end)
end

-- Build reverse index: itemID → recipeID (for sub-recipe detection)
function Data:BuildItemToRecipeIndex()
    ns.itemToRecipe = {}
    local count = 0
    local noOutput = 0
    for recipeID, cached in pairs(KazCraftDB.recipeCache) do
        if cached.outputItemID then
            ns.itemToRecipe[cached.outputItemID] = recipeID
            count = count + 1
        else
            noOutput = noOutput + 1
        end
        if cached.qualityItemIDs then
            for _, itemID in ipairs(cached.qualityItemIDs) do
                ns.itemToRecipe[itemID] = recipeID
                count = count + 1
            end
        end
    end
end

-- Get the queue for a character
function Data:GetCharacterQueue(charKey)
    charKey = charKey or ns.charKey
    if not KazCraftDB.queues[charKey] then
        KazCraftDB.queues[charKey] = {}
    end
    return KazCraftDB.queues[charKey]
end

-- Add a recipe to the queue
function Data:AddToQueue(recipeID, quantity, charKey)
    charKey = charKey or ns.charKey
    local queue = self:GetCharacterQueue(charKey)

    -- Check if already queued
    for _, entry in ipairs(queue) do
        if entry.recipeID == recipeID then
            entry.quantity = entry.quantity + (quantity or 1)
            return
        end
    end

    table.insert(queue, {
        recipeID = recipeID,
        quantity = quantity or 1,
    })
end

-- Queue a recipe and auto-queue any craftable sub-recipes for shortfall
-- Sub-recipes are placed before their parent in the queue (craft order)
function Data:QueueWithSubRecipes(recipeID, qty, _visited)
    _visited = _visited or {}
    if _visited[recipeID] then return end -- prevent infinite loops
    _visited[recipeID] = true

    -- Ensure cached
    if not KazCraftDB.recipeCache[recipeID] then
        self:CacheSchematic(recipeID, ns.currentProfName)
    end

    -- Queue the main recipe first (needed for demand calculation)
    self:AddToQueue(recipeID, qty)

    -- Ensure index exists (lazy build if CacheAllRecipes hasn't run yet)
    if not ns.itemToRecipe then
        self:BuildItemToRecipeIndex()
    end

    local cached = KazCraftDB.recipeCache[recipeID]
    if not cached or not cached.reagents then return end

    -- Check each reagent for craftable sub-recipes
    for _, reagent in ipairs(cached.reagents) do
        local subRecipeID = ns.itemToRecipe[reagent.itemID]
        if subRecipeID and not _visited[subRecipeID] then
            local have = C_Item.GetItemCount(reagent.itemID, true, false, true, true)

            -- Total demand for this reagent across ALL queued recipes
            local totalDemand = 0
            local queue = self:GetCharacterQueue()
            for _, entry in ipairs(queue) do
                local entryCached = KazCraftDB.recipeCache[entry.recipeID]
                if entryCached and entryCached.reagents then
                    for _, r in ipairs(entryCached.reagents) do
                        if r.itemID == reagent.itemID then
                            totalDemand = totalDemand + (r.quantity * entry.quantity)
                        end
                    end
                end
            end

            -- Total supply = inventory + already-queued sub-recipe output
            local alreadyQueued = 0
            for _, entry in ipairs(queue) do
                if entry.recipeID == subRecipeID then
                    alreadyQueued = alreadyQueued + entry.quantity
                    break
                end
            end

            local short = math.max(0, totalDemand - have - alreadyQueued)
            if short > 0 then
                local subCached = KazCraftDB.recipeCache[subRecipeID]
                local subName = subCached and subCached.recipeName or ("Recipe " .. subRecipeID)
                print("|cff00ccff[KazCraft]|r Auto-queued " .. short .. "x " .. subName)
                self:QueueWithSubRecipes(subRecipeID, short, _visited)

                -- Move sub-recipe before parent in queue for correct craft order
                self:EnsureBefore(subRecipeID, recipeID)
            end
        end
    end
end

-- Move entry with recipeA before recipeB in the queue (if both exist)
function Data:EnsureBefore(recipeA, recipeB, charKey)
    charKey = charKey or ns.charKey
    local queue = self:GetCharacterQueue(charKey)
    local idxA, idxB
    for i, entry in ipairs(queue) do
        if entry.recipeID == recipeA then idxA = i end
        if entry.recipeID == recipeB then idxB = i end
    end
    if idxA and idxB and idxA > idxB then
        local entry = table.remove(queue, idxA)
        table.insert(queue, idxB, entry)
    end
end

-- Remove a recipe from the queue
function Data:RemoveFromQueue(index, charKey)
    charKey = charKey or ns.charKey
    local queue = self:GetCharacterQueue(charKey)
    table.remove(queue, index)
end

-- Adjust quantity for a queued recipe
function Data:AdjustQuantity(index, delta, charKey)
    charKey = charKey or ns.charKey
    local queue = self:GetCharacterQueue(charKey)
    if not queue[index] then return end

    queue[index].quantity = math.max(1, queue[index].quantity + delta)
end

-- Clear queue for a character
function Data:ClearQueue(charKey)
    charKey = charKey or ns.charKey
    KazCraftDB.queues[charKey] = {}
end

-- Pull CraftSim craft queue materials (soft dependency)
-- CraftSim uses private namespace — access via CraftSimAPI:GetCraftSim() global
-- Returns: { [itemID] = totalNeeded }
local function GetCraftSimMaterials()
    local mats = {}

    -- CraftSimAPI is the only global CraftSim exposes
    if not CraftSimAPI then return mats end

    local CS = CraftSimAPI:GetCraftSim()
    if not CS or not CS.CRAFTQ or not CS.CRAFTQ.craftQueue then return mats end

    local craftQueue = CS.CRAFTQ.craftQueue
    if not craftQueue.craftQueueItems then return mats end

    for _, cqi in ipairs(craftQueue.craftQueueItems) do
        local recipeData = cqi.recipeData
        local amount = cqi.amount or 1
        if recipeData and recipeData.reagentData and recipeData.reagentData.requiredReagents then
            for _, reagent in ipairs(recipeData.reagentData.requiredReagents) do
                if reagent.hasQuality and reagent.items then
                    -- Quality reagent: each tier has allocated quantity
                    for _, reagentItem in ipairs(reagent.items) do
                        if reagentItem.quantity and reagentItem.quantity > 0 then
                            local ok, itemID = pcall(function() return reagentItem.item:GetItemID() end)
                            if ok and itemID then
                                mats[itemID] = (mats[itemID] or 0) + (reagentItem.quantity * amount)
                            end
                        end
                    end
                elseif reagent.items and reagent.items[1] then
                    -- No quality tiers — single item, use requiredQuantity
                    local ok, itemID = pcall(function() return reagent.items[1].item:GetItemID() end)
                    if ok and itemID then
                        mats[itemID] = (mats[itemID] or 0) + (reagent.requiredQuantity * amount)
                    end
                end
            end
        end
    end

    return mats
end

-- Aggregate materials needed for a character's queue (or all)
-- Merges KazCraft queue + CraftSim queue (if loaded)
-- Returns: { [itemID] = { itemID, itemName, icon, need, have, price, total } }
function Data:GetMaterialList(charKey)
    local materials = {} -- itemID -> { need = N }
    local queues

    if charKey then
        queues = { [charKey] = self:GetCharacterQueue(charKey) }
    else
        queues = KazCraftDB.queues
    end

    -- KazCraft's own queue
    for _, queue in pairs(queues) do
        for _, entry in ipairs(queue) do
            local cached = KazCraftDB.recipeCache[entry.recipeID]
            if cached then
                for _, reagent in ipairs(cached.reagents) do
                    if not materials[reagent.itemID] then
                        materials[reagent.itemID] = { itemID = reagent.itemID, need = 0 }
                    end
                    materials[reagent.itemID].need = materials[reagent.itemID].need + (reagent.quantity * entry.quantity)
                end
            end
        end
    end

    -- CraftSim queue (soft dependency — merges if CraftSim is loaded)
    local csMats = GetCraftSimMaterials()
    for itemID, qty in pairs(csMats) do
        if not materials[itemID] then
            materials[itemID] = { itemID = itemID, need = 0 }
        end
        materials[itemID].need = materials[itemID].need + qty
    end

    -- Enrich with inventory counts and prices
    local result = {}
    for itemID, mat in pairs(materials) do
        mat.have = C_Item.GetItemCount(itemID, true, false, true, true)
        mat.short = math.max(0, mat.need - mat.have)

        -- TSM price via KazCraft's standalone reader (or TSM_API fallback)
        mat.price = 0
        if ns.TSMData then
            local price = ns.TSMData:GetPrice(itemID, "DBMinBuyout")
            if price then
                mat.price = price
            end
        end
        mat.totalCost = mat.short * mat.price

        -- Item info (may need server query — request it, refresh on callback)
        local itemName, _, _, _, _, _, _, _, _, itemIcon, _, _, _, bindType = C_Item.GetItemInfo(itemID)
        if not itemName then
            -- Request from server — will fire GET_ITEM_INFO_RECEIVED when ready
            C_Item.RequestLoadItemDataByID(itemID)
        end
        mat.itemName = itemName or ("Item:" .. itemID)
        mat.icon = itemIcon or 134400
        mat.soulbound = (bindType == 1) -- LE_ITEM_BIND_ON_PICKUP

        table.insert(result, mat)
    end

    -- Sort by name
    table.sort(result, function(a, b)
        return a.itemName < b.itemName
    end)

    return result
end

-- Get total cost of all missing materials
function Data:GetTotalCost(charKey)
    local mats = self:GetMaterialList(charKey)
    local total = 0
    for _, mat in ipairs(mats) do
        if not mat.soulbound then
            total = total + mat.totalCost
        end
    end
    return total
end

-- Get all character keys that have queues
function Data:GetQueuedCharacters()
    local chars = {}
    for charKey, queue in pairs(KazCraftDB.queues) do
        if #queue > 0 then
            table.insert(chars, charKey)
        end
    end
    table.sort(chars)
    return chars
end

-- Check if CraftSim queue has items
function Data:HasCraftSimQueue()
    if not CraftSimAPI then return false end
    local CS = CraftSimAPI:GetCraftSim()
    if not CS or not CS.CRAFTQ or not CS.CRAFTQ.craftQueue then return false end
    local items = CS.CRAFTQ.craftQueue.craftQueueItems
    return items and #items > 0
end

-- ============================================================================
-- Cross-Addon API (consumed by KazVendor, etc.)
-- ============================================================================
KazCraft_API = {}
function KazCraft_API.GetMissingMaterials()
    return ns.Data:GetMaterialList(ns.charKey)
end

-- Decrement queue after successful craft
function Data:DecrementQueue(recipeID, charKey)
    charKey = charKey or ns.charKey
    local queue = self:GetCharacterQueue(charKey)
    for i, entry in ipairs(queue) do
        if entry.recipeID == recipeID then
            entry.quantity = entry.quantity - 1
            if entry.quantity <= 0 then
                table.remove(queue, i)
            end
            return true
        end
    end
    return false
end
