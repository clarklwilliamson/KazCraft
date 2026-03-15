local addonName, ns = ...

ns.Data = {}
local Data = ns.Data

-- Cache a single recipe schematic into SavedVariables
-- charKey: optional, tags recipe as known by this character
function Data:CacheSchematic(recipeID, profName, charKey)
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

    -- Preserve existing knownBy when re-caching
    local existing = KazCraftDB.recipeCache[recipeID]
    local knownBy = existing and existing.knownBy or {}

    KazCraftDB.recipeCache[recipeID] = {
        recipeName = schematic.name,
        icon = schematic.icon,
        professionName = profName or "",
        reagents = reagents,
        outputItemID = schematic.outputItemID,
        qualityItemIDs = qualityItemIDs or nil,
        knownBy = knownBy,
    }

    -- Tag who knows this recipe
    if charKey then
        KazCraftDB.recipeCache[recipeID].knownBy[charKey] = true
    end

    return KazCraftDB.recipeCache[recipeID]
end

-- Background-cache all learned recipes when profession opens (20/frame)
function Data:CacheAllRecipes(profInfo)
    if self._caching then return end
    if not profInfo or not profInfo.profession then return end
    self._caching = true

    local profName = profInfo.professionName or ""
    local charKey = ns.charKey
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
            local recipeInfo = C_TradeSkillUI.GetRecipeInfo(id)
            local isLearned = recipeInfo and recipeInfo.learned

            if not KazCraftDB.recipeCache[id] then
                if isLearned then
                    self:CacheSchematic(id, profName, charKey)
                end
            elseif isLearned and charKey then
                local entry = KazCraftDB.recipeCache[id]
                entry.knownBy = entry.knownBy or {}
                entry.knownBy[charKey] = true
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

