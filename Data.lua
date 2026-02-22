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

    KazCraftDB.recipeCache[recipeID] = {
        recipeName = schematic.name,
        icon = schematic.icon,
        professionName = profName or "",
        reagents = reagents,
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
        end
    end)
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

-- Aggregate materials needed for a character's queue (or all)
-- Returns: { [itemID] = { itemID, itemName, icon, need, have, price, total } }
function Data:GetMaterialList(charKey)
    local materials = {} -- itemID -> { need = N }
    local queues

    if charKey then
        queues = { [charKey] = self:GetCharacterQueue(charKey) }
    else
        queues = KazCraftDB.queues
    end

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

    -- Enrich with inventory counts and prices
    local result = {}
    for itemID, mat in pairs(materials) do
        mat.have = C_Item.GetItemCount(itemID, true, false, true, true)
        mat.short = math.max(0, mat.need - mat.have)

        -- TSM price (soft dependency)
        mat.price = 0
        if TSM_API and TSM_API.GetCustomPriceValue then
            local price = TSM_API.GetCustomPriceValue("DBMinBuyout", "i:" .. itemID)
            if price then
                mat.price = price
            end
        end
        mat.totalCost = mat.short * mat.price

        -- Item info (may need server query — request it, refresh on callback)
        local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
        if not itemName then
            -- Request from server — will fire GET_ITEM_INFO_RECEIVED when ready
            C_Item.RequestLoadItemDataByID(itemID)
        end
        mat.itemName = itemName or ("Item:" .. itemID)
        mat.icon = itemIcon or 134400

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
        total = total + mat.totalCost
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