-- Scan all DataStore characters' known recipes and tag knownBy on cached entries
-- Also captures profession skill levels from DataStore (overall rank as fallback)
function Data:ScanKnownRecipes()
    local function log(msg)
        KazUtil._logBuffer[#KazUtil._logBuffer + 1] = {
            time = date("%H:%M:%S"), addon = "KazCraft", level = "info", msg = msg,
        }
    end
    if not DataStore then
        log("ScanKnownRecipes: DataStore not loaded")
        return
    end
    if not DataStore.GetProfession1 then
        log("ScanKnownRecipes: DataStore_Crafts not ready (GetProfession1 missing)")
        return
    end
    local cache = KazCraftDB.recipeCache
    KazCraftDB.professionSkills = KazCraftDB.professionSkills or {}

    local tagged = 0
    local skillsCaptured = 0
    local dsRecipesTotal = 0
    local dsRecipesLearned = 0
    local dsRecipesMatched = 0
    for account in pairs(DataStore:GetAccounts()) do
        for realm in pairs(DataStore:GetRealms(account)) do
            for charName, dsKey in pairs(DataStore:GetCharacters(realm, account)) do
                local kazKey = charName .. "-" .. realm

                -- Get both primary professions
                for i = 1, 2 do
                    local prof, profName, rank
                    if i == 1 then
                        rank, _, _, profName = DataStore:GetProfession1(dsKey)
                        if profName then
                            prof = DataStore:GetProfession(dsKey, profName)
                        end
                    else
                        rank, _, _, profName = DataStore:GetProfession2(dsKey)
                        if profName then
                            prof = DataStore:GetProfession(dsKey, profName)
                        end
                    end

                    -- Cache skill level from DataStore (only if we don't have live data)
                    if profName and rank and rank > 0 then
                        KazCraftDB.professionSkills[kazKey] = KazCraftDB.professionSkills[kazKey] or {}
                        if not KazCraftDB.professionSkills[kazKey][profName] then
                            KazCraftDB.professionSkills[kazKey][profName] = rank
                            skillsCaptured = skillsCaptured + 1
                        end
                    end

                    if prof and cache and next(cache) then
                        DataStore:IterateRecipes(prof, 0, 0, function(recipeData)
                            if recipeData then
                                dsRecipesTotal = dsRecipesTotal + 1
                                local _, recipeID, isLearned = DataStore:GetRecipeInfo(recipeData)
                                if isLearned then
                                    dsRecipesLearned = dsRecipesLearned + 1
                                    if recipeID and cache[recipeID] then
                                        dsRecipesMatched = dsRecipesMatched + 1
                                        local entry = cache[recipeID]
                                        entry.knownBy = entry.knownBy or {}
                                        if not entry.knownBy[kazKey] then
                                            entry.knownBy[kazKey] = true
                                            tagged = tagged + 1
                                        end
                                    end
                                end
                            end
                        end)
                    end
                end
            end
        end
    end

    log("ScanKnownRecipes: DS has " .. dsRecipesTotal .. " recipes, " ..
        dsRecipesLearned .. " learned, " .. dsRecipesMatched .. " match our cache, " ..
        tagged .. " newly tagged, " .. skillsCaptured .. " skills")
end

-- Cache current character's profession skill level (expansion-specific)
function Data:CacheSkillLevel()
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    if not profInfo or not profInfo.professionName then return end

    local charKey = ns.charKey
    if not charKey then return end

    local skillLevel = (profInfo.skillLevel or 0) + (profInfo.skillModifier or 0)
    local profName = profInfo.professionName

    KazCraftDB.professionSkills = KazCraftDB.professionSkills or {}
    KazCraftDB.professionSkills[charKey] = KazCraftDB.professionSkills[charKey] or {}
    KazCraftDB.professionSkills[charKey][profName] = skillLevel

    ns.DebugLog("CacheSkillLevel:", charKey, profName, "=", skillLevel)
end

-- Get the best crafter for a recipe (highest skill in that profession)
function Data:GetBestCrafter(recipeID)
    local cached = KazCraftDB.recipeCache[recipeID]
    if not cached or not cached.knownBy then return nil end

    local profName = cached.professionName
    local skills = KazCraftDB.professionSkills or {}

    local best = nil
    local bestSkill = -1

    for charKey in pairs(cached.knownBy) do
        local charSkills = skills[charKey]
        local skill = charSkills and charSkills[profName] or 0
        if skill > bestSkill then
            bestSkill = skill
            best = charKey
        end
    end

    return best, bestSkill > 0 and bestSkill or nil
end

-- Get list of characters who can craft a specific item
function Data:GetCraftersForItem(itemID)
    if not itemID or not ns.itemToRecipe then return nil end
    local recipeID = ns.itemToRecipe[itemID]
    if not recipeID then return nil end
    return self:GetCraftersForRecipe(recipeID)
end

-- Get list of characters who know a specific recipe, enriched with class color
function Data:GetCraftersForRecipe(recipeID)
    if not recipeID then return nil end
    local entry = KazCraftDB.recipeCache[recipeID]
    if not entry or not entry.knownBy then return nil end

    local crafters = {}
    for kazKey in pairs(entry.knownBy) do
        local charName, realm = kazKey:match("^(.-)%-(.+)$")
        local classColor = nil

        -- Try to get class color from DataStore
        if DataStore and DataStore.GetCharacterClass then
            for account in pairs(DataStore:GetAccounts()) do
                local dsKey = account .. "." .. realm .. "." .. charName
                local ok, _, englishClass = pcall(DataStore.GetCharacterClass, DataStore, dsKey)
                if ok and englishClass then
                    local cc = RAID_CLASS_COLORS[englishClass]
                    if cc then
                        classColor = cc:GenerateHexColorMarkup()
                    end
                    break
                end
            end
        end

        -- Skill level from our cache
        local profName = entry.professionName
        local skills = KazCraftDB.professionSkills or {}
        local charSkills = skills[kazKey]
        local skill = charSkills and charSkills[profName] or nil

        table.insert(crafters, {
            key = kazKey,
            name = charName,
            realm = realm,
            classColor = classColor,
            coloredName = classColor and (classColor .. charName .. "|r") or charName,
            skill = skill,
        })
    end

    -- Sort by skill (highest first), then name
    table.sort(crafters, function(a, b)
        local sa, sb = a.skill or 0, b.skill or 0
        if sa ~= sb then return sa > sb end
        return a.name < b.name
    end)
    return crafters
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
function Data:AddToQueue(recipeID, quantity, charKey, reagents)
    charKey = charKey or ns.charKey
    local queue = self:GetCharacterQueue(charKey)

    -- Check if already queued with same reagent allocation
    for _, entry in ipairs(queue) do
        if entry.recipeID == recipeID then
            entry.quantity = entry.quantity + (quantity or 1)
            -- Update reagent allocation if provided (newer allocation wins)
            if reagents then
                entry.reagents = reagents
            end
            return
        end
    end

    table.insert(queue, {
        recipeID = recipeID,
        quantity = quantity or 1,
        reagents = reagents,  -- { {itemID=N, quantity=N}, ... } or nil for default
    })
end

-- Queue a recipe and auto-queue any craftable sub-recipes for shortfall
-- Sub-recipes are placed before their parent in the queue (craft order)
function Data:QueueWithSubRecipes(recipeID, qty, _visited, reagents)
    _visited = _visited or {}
    if _visited[recipeID] then return end -- prevent infinite loops
    _visited[recipeID] = true

    -- Ensure cached
    if not KazCraftDB.recipeCache[recipeID] then
        self:CacheSchematic(recipeID, ns.currentProfName, ns.charKey)
    end

    -- Queue the main recipe (with reagent allocation if provided)
    self:AddToQueue(recipeID, qty, nil, reagents)

    -- Always rebuild index fresh — CacheAllRecipes may have added new entries
    self:BuildItemToRecipeIndex()

    local cached = KazCraftDB.recipeCache[recipeID]
    if not cached or not cached.reagents then return end

    -- Check each reagent for craftable sub-recipes
    for _, reagent in ipairs(cached.reagents) do
        local subRecipeID = ns.itemToRecipe[reagent.itemID]

        -- If not in index, search profession recipes while UI is open
        if not subRecipeID and C_TradeSkillUI.IsTradeSkillReady() then
            local allRecipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
            if allRecipeIDs then
                for _, rid in ipairs(allRecipeIDs) do
                    -- Cache and check output
                    if not KazCraftDB.recipeCache[rid] then
                        self:CacheSchematic(rid, ns.currentProfName, ns.charKey)
                    end
                    local sub = KazCraftDB.recipeCache[rid]
                    if sub then
                        if sub.outputItemID == reagent.itemID then
                            subRecipeID = rid
                            ns.itemToRecipe[reagent.itemID] = rid
                            break
                        end
                        if sub.qualityItemIDs then
                            for _, qid in ipairs(sub.qualityItemIDs) do
                                if qid == reagent.itemID then
                                    subRecipeID = rid
                                    ns.itemToRecipe[reagent.itemID] = rid
                                    break
                                end
                            end
                            if subRecipeID then break end
                        end
                    end
                end
            end
        end
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

    -- Also clear CraftSim queue if loaded
    if CraftSimLib and CraftSimLib.CRAFTQ then
        local ok = pcall(function()
            if CraftSimLib.CRAFTQ.ClearAll then
                CraftSimLib.CRAFTQ:ClearAll()
            end
            if CraftSimLib.CRAFTQ.UI and CraftSimLib.CRAFTQ.UI.UpdateDisplay then
                CraftSimLib.CRAFTQ.UI:UpdateDisplay()
            end
        end)
    end
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
        local amount = tonumber(cqi.amount) or 1
        if recipeData and recipeData.reagentData and recipeData.reagentData.requiredReagents then
            for _, reagent in ipairs(recipeData.reagentData.requiredReagents) do
                -- Skip order-provided reagents (customer provides them)
                local isOrderReagent = false
                if recipeData.orderData then
                    local ok, result = pcall(reagent.IsOrderReagentIn, reagent, recipeData)
                    isOrderReagent = ok and result
                end
                if isOrderReagent then
                    -- Customer-provided, don't count toward shopping list
                elseif reagent.hasQuality and reagent.items then
                    -- Quality reagent: each tier has allocated quantity
                    for _, reagentItem in ipairs(reagent.items) do
                        if reagentItem.quantity and reagentItem.quantity > 0 then
                            local ok, itemID = pcall(function() return reagentItem.item:GetItemID() end)
                            if ok and itemID then
                                mats[itemID] = (mats[itemID] or 0) + ((tonumber(reagentItem.quantity) or 0) * amount)
                            end
                        end
                    end
                elseif reagent.items and reagent.items[1] then
                    -- No quality tiers — single item, use requiredQuantity
                    local ok, itemID = pcall(function() return reagent.items[1].item:GetItemID() end)
                    if ok and itemID then
                        mats[itemID] = (mats[itemID] or 0) + ((tonumber(reagent.requiredQuantity) or 0) * amount)
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
            -- Use tier-specific reagents from queue entry if available (from Optimize > Apply > +Queue)
            -- Otherwise fall back to base reagents from recipe cache
            local reagentList = entry.reagents
            if not reagentList then
                local cached = KazCraftDB.recipeCache[entry.recipeID]
                reagentList = cached and cached.reagents
            end
            if reagentList then
                for _, reagent in ipairs(reagentList) do
                    if not materials[reagent.itemID] then
                        materials[reagent.itemID] = { itemID = reagent.itemID, need = 0 }
                    end
                    materials[reagent.itemID].need = materials[reagent.itemID].need + ((tonumber(reagent.quantity) or 0) * (tonumber(entry.quantity) or 0))
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
        mat.have = tonumber(C_Item.GetItemCount(itemID, true, false, true, true)) or 0
        mat.need = tonumber(mat.need) or 0
        mat.short = math.max(0, mat.need - mat.have)

        -- Price: live cache first, Auctionator fallback
        mat.price = 0
        if ns.PriceCache then
            local price = ns.PriceCache:GetBestPrice(itemID)
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
-- PriceCache — persistent live AH prices, Auctionator fallback
-- ============================================================================
ns.PriceCache = {}
local PriceCache = ns.PriceCache
local MAX_SANE_PRICE = 100000000000 -- 10,000,000g in copper — sanity cap

function PriceCache:SetPrice(itemID, price)
    if not itemID or not price or price <= 0 then return end
    if price > MAX_SANE_PRICE then return end -- reject corrupt prices
    KazCraftDB.priceCache[itemID] = { p = price, t = time() }
end

function PriceCache:GetPrice(itemID, maxAge)
    maxAge = maxAge or 3600
    local entry = KazCraftDB.priceCache and KazCraftDB.priceCache[itemID]
    if entry and (time() - entry.t) <= maxAge then
        return entry.p
    end
    return nil
end

function PriceCache:GetBestPrice(itemID)
    local cached = self:GetPrice(itemID)
    if cached and cached <= MAX_SANE_PRICE then return cached, "live" end
    -- Auctionator fallback (from their last full scan)
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, atr = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "KazCraft", itemID)
        if ok and atr and atr > 0 and atr <= MAX_SANE_PRICE then return atr, "auctionator" end
    end
    return nil, nil
end

function PriceCache:GetSellPrice(itemID)
    local cached = self:GetPrice(itemID)
    if cached and cached <= MAX_SANE_PRICE then return cached, "live" end
    -- Auctionator fallback (from their last full scan)
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, atr = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "KazCraft", itemID)
        if ok and atr and atr > 0 and atr <= MAX_SANE_PRICE then return atr, "auctionator" end
    end
    return nil, nil
end

-- Collect output itemIDs from queued recipes (for AH sell-price scanning)
function PriceCache:GetQueueOutputItems()
    local outputs = {}
    local seen = {}
    -- KazCraft queue
    if KazCraftDB.queues then
        for _, queue in pairs(KazCraftDB.queues) do
            for _, entry in ipairs(queue) do
                local cached = KazCraftDB.recipeCache and KazCraftDB.recipeCache[entry.recipeID]
                if cached and cached.outputItemID and not seen[cached.outputItemID] then
                    seen[cached.outputItemID] = true
                    tinsert(outputs, cached.outputItemID)
                end
            end
        end
    end
    -- CraftSim queue outputs
    local CS = ns.CraftSimAPI and ns.CraftSimAPI:GetCraftSim()
    if CS and CS.CRAFTQ and CS.CRAFTQ.craftQueue then
        local items = CS.CRAFTQ.craftQueue.craftQueueItems
        if items then
            for _, item in ipairs(items) do
                local rd = item.recipeData
                if rd and rd.resultData and rd.resultData.expectedItem then
                    local ok, itemID = pcall(function() return rd.resultData.expectedItem:GetItemID() end)
                    if ok and itemID and not seen[itemID] then
                        seen[itemID] = true
                        tinsert(outputs, itemID)
                    end
                end
            end
        end
    end
    return outputs
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
