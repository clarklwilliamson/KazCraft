local addonName, ns = ...

local ProfRecipes = {}
ns.ProfRecipes = ProfRecipes

local LEFT_WIDTH = 300
local RECIPE_ROW_HEIGHT = 22
local REAGENT_ROW_HEIGHT = 26
local MAX_VISIBLE_ROWS = 28
local MAX_REAGENT_ROWS = 10

-- Difficulty colors
local DIFFICULTY_COLORS = {
    optimal  = { 1.0, 0.5, 0.1 },   -- orange
    medium   = { 1.0, 1.0, 0.0 },   -- yellow
    easy     = { 0.1, 1.0, 0.1 },   -- green
    trivial  = { 0.5, 0.5, 0.5 },   -- gray
    default  = { 0.86, 0.84, 0.78 }, -- brightText fallback
}

-- State
local initialized = false
local parentFrame
local leftPanel, rightPanel
local searchBox, filterBtn
local recipeScrollFrame, recipeContent
local detailFrame
local recipeRows = {}
local reagentRows = {}

-- Data
local displayList = {}      -- flattened list: { type, depth, catID, recipeID, info, collapsed, ... }
local selectedRecipeID = nil
local scrollOffset = 0
local isCrafting = false

-- Reagent slot state
local currentTransaction = nil
local currentSchematic = nil
local lastTransactionRecipeID = nil
local optionalSlotFrames = {}
local finishingSlotFrames = {}
local MAX_OPTIONAL_SLOTS = 5
local MAX_FINISHING_SLOTS = 3
local SLOT_BOX_SIZE = 40
local SLOT_BOX_SPACING = 6
local MAX_SPEC_NODE_ROWS = 8
local SPEC_NODE_ROW_HEIGHT = 20
local MAX_SIM_REAGENT_ROWS = 8
local SIM_FINISHING_SLOTS = 3

-- Sim panel state
local simRecipeData = nil     -- CraftSim.RecipeData for simulation
local simReagentRows = {}     -- UI rows for quality reagent editing
local simFinishingDrops = {}  -- Dropdown frames for finishing reagents

--------------------------------------------------------------------
-- Category tree → flat display list
--------------------------------------------------------------------
local function BuildCategoryTree(recipeIDs, childProfID, learnedFilter)
    -- Build category hierarchy for recipes matching learnedFilter
    -- learnedFilter: true = learned only, false = unlearned only, nil = all
    local categories = {}
    local rootCats = {}
    local hasAny = false

    for _, recipeID in ipairs(recipeIDs) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and (not childProfID or C_TradeSkillUI.IsRecipeInSkillLine(recipeID, childProfID)) then
            if learnedFilter == nil or info.learned == learnedFilter then
                hasAny = true
                local catID = info.categoryID
                local curCat = catID
                while curCat and curCat > 0 do
                    if not categories[curCat] then
                        local catInfo = C_TradeSkillUI.GetCategoryInfo(curCat)
                        categories[curCat] = {
                            name = catInfo and catInfo.name or ("Category " .. curCat),
                            parentCategoryID = catInfo and catInfo.parentCategoryID,
                            uiOrder = catInfo and catInfo.uiOrder or 0,
                            recipes = {},
                            subcats = {},
                        }
                    end
                    local parentID = categories[curCat].parentCategoryID
                    if parentID and parentID > 0 then
                        if not categories[parentID] then
                            local pInfo = C_TradeSkillUI.GetCategoryInfo(parentID)
                            categories[parentID] = {
                                name = pInfo and pInfo.name or ("Category " .. parentID),
                                parentCategoryID = pInfo and pInfo.parentCategoryID,
                                uiOrder = pInfo and pInfo.uiOrder or 0,
                                recipes = {},
                                subcats = {},
                            }
                        end
                        local found = false
                        for _, sc in ipairs(categories[parentID].subcats) do
                            if sc == curCat then found = true; break end
                        end
                        if not found then
                            table.insert(categories[parentID].subcats, curCat)
                        end
                    else
                        rootCats[curCat] = true
                    end
                    curCat = parentID
                end

                if categories[catID] then
                    table.insert(categories[catID].recipes, { recipeID = recipeID, info = info })
                end
            end
        end
    end

    return categories, rootCats, hasAny
end

local function FlattenTree(categories, rootCats, outList, collapses)
    -- Strip root wrapper categories
    local effectiveRoots = {}
    for catID in pairs(rootCats) do
        local cat = categories[catID]
        if cat and #cat.recipes == 0 and #cat.subcats > 0 then
            for _, subID in ipairs(cat.subcats) do
                effectiveRoots[subID] = true
            end
        else
            effectiveRoots[catID] = true
        end
    end

    local sortedRoots = {}
    for catID in pairs(effectiveRoots) do
        table.insert(sortedRoots, catID)
    end
    table.sort(sortedRoots, function(a, b)
        local oa = categories[a] and categories[a].uiOrder or 0
        local ob = categories[b] and categories[b].uiOrder or 0
        return oa < ob
    end)

    local function Flatten(catID, depth)
        local cat = categories[catID]
        if not cat then return end

        local isCollapsed = collapses[catID] or false

        table.insert(outList, {
            type = "category",
            catID = catID,
            name = cat.name,
            depth = depth,
            collapsed = isCollapsed,
        })

        if not isCollapsed then
            table.sort(cat.subcats, function(a, b)
                local oa = categories[a] and categories[a].uiOrder or 0
                local ob = categories[b] and categories[b].uiOrder or 0
                return oa < ob
            end)
            for _, subID in ipairs(cat.subcats) do
                Flatten(subID, depth + 1)
            end

            for _, r in ipairs(cat.recipes) do
                table.insert(outList, {
                    type = "recipe",
                    recipeID = r.recipeID,
                    info = r.info,
                    depth = depth + 1,
                })
            end
        end
    end

    for _, catID in ipairs(sortedRoots) do
        Flatten(catID, 0)
    end
end

local function BuildDisplayList()
    wipe(displayList)

    local recipeIDs = C_TradeSkillUI.GetFilteredRecipeIDs()
    if not recipeIDs or #recipeIDs == 0 then return end

    local childProfInfo = C_TradeSkillUI.GetChildProfessionInfo()
    local childProfID = childProfInfo and childProfInfo.professionID
    local collapses = KazCraftDB.profCollapses or {}

    local showLearned = C_TradeSkillUI.GetShowLearned()
    local showUnlearned = C_TradeSkillUI.GetShowUnlearned()

    if showLearned and showUnlearned then
        -- Both visible — learned first, separator, then unlearned
        local lCats, lRoots, hasLearned = BuildCategoryTree(recipeIDs, childProfID, true)
        local uCats, uRoots, hasUnlearned = BuildCategoryTree(recipeIDs, childProfID, false)

        if hasLearned then
            FlattenTree(lCats, lRoots, displayList, collapses)
        end
        if hasLearned and hasUnlearned then
            table.insert(displayList, { type = "separator", text = "Unlearned" })
        end
        if hasUnlearned then
            FlattenTree(uCats, uRoots, displayList, collapses)
        end
    else
        -- Only one group shown — no separator needed
        local cats, roots = BuildCategoryTree(recipeIDs, childProfID, nil)
        FlattenTree(cats, roots, displayList, collapses)
    end

    -- Push "Appendix" categories (and their children) below normal recipes
    -- Post-processes the flat displayList — plucks Appendix entries and re-inserts before Unlearned
    local sepIdx = nil
    for i, entry in ipairs(displayList) do
        if entry.type == "separator" then sepIdx = i; break end
    end

    local scanEnd = sepIdx and (sepIdx - 1) or #displayList
    local normal = {}
    local appendix = {}
    local tail = {}
    local inAppendix = false
    local appendixDepth = 0

    for i = 1, scanEnd do
        local entry = displayList[i]
        if entry.type == "category" and entry.name and entry.name:find("^Appendix") then
            inAppendix = true
            appendixDepth = entry.depth
            table.insert(appendix, entry)
        elseif inAppendix and entry.depth > appendixDepth then
            table.insert(appendix, entry)
        else
            inAppendix = false
            table.insert(normal, entry)
        end
    end

    if sepIdx then
        for i = sepIdx, #displayList do
            table.insert(tail, displayList[i])
        end
    end

    if #appendix > 0 then
        wipe(displayList)
        for _, e in ipairs(normal) do displayList[#displayList + 1] = e end
        -- Appendix entries hidden — reference-only recipes, never crafted
        for _, e in ipairs(tail) do displayList[#displayList + 1] = e end
    end
end

--------------------------------------------------------------------
-- Recipe difficulty color
--------------------------------------------------------------------
local function GetDifficultyColor(info)
    if not info then return DIFFICULTY_COLORS.default end
    if not info.learned then return DIFFICULTY_COLORS.trivial end  -- unlearned = grey
    local d = info.relativeDifficulty
    if d == nil then return DIFFICULTY_COLORS.default end
    if d == Enum.TradeskillRelativeDifficulty.Optimal then return DIFFICULTY_COLORS.optimal end
    if d == Enum.TradeskillRelativeDifficulty.Medium then return DIFFICULTY_COLORS.medium end
    if d == Enum.TradeskillRelativeDifficulty.Easy then return DIFFICULTY_COLORS.easy end
    if d == Enum.TradeskillRelativeDifficulty.Trivial then return DIFFICULTY_COLORS.trivial end
    return DIFFICULTY_COLORS.default
end

--------------------------------------------------------------------
-- Quality stars string
--------------------------------------------------------------------
local function GetQualityStars(info)
    if not info or not info.qualityIlvlBonuses then return "" end
    local maxQ = #info.qualityIlvlBonuses
    if maxQ <= 0 then return "" end
    -- Current learned quality (if applicable)
    local stars = ""
    for i = 1, maxQ do
        stars = stars .. "|cffffd700*|r"
    end
    return " " .. stars
end

--------------------------------------------------------------------
-- Recipe rows (virtual scroll)
--------------------------------------------------------------------
local function CreateRecipeRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(RECIPE_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * RECIPE_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * RECIPE_ROW_HEIGHT)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0)

    row.leftAccent = row:CreateTexture(nil, "ARTWORK", nil, 2)
    row.leftAccent:SetSize(2, RECIPE_ROW_HEIGHT)
    row.leftAccent:SetPoint("LEFT")
    row.leftAccent:SetColorTexture(unpack(ns.COLORS.accent))
    row.leftAccent:Hide()

    -- Arrow for categories
    row.arrow = row:CreateFontString(nil, "OVERLAY")
    row.arrow:SetFont(ns.FONT, 12, "")
    row.arrow:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Icon for recipes
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)

    -- Name
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 14, "")
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    -- Count (craftable) — left of icon
    row.countText = row:CreateFontString(nil, "OVERLAY")
    row.countText:SetFont(ns.FONT, 12, "")
    row.countText:SetTextColor(unpack(ns.COLORS.mutedText))
    row.countText:SetJustifyH("RIGHT")
    row.countText:SetWidth(20)

    -- Quality pip (atlas icon)
    row.qualityPip = row:CreateTexture(nil, "OVERLAY")
    row.qualityPip:SetSize(14, 14)
    row.qualityPip:Hide()

    -- Skill-up count (to the left of icon)
    row.skillUpText = row:CreateFontString(nil, "OVERLAY")
    row.skillUpText:SetFont(ns.FONT, 12, "")
    row.skillUpText:SetJustifyH("RIGHT")
    row.skillUpText:Hide()

    -- Favorite star
    row.favText = row:CreateFontString(nil, "OVERLAY")
    row.favText:SetFont(ns.FONT, 12, "")
    row.favText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.favText:SetText("|cffffd700*|r")
    row.favText:Hide()

    row.recipeID = nil

    row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        self.leftAccent:Show()
        if self.recipeID and IsShiftKeyDown() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetRecipeResultItem(self.recipeID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        if self._selected then
            self.bg:SetColorTexture(unpack(ns.COLORS.rowSelected))
        else
            self.bg:SetColorTexture(1, 1, 1, 0)
        end
        if not self._selected then
            self.leftAccent:Hide()
        end
        GameTooltip:Hide()
    end)
    row:SetScript("OnUpdate", function(self)
        if GameTooltip:IsOwned(self) and not IsShiftKeyDown() then
            GameTooltip:Hide()
        elseif not GameTooltip:IsOwned(self) and self.recipeID and IsShiftKeyDown() and self:IsMouseOver() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetRecipeResultItem(self.recipeID)
            GameTooltip:Show()
        end
    end)

    return row
end

local function UpdateRecipeRow(row, entry, index)
    if not entry then
        row:Hide()
        return
    end

    if entry.type == "separator" then
        -- Divider line with label
        row.recipeID = nil
        row:Show()
        row.icon:Hide()
        row.arrow:Hide()
        row.countText:Hide()
        row.favText:Hide()
        row.skillUpText:Hide()
        row.qualityPip:Hide()
        row._selected = false
        row.leftAccent:Hide()
        row.bg:SetColorTexture(1, 1, 1, 0)
        row.nameText:Show()
        row.nameText:ClearAllPoints()
        row.nameText:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.nameText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.nameText:SetText("|cff888888--- " .. (entry.text or "") .. " ---|r")
        row.nameText:SetFont(ns.FONT, 12, "")
        row.nameText:SetTextColor(unpack(ns.COLORS.mutedText))
        row:SetScript("OnClick", nil)
        return
    end

    local indent = entry.depth * 14

    if entry.type == "category" then
        -- Category row
        row.recipeID = nil
        row.icon:Hide()
        row.arrow:Show()
        row.arrow:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
        row.arrow:SetText(entry.collapsed and ">" or "v")

        row.nameText:Show()
        row.nameText:SetPoint("LEFT", row.arrow, "RIGHT", 4, 0)
        row.nameText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.nameText:SetText(entry.name)
        row.nameText:SetTextColor(unpack(ns.COLORS.headerText))
        row.nameText:SetFont(ns.FONT, 14, "")

        row.countText:SetText("")
        row.favText:Hide()
        row.skillUpText:Hide()
        row.qualityPip:Hide()
        row._selected = false
        row.leftAccent:Hide()
        row.bg:SetColorTexture(1, 1, 1, 0)

        row:SetScript("OnClick", function()
            if not KazCraftDB.profCollapses then
                KazCraftDB.profCollapses = {}
            end
            KazCraftDB.profCollapses[entry.catID] = not entry.collapsed
            ProfRecipes:RefreshRecipeList()
        end)
    else
        -- Recipe row
        local info = entry.info
        row.recipeID = entry.recipeID
        row.arrow:Hide()

        row.icon:Show()
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
        row.icon:SetTexture(info and info.icon or 134400)

        local craftable = C_TradeSkillUI.GetCraftableCount(entry.recipeID) or 0
        local recipeName = info and info.name or ("Recipe " .. entry.recipeID)
        if craftable > 0 then
            row.countText:SetFont(ns.FONT, 12, "")
            row.countText:SetText("|cffc8aa64[" .. craftable .. "]|r")
            row.countText:SetWidth(0)
            row.countText:Show()
        else
            row.countText:Hide()
        end

        -- Skill-up count (to the left of the icon in the indent space)
        local numSkillUps = info and info.numSkillUps or 0
        local color = GetDifficultyColor(info)
        if numSkillUps > 1 then
            row.skillUpText:ClearAllPoints()
            row.skillUpText:SetPoint("RIGHT", row.icon, "LEFT", -2, 0)
            row.skillUpText:SetText(numSkillUps)
            row.skillUpText:SetTextColor(color[1], color[2], color[3])
            row.skillUpText:Show()
        else
            row.skillUpText:Hide()
        end

        row.nameText:Show()
        row.nameText:ClearAllPoints()
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.nameText:SetPoint("RIGHT", row, "RIGHT", -20, 0)
        row.nameText:SetText(recipeName)
        row.nameText:SetFont(ns.FONT, 14, "")
        row.nameText:SetTextColor(color[1], color[2], color[3])

        -- Favorite
        if info and info.favorite then
            row.favText:Show()
        else
            row.favText:Hide()
        end

        -- Quality pip — show achievable tier for recipes with quality
        local hasQuality = info and (info.supportsQualities or (info.qualityIlvlBonuses and #info.qualityIlvlBonuses > 0))
        if hasQuality and ProfessionsUtil and Professions then
            local tempSchematic = ProfessionsUtil.GetRecipeSchematic(entry.recipeID, false)
            local tempTxn = CreateProfessionsRecipeTransaction(tempSchematic)
            pcall(Professions.AllocateAllBasicReagents, tempTxn, true)
            local tempReagents = tempTxn:CreateCraftingReagentInfoTbl() or {}
            local opInfo = C_TradeSkillUI.GetCraftingOperationInfo(entry.recipeID, tempReagents, nil, false)
            local qTier = opInfo and opInfo.craftingQuality or 0
            if qTier > 0 then
                row.qualityPip:SetAtlas("Professions-Icon-Quality-Tier" .. qTier .. "-Small", false)
                row.qualityPip:Show()
            else
                row.qualityPip:Hide()
            end
        else
            row.qualityPip:Hide()
        end

        -- Right-side anchor chain: name truncates before rightmost elements
        local rightAnchor = row
        local rightPoint = "RIGHT"
        local rightOfs = -4
        if row.qualityPip:IsShown() then
            row.qualityPip:ClearAllPoints()
            row.qualityPip:SetPoint("RIGHT", rightAnchor, rightPoint, rightOfs, 0)
            rightAnchor = row.qualityPip
            rightPoint = "LEFT"
            rightOfs = -1
        end
        if row.countText:IsShown() then
            row.countText:ClearAllPoints()
            row.countText:SetPoint("RIGHT", rightAnchor, rightPoint, rightOfs, 0)
            rightAnchor = row.countText
            rightPoint = "LEFT"
            rightOfs = -2
        end
        if row.favText:IsShown() then
            row.favText:ClearAllPoints()
            row.favText:SetPoint("RIGHT", rightAnchor, rightPoint, rightOfs, 0)
            rightAnchor = row.favText
            rightPoint = "LEFT"
            rightOfs = -2
        end
        row.nameText:SetPoint("RIGHT", rightAnchor, rightPoint, rightOfs, 0)

        -- Selection highlight
        local isSelected = (entry.recipeID == selectedRecipeID)
        row._selected = isSelected
        if isSelected then
            row.bg:SetColorTexture(unpack(ns.COLORS.rowSelected))
            row.leftAccent:Show()
        else
            row.bg:SetColorTexture(1, 1, 1, 0)
            row.leftAccent:Hide()
        end

        row:SetScript("OnClick", function()
            if CloseProfessionsItemFlyout then
                pcall(CloseProfessionsItemFlyout)
            end
            selectedRecipeID = entry.recipeID
            if KazCraftDB and ns.currentProfName then
                if type(KazCraftDB.lastRecipeID) ~= "table" then KazCraftDB.lastRecipeID = {} end
                KazCraftDB.lastRecipeID[ns.currentProfName] = selectedRecipeID
            end
            ProfRecipes:RefreshRows()
            ProfRecipes:RefreshDetail()
            -- Sync selection to docked queue panel
            if ns.ProfessionUI then
                ns.ProfessionUI:SetSelectedRecipe(entry.recipeID)
            end
            -- Notify CraftSim so its spec info / module windows update
            -- pcall: CraftSim reads Blizzard's schematic form which may be stale
            if CraftSimLib and CraftSimLib.INIT and CraftSimLib.INIT.TriggerModuleUpdate then
                CraftSimLib.INIT.currentRecipeID = entry.recipeID
                pcall(CraftSimLib.INIT.TriggerModuleUpdate, CraftSimLib.INIT, false)
            end
        end)
    end

    row:Show()
end

--------------------------------------------------------------------
-- Scroll handling
--------------------------------------------------------------------
local recipeScrollbar, recipeScrollThumb

local function UpdateRecipeScrollbar()
    if not recipeScrollbar then return end
    local total = #displayList
    if total <= MAX_VISIBLE_ROWS then
        recipeScrollbar:Hide()
        return
    end
    recipeScrollbar:Show()
    local trackHeight = recipeScrollbar:GetHeight()
    local thumbRatio = MAX_VISIBLE_ROWS / total
    local thumbHeight = math.max(20, trackHeight * thumbRatio)
    recipeScrollThumb:SetHeight(thumbHeight)
    local maxScroll = total - MAX_VISIBLE_ROWS
    local scrollPct = (maxScroll > 0) and (scrollOffset / maxScroll) or 0
    local thumbOffset = scrollPct * (trackHeight - thumbHeight)
    recipeScrollThumb:SetPoint("TOP", recipeScrollbar, "TOP", 0, -thumbOffset)
end

local function OnRecipeScroll(self, delta)
    scrollOffset = math.max(0, math.min(scrollOffset - delta * 5, math.max(0, #displayList - MAX_VISIBLE_ROWS)))
    ProfRecipes:RefreshRows()
end

--------------------------------------------------------------------
-- Left panel: search + filter + recipe list
--------------------------------------------------------------------
local function CreateLeftPanel(parent)
    leftPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    leftPanel:SetWidth(LEFT_WIDTH)
    leftPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    leftPanel:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    leftPanel:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    leftPanel:SetBackdropColor(unpack(ns.COLORS.panelBg))
    leftPanel:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- Search box
    searchBox = CreateFrame("EditBox", nil, leftPanel, "BackdropTemplate")
    searchBox:SetSize(LEFT_WIDTH - 44, 22)
    searchBox:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 6, -6)
    searchBox:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    searchBox:SetBackdropColor(unpack(ns.COLORS.searchBg))
    searchBox:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    searchBox:SetFont(ns.FONT, 14, "")
    searchBox:SetTextColor(unpack(ns.COLORS.brightText))
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(40)

    -- Placeholder text
    searchBox.placeholder = searchBox:CreateFontString(nil, "OVERLAY")
    searchBox.placeholder:SetFont(ns.FONT, 14, "")
    searchBox.placeholder:SetPoint("LEFT", searchBox, "LEFT", 6, 0)
    searchBox.placeholder:SetText("Search...")
    searchBox.placeholder:SetTextColor(unpack(ns.COLORS.mutedText))

    searchBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        if text == "" then
            searchBox.placeholder:Show()
        else
            searchBox.placeholder:Hide()
        end
        C_TradeSkillUI.SetRecipeItemNameFilter(text)
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    searchBox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchFocus))
    end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    end)

    -- Filter button
    filterBtn = ns.CreateButton(leftPanel, "F", 26, 22)
    filterBtn:SetPoint("LEFT", searchBox, "RIGHT", 4, 0)
    filterBtn:SetScript("OnClick", function(self)
        ProfRecipes:ToggleFilterMenu(self)
    end)

    -- Recipe list area
    recipeContent = CreateFrame("Frame", nil, leftPanel)
    recipeContent:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, -34)
    recipeContent:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", 0, 0)
    recipeContent:SetClipsChildren(true)
    recipeContent:EnableMouseWheel(true)
    recipeContent:SetScript("OnMouseWheel", OnRecipeScroll)

    -- Scrollbar (6px, right edge of recipe list)
    recipeScrollbar = CreateFrame("Frame", nil, recipeContent)
    recipeScrollbar:SetWidth(6)
    recipeScrollbar:SetPoint("TOPRIGHT", recipeContent, "TOPRIGHT", -1, -1)
    recipeScrollbar:SetPoint("BOTTOMRIGHT", recipeContent, "BOTTOMRIGHT", -1, 1)
    local scrollTrack = recipeScrollbar:CreateTexture(nil, "BACKGROUND")
    scrollTrack:SetAllPoints()
    scrollTrack:SetColorTexture(1, 1, 1, 0.06)

    recipeScrollThumb = CreateFrame("Frame", nil, recipeScrollbar)
    recipeScrollThumb:SetWidth(6)
    recipeScrollThumb:SetHeight(40)
    recipeScrollThumb:SetPoint("TOP", recipeScrollbar, "TOP", 0, 0)
    local thumbTex = recipeScrollThumb:CreateTexture(nil, "OVERLAY")
    thumbTex:SetAllPoints()
    thumbTex:SetColorTexture(unpack(ns.COLORS.scrollThumb or {0.5, 0.45, 0.35, 0.6}))

    -- Pre-allocate recipe rows
    for i = 1, MAX_VISIBLE_ROWS do
        recipeRows[i] = CreateRecipeRow(recipeContent, i)
    end
end

--------------------------------------------------------------------
-- Filter dropdown menu (scrollable, with Sources & Slots submenus)
--------------------------------------------------------------------
local filterMenu
local filterRows = {}
local filterScrollOffset = 0
local filterDisplayList = {}
local sourcesExpanded = false
local slotsExpanded = false
local FILTER_ROW_HEIGHT = 22
local MAX_FILTER_ROWS = 16

-- Source type names (matches BATTLE_PET_SOURCE_N globals)
local SOURCE_NAMES = {
    [1] = "Drop",
    [2] = "Quest",
    [3] = "Vendor",
    [4] = "Profession",
    [5] = "Wild Pet",
    [6] = "Achievement",
    [7] = "World Event",
    [8] = "Promotion",
    [9] = "TCG",
    [10] = "Pet Store",
    [11] = "Discovery",
    [12] = "Trading Post",
}

local function BuildFilterDisplayList()
    filterDisplayList = {}
    -- Top-level checkboxes
    table.insert(filterDisplayList, { type = "check", text = "Show Learned",
        getter = function() return C_TradeSkillUI.GetShowLearned() end,
        setter = function(v) C_TradeSkillUI.SetShowLearned(v) end })
    table.insert(filterDisplayList, { type = "check", text = "Show Unlearned",
        getter = function() return C_TradeSkillUI.GetShowUnlearned() end,
        setter = function(v) C_TradeSkillUI.SetShowUnlearned(v) end })
    table.insert(filterDisplayList, { type = "check", text = "Has Skill Up",
        getter = function() return C_TradeSkillUI.GetOnlyShowSkillUpRecipes() end,
        setter = function(v) C_TradeSkillUI.SetOnlyShowSkillUpRecipes(v) end })
    table.insert(filterDisplayList, { type = "check", text = "First Craft",
        getter = function() return C_TradeSkillUI.GetOnlyShowFirstCraftRecipes() end,
        setter = function(v) C_TradeSkillUI.SetOnlyShowFirstCraftRecipes(v) end })
    table.insert(filterDisplayList, { type = "check", text = "Have Materials",
        getter = function() return C_TradeSkillUI.GetOnlyShowMakeableRecipes() end,
        setter = function(v) C_TradeSkillUI.SetOnlyShowMakeableRecipes(v) end })

    -- Sources header
    table.insert(filterDisplayList, { type = "header", text = "Sources", expanded = sourcesExpanded,
        toggle = function() sourcesExpanded = not sourcesExpanded end })
    if sourcesExpanded then
        for sourceIdx = 1, 12 do
            local name = SOURCE_NAMES[sourceIdx]
            if name and C_TradeSkillUI.IsAnyRecipeFromSource(sourceIdx) then
                table.insert(filterDisplayList, { type = "check", text = name, indent = true,
                    getter = function() return not C_TradeSkillUI.IsRecipeSourceTypeFiltered(sourceIdx) end,
                    setter = function(v) C_TradeSkillUI.SetRecipeSourceTypeFilter(sourceIdx, not v) end })
            end
        end
    end

    -- Slots header
    local slotCount = C_TradeSkillUI.GetAllFilterableInventorySlotsCount() or 0
    if slotCount > 0 then
        table.insert(filterDisplayList, { type = "header", text = "Slots", expanded = slotsExpanded,
            toggle = function() slotsExpanded = not slotsExpanded end })
        if slotsExpanded then
            for slotIdx = 1, slotCount do
                local name = C_TradeSkillUI.GetFilterableInventorySlotName(slotIdx)
                if name and name ~= "" then
                    table.insert(filterDisplayList, { type = "check", text = name, indent = true,
                        getter = function() return not C_TradeSkillUI.IsInventorySlotFiltered(slotIdx) end,
                        setter = function(v) C_TradeSkillUI.SetInventorySlotFilter(slotIdx, not v) end })
                end
            end
        end
    end
end

local function CreateFilterRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(FILTER_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * FILTER_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * FILTER_ROW_HEIGHT)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", row, "LEFT", 6, 0)

    row.arrow = row:CreateFontString(nil, "OVERLAY")
    row.arrow:SetFont(ns.FONT, 12, "")
    row.arrow:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.arrow:SetTextColor(unpack(ns.COLORS.mutedText))

    row.label = row:CreateFontString(nil, "OVERLAY")
    row.label:SetFont(ns.FONT, 14, "")
    row.label:SetTextColor(unpack(ns.COLORS.brightText))

    -- Full-row clickable button (for headers AND checkboxes)
    row.hitBtn = CreateFrame("Button", nil, row)
    row.hitBtn:SetAllPoints()
    row.hitBtn:Hide()
    row.hitBtn:RegisterForClicks("LeftButtonUp")

    return row
end

local function UpdateFilterRow(row, entry)
    if not entry then
        row:Hide()
        return
    end
    row:Show()

    -- Reset all elements
    row.check:Hide()
    row.arrow:Hide()
    row.label:SetText("")
    row.hitBtn:Hide()
    row.hitBtn:SetScript("OnClick", nil)

    if entry.type == "header" then
        row.arrow:Show()
        row.arrow:SetText(entry.expanded and "v" or ">")
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", row.arrow, "RIGHT", 4, 0)
        row.label:SetText(entry.text)
        row.label:SetFont(ns.FONT, 14, "")
        row.label:SetTextColor(unpack(ns.COLORS.headerText))
        row.hitBtn:Show()
        row.hitBtn:SetScript("OnClick", function()
            entry.toggle()
            BuildFilterDisplayList()
            ProfRecipes:RefreshFilterMenu()
        end)
    else
        row.check:Show()
        row.check:ClearAllPoints()
        row.check:SetPoint("LEFT", row, "LEFT", entry.indent and 20 or 6, 0)
        row.check:SetChecked(entry.getter())
        row.check:SetScript("OnClick", function(self)
            entry.setter(self:GetChecked())
        end)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
        row.label:SetText(entry.text)
        row.label:SetFont(ns.FONT, 14, "")
        row.label:SetTextColor(unpack(ns.COLORS.brightText))
        -- Full row click toggles the checkbox
        row.hitBtn:Show()
        row.hitBtn:SetScript("OnClick", function()
            local newVal = not entry.getter()
            entry.setter(newVal)
            row.check:SetChecked(newVal)
        end)
    end
end

function ProfRecipes:RefreshFilterMenu()
    local visCount = math.min(#filterDisplayList, MAX_FILTER_ROWS)
    local menuHeight = visCount * FILTER_ROW_HEIGHT + 8
    filterMenu:SetSize(190, menuHeight)

    filterScrollOffset = math.max(0, math.min(filterScrollOffset, #filterDisplayList - MAX_FILTER_ROWS))
    for i = 1, MAX_FILTER_ROWS do
        local entry = filterDisplayList[i + filterScrollOffset]
        if not filterRows[i] then
            filterRows[i] = CreateFilterRow(filterMenu, i)
        end
        UpdateFilterRow(filterRows[i], entry)
    end
    for i = MAX_FILTER_ROWS + 1, #filterRows do
        filterRows[i]:Hide()
    end
end

function ProfRecipes:ToggleFilterMenu(anchorBtn)
    if filterMenu and filterMenu:IsShown() then
        filterMenu:Hide()
        return
    end

    if not filterMenu then
        filterMenu = CreateFrame("Frame", nil, leftPanel, "BackdropTemplate")
        filterMenu:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        filterMenu:SetBackdropColor(20/255, 20/255, 20/255, 0.98)
        filterMenu:SetBackdropBorderColor(unpack(ns.COLORS.accent))
        filterMenu:SetFrameStrata("DIALOG")
        filterMenu:SetClipsChildren(true)
        filterMenu:EnableMouse(true)
        filterMenu:EnableMouseWheel(true)
        filterMenu:SetScript("OnMouseWheel", function(self, delta)
            filterScrollOffset = math.max(0, math.min(filterScrollOffset - delta, math.max(0, #filterDisplayList - MAX_FILTER_ROWS)))
            ProfRecipes:RefreshFilterMenu()
        end)
    end

    filterScrollOffset = 0
    BuildFilterDisplayList()
    ProfRecipes:RefreshFilterMenu()

    filterMenu:ClearAllPoints()
    filterMenu:SetPoint("TOPRIGHT", anchorBtn, "BOTTOMRIGHT", 0, -2)
    filterMenu:Show()
end

--------------------------------------------------------------------
-- Right panel: recipe detail + reagents + craft controls + queue
--------------------------------------------------------------------
local detail = {} -- UI element refs

local function CreateReagentRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(REAGENT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * REAGENT_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * REAGENT_ROW_HEIGHT)
    row:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

    row.countText = row:CreateFontString(nil, "OVERLAY")
    row.countText:SetFont(ns.FONT, 14, "")
    row.countText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.countText:SetJustifyH("LEFT")

    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 14, "")
    row.nameText:SetPoint("LEFT", row.countText, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    row.checkText = nil  -- merged into countText
    row.itemID = nil

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self.itemID and IsShiftKeyDown() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    row:SetScript("OnUpdate", function(self)
        if GameTooltip:IsOwned(self) and not IsShiftKeyDown() then
            GameTooltip:Hide()
        elseif not GameTooltip:IsOwned(self) and self.itemID and IsShiftKeyDown() and self:IsMouseOver() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end
    end)

    return row
end

--------------------------------------------------------------------
-- Reagent slot box (40x40 icon button for Optional/Finishing)
--------------------------------------------------------------------
local function CreateReagentSlotBox(parent, index)
    local box = CreateFrame("Button", nil, parent, "BackdropTemplate")
    box:SetSize(SLOT_BOX_SIZE, SLOT_BOX_SIZE)
    box:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    box:SetBackdropColor(8/255, 8/255, 8/255, 1)
    box:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
    box:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    box.icon = box:CreateTexture(nil, "ARTWORK")
    box.icon:SetSize(32, 32)
    box.icon:SetPoint("CENTER")
    box.icon:Hide()

    box.plusText = box:CreateFontString(nil, "OVERLAY")
    box.plusText:SetFont(ns.FONT, 18, "")
    box.plusText:SetPoint("CENTER")
    box.plusText:SetText("+")
    box.plusText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- State
    box.slotIndex = nil
    box.slotSchematic = nil
    box.itemID = nil

    box:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.accent))
        if IsShiftKeyDown() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.itemID then
                GameTooltip:SetItemByID(self.itemID)
            elseif self.slotSchematic then
                GameTooltip:SetText(self.slotSchematic.slotText or "Optional Reagent", 1, 1, 1)
                GameTooltip:AddLine("Click to select a reagent", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end
    end)
    box:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
        GameTooltip:Hide()
    end)
    box:SetScript("OnUpdate", function(self)
        if GameTooltip:IsOwned(self) and not IsShiftKeyDown() then
            GameTooltip:Hide()
        elseif not GameTooltip:IsOwned(self) and IsShiftKeyDown() and self:IsMouseOver() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.itemID then
                GameTooltip:SetItemByID(self.itemID)
            elseif self.slotSchematic then
                GameTooltip:SetText(self.slotSchematic.slotText or "Optional Reagent", 1, 1, 1)
                GameTooltip:AddLine("Click to select a reagent", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end
    end)

    box:Hide()
    return box
end

local function CreateRightPanel(parent)
    rightPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 0, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    rightPanel:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    rightPanel:SetBackdropColor(unpack(ns.COLORS.panelBg))
    rightPanel:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- Detail content (direct child, full area)
    detailFrame = CreateFrame("Frame", nil, rightPanel)
    detailFrame:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 4, -4)
    detailFrame:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -4, 4)

    -- Recipe name
    detail.nameText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.nameText:SetFont(ns.FONT, 16, "")
    detail.nameText:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 8, -8)
    detail.nameText:SetPoint("RIGHT", detailFrame, "RIGHT", -40, 0)
    detail.nameText:SetJustifyH("LEFT")
    detail.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Favorite star toggle
    detail.favBtn = CreateFrame("Button", nil, detailFrame)
    detail.favBtn:SetSize(20, 20)
    detail.favBtn:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -8, -8)
    detail.favBtn.t = detail.favBtn:CreateFontString(nil, "OVERLAY")
    detail.favBtn.t:SetFont(ns.FONT, 16, "")
    detail.favBtn.t:SetPoint("CENTER")
    detail.favBtn.t:SetText("*")
    detail.favBtn.t:SetTextColor(unpack(ns.COLORS.mutedText))
    detail.favBtn:SetScript("OnClick", function()
        if selectedRecipeID then
            local info = C_TradeSkillUI.GetRecipeInfo(selectedRecipeID)
            if info then
                C_TradeSkillUI.SetRecipeFavorite(selectedRecipeID, not info.favorite)
            end
        end
    end)

    -- Recipe icon + subtext
    detail.icon = detailFrame:CreateTexture(nil, "ARTWORK")
    detail.icon:SetSize(32, 32)
    detail.icon:SetPoint("TOPLEFT", detail.nameText, "BOTTOMLEFT", 0, -6)

    -- Invisible overlay for Shift-tooltip on the recipe output icon
    detail.iconBtn = CreateFrame("Button", nil, detailFrame)
    detail.iconBtn:SetAllPoints(detail.icon)
    detail.iconBtn:SetFrameLevel(detailFrame:GetFrameLevel() + 5)
    detail.iconBtn.recipeID = nil
    detail.iconBtn:SetScript("OnEnter", function(self)
        if self.recipeID and IsShiftKeyDown() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetRecipeResultItem(self.recipeID)
            GameTooltip:Show()
        end
    end)
    detail.iconBtn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    detail.iconBtn:SetScript("OnUpdate", function(self)
        if GameTooltip:IsOwned(self) and not IsShiftKeyDown() then
            GameTooltip:Hide()
        elseif not GameTooltip:IsOwned(self) and self.recipeID and IsShiftKeyDown() and self:IsMouseOver() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetRecipeResultItem(self.recipeID)
            GameTooltip:Show()
        end
    end)

    -- Quality pip overlay on recipe output icon
    detail.iconQualityPip = detailFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    detail.iconQualityPip:SetSize(16, 16)
    detail.iconQualityPip:SetPoint("TOPLEFT", detail.icon, "TOPLEFT", -2, 2)
    detail.iconQualityPip:Hide()

    detail.subtypeText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.subtypeText:SetFont(ns.FONT, 14, "")
    detail.subtypeText:SetPoint("LEFT", detail.icon, "RIGHT", 8, 0)
    detail.subtypeText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Recipe description / flavor text
    detail.descText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.descText:SetFont(ns.FONT, 12, "")
    detail.descText:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -6)
    detail.descText:SetPoint("RIGHT", detailFrame, "RIGHT", -12, 0)
    detail.descText:SetJustifyH("LEFT")
    detail.descText:SetWordWrap(true)
    detail.descText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- ── Reagents ── (anchored dynamically below description)
    detail.reagentHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.reagentHeader:SetFont(ns.FONT, 12, "")
    detail.reagentHeader:SetText("REAGENTS")
    detail.reagentHeader:SetTextColor(unpack(ns.COLORS.headerText))

    detail.reagentFrame = CreateFrame("Frame", nil, detailFrame)
    -- anchored dynamically in RefreshDetail below reagentHeader
    detail.reagentFrame:SetHeight(MAX_REAGENT_ROWS * REAGENT_ROW_HEIGHT)

    for i = 1, MAX_REAGENT_ROWS do
        reagentRows[i] = CreateReagentRow(detail.reagentFrame, i)
    end

    -- ── Salvage slot (Disassemble, Scour, Pilfer) ──
    detail.salvageBox = CreateReagentSlotBox(detailFrame, 1)
    detail.salvageBox:Hide()

    -- ── Recraft slot (Recraft Equipment) ──
    detail.recraftBox = CreateReagentSlotBox(detailFrame, 1)
    detail.recraftBox:Hide()

    -- Recraft preview: input → output
    detail.recraftArrow = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.recraftArrow:SetFont(ns.FONT, 18, "")
    detail.recraftArrow:SetText(">")
    detail.recraftArrow:SetTextColor(unpack(ns.COLORS.mutedText))
    detail.recraftArrow:Hide()

    detail.recraftOutput = CreateReagentSlotBox(detailFrame, 2)
    detail.recraftOutput:Hide()
    detail.recraftOutput:SetScript("OnClick", nil) -- output box is display-only

    -- ── Enchant target slot ──
    detail.enchantHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.enchantHeader:SetFont(ns.FONT, 12, "")
    detail.enchantHeader:SetText("ENCHANT TARGET")
    detail.enchantHeader:SetTextColor(unpack(ns.COLORS.headerText))
    detail.enchantHeader:Hide()

    detail.enchantBox = CreateReagentSlotBox(detailFrame, 1)
    detail.enchantBox:Hide()

    detail.enchantName = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.enchantName:SetFont(ns.FONT, 11, "")
    detail.enchantName:SetPoint("LEFT", detail.enchantBox, "RIGHT", 8, 0)
    detail.enchantName:SetTextColor(unpack(ns.COLORS.brightText))
    detail.enchantName:SetText("Select an item to enchant")
    detail.enchantName:Hide()

    -- ── Optional Reagents ──
    detail.optionalHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.optionalHeader:SetFont(ns.FONT, 12, "")
    detail.optionalHeader:SetText("OPTIONAL REAGENTS")
    detail.optionalHeader:SetTextColor(unpack(ns.COLORS.headerText))
    detail.optionalHeader:Hide()

    detail.optionalFrame = CreateFrame("Frame", nil, detailFrame)
    detail.optionalFrame:SetHeight(SLOT_BOX_SIZE)
    detail.optionalFrame:SetPoint("LEFT", detailFrame, "LEFT", 8, 0)
    detail.optionalFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    detail.optionalFrame:Hide()

    for i = 1, MAX_OPTIONAL_SLOTS do
        optionalSlotFrames[i] = CreateReagentSlotBox(detail.optionalFrame, i)
    end

    -- ── Finishing Reagents ──
    detail.finishingHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.finishingHeader:SetFont(ns.FONT, 12, "")
    detail.finishingHeader:SetText("FINISHING REAGENTS")
    detail.finishingHeader:SetTextColor(unpack(ns.COLORS.headerText))
    detail.finishingHeader:Hide()

    detail.finishingFrame = CreateFrame("Frame", nil, detailFrame)
    detail.finishingFrame:SetHeight(SLOT_BOX_SIZE)
    detail.finishingFrame:SetPoint("LEFT", detailFrame, "LEFT", 8, 0)
    detail.finishingFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    detail.finishingFrame:Hide()

    for i = 1, MAX_FINISHING_SLOTS do
        finishingSlotFrames[i] = CreateReagentSlotBox(detail.finishingFrame, i)
    end

    -- ── Details ──
    detail.detailHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.detailHeader:SetFont(ns.FONT, 12, "")
    detail.detailHeader:SetText("DETAILS")
    detail.detailHeader:SetTextColor(unpack(ns.COLORS.headerText))
    -- anchored dynamically after reagents

    detail.qualityText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.qualityText:SetFont(ns.FONT, 14, "")
    detail.qualityText:SetTextColor(unpack(ns.COLORS.brightText))

    detail.skillText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.skillText:SetFont(ns.FONT, 14, "")
    detail.skillText:SetTextColor(unpack(ns.COLORS.mutedText))

    detail.concText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.concText:SetFont(ns.FONT, 14, "")
    detail.concText:SetTextColor(unpack(ns.COLORS.mutedText))

    detail.cooldownText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.cooldownText:SetFont(ns.FONT, 14, "")
    detail.cooldownText:SetTextColor(0.9, 0.3, 0.3, 1)

    -- Recipe source info box (unlearned / next rank)
    detail.sourceFrame = CreateFrame("Frame", nil, detailFrame, "BackdropTemplate")
    detail.sourceFrame:SetPoint("LEFT", detailFrame, "LEFT", 8, 0)
    detail.sourceFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    detail.sourceFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    detail.sourceFrame:SetBackdropColor(40/255, 35/255, 20/255, 0.9)
    detail.sourceFrame:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.6)
    detail.sourceFrame:Hide()

    detail.sourceIcon = detail.sourceFrame:CreateTexture(nil, "ARTWORK")
    detail.sourceIcon:SetSize(16, 16)
    detail.sourceIcon:SetPoint("TOPLEFT", detail.sourceFrame, "TOPLEFT", 6, -6)
    detail.sourceIcon:SetTexture("Interface\\common\\help-i")

    detail.sourceLabel = detail.sourceFrame:CreateFontString(nil, "OVERLAY")
    detail.sourceLabel:SetFont(ns.FONT, 12, "")
    detail.sourceLabel:SetPoint("TOPLEFT", detail.sourceIcon, "TOPRIGHT", 4, 1)
    detail.sourceLabel:SetTextColor(1, 0.82, 0)

    detail.sourceText = detail.sourceFrame:CreateFontString(nil, "OVERLAY")
    detail.sourceText:SetFont(ns.FONT, 14, "")
    detail.sourceText:SetPoint("TOPLEFT", detail.sourceLabel, "BOTTOMLEFT", 0, -4)
    detail.sourceText:SetPoint("RIGHT", detail.sourceFrame, "RIGHT", -8, 0)
    detail.sourceText:SetJustifyH("LEFT")
    detail.sourceText:SetWordWrap(true)
    detail.sourceText:SetTextColor(unpack(ns.COLORS.brightText))

    -- ── CraftSim Specialization Info ──
    detail.specHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.specHeader:SetFont(ns.FONT, 12, "")
    detail.specHeader:SetText("SPECIALIZATIONS")
    detail.specHeader:SetTextColor(unpack(ns.COLORS.headerText))
    detail.specHeader:Hide()

    detail.specStatsText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.specStatsText:SetFont(ns.FONT, 11, "")
    detail.specStatsText:SetPoint("TOPLEFT", detail.specHeader, "BOTTOMLEFT", 0, -4)
    detail.specStatsText:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    detail.specStatsText:SetJustifyH("LEFT")
    detail.specStatsText:SetTextColor(unpack(ns.COLORS.brightText))
    detail.specStatsText:Hide()

    detail.specNodeFrame = CreateFrame("Frame", nil, detailFrame)
    detail.specNodeFrame:SetSize(200, MAX_SPEC_NODE_ROWS * SPEC_NODE_ROW_HEIGHT)
    detail.specNodeFrame:Hide()

    detail.specNodeRows = {}
    for i = 1, MAX_SPEC_NODE_ROWS do
        local row = CreateFrame("Frame", nil, detail.specNodeFrame)
        row:SetHeight(SPEC_NODE_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", detail.specNodeFrame, "TOPRIGHT", 0, -(i - 1) * SPEC_NODE_ROW_HEIGHT)
        row:SetWidth(200)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

        row.nameText = row:CreateFontString(nil, "OVERLAY")
        row.nameText:SetFont(ns.FONT, 11, "")
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.nameText:SetJustifyH("LEFT")

        row.rankText = row:CreateFontString(nil, "OVERLAY")
        row.rankText:SetFont(ns.FONT, 11, "")
        row.rankText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.rankText:SetJustifyH("RIGHT")

        row:Hide()
        detail.specNodeRows[i] = row
    end

    -- ── SIM Panel ──
    detail.simFrame = CreateFrame("Frame", nil, detailFrame, "BackdropTemplate")
    detail.simFrame:SetPoint("LEFT", detailFrame, "LEFT", 8, 0)
    detail.simFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    detail.simFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    detail.simFrame:SetBackdropColor(22/255, 22/255, 22/255, 0.95)
    detail.simFrame:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
    detail.simFrame:Hide()

    detail.simHeader = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simHeader:SetFont(ns.FONT, 12, "")
    detail.simHeader:SetText("SIM")
    detail.simHeader:SetTextColor(unpack(ns.COLORS.headerText))
    detail.simHeader:SetPoint("TOPLEFT", detail.simFrame, "TOPLEFT", 8, -6)

    -- Reagent quality label
    detail.simReagentLabel = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simReagentLabel:SetFont(ns.FONT, 11, "")
    detail.simReagentLabel:SetText("Reagent Quality:")
    detail.simReagentLabel:SetTextColor(unpack(ns.COLORS.mutedText))
    detail.simReagentLabel:SetPoint("TOPLEFT", detail.simHeader, "BOTTOMLEFT", 0, -6)

    -- Container for reagent rows
    detail.simReagentFrame = CreateFrame("Frame", nil, detail.simFrame)
    detail.simReagentFrame:SetPoint("TOPLEFT", detail.simReagentLabel, "BOTTOMLEFT", 0, -4)
    detail.simReagentFrame:SetPoint("RIGHT", detail.simFrame, "RIGHT", -8, 0)
    detail.simReagentFrame:SetHeight(MAX_SIM_REAGENT_ROWS * 24)

    for i = 1, MAX_SIM_REAGENT_ROWS do
        local row = CreateFrame("Frame", nil, detail.simReagentFrame)
        row:SetHeight(22)
        row:SetPoint("TOPLEFT", detail.simReagentFrame, "TOPLEFT", 0, -(i - 1) * 24)
        row:SetPoint("RIGHT", detail.simReagentFrame, "RIGHT", 0, 0)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

        -- Invisible overlay for shift-tooltip on reagent icon
        row.iconBtn = CreateFrame("Button", nil, row)
        row.iconBtn:SetAllPoints(row.icon)
        row.iconBtn:SetFrameLevel(row:GetFrameLevel() + 5)
        row.iconBtn.itemID = nil
        row.iconBtn:SetScript("OnEnter", function(self)
            if self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.itemID)
                GameTooltip:Show()
            end
        end)
        row.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Three editboxes for R1/R2/R3 quantities
        row.edits = {}
        for t = 1, 3 do
            local eb = CreateFrame("EditBox", nil, row, "BackdropTemplate")
            eb:SetSize(28, 18)
            if t == 1 then
                eb:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
            else
                eb:SetPoint("LEFT", row.edits[t - 1], "RIGHT", 4, 0)
            end
            eb:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeSize = 1,
            })
            eb:SetBackdropColor(unpack(ns.COLORS.searchBg))
            local tierColors = { {1,1,1}, {0.3,1,0.3}, {0.3,0.6,1} }
            eb:SetBackdropBorderColor(tierColors[t][1], tierColors[t][2], tierColors[t][3], 0.5)
            eb:SetFont(ns.FONT, 11, "")
            eb:SetTextColor(unpack(ns.COLORS.brightText))
            eb:SetJustifyH("CENTER")
            eb:SetAutoFocus(false)
            eb:SetNumeric(true)
            eb:SetMaxLetters(3)
            eb:SetText("0")
            eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
            eb:SetScript("OnEditFocusLost", function() ProfRecipes:RefreshSimResults() end)
            row.edits[t] = eb
        end

        -- Total label
        row.totalText = row:CreateFontString(nil, "OVERLAY")
        row.totalText:SetFont(ns.FONT, 11, "")
        row.totalText:SetPoint("LEFT", row.edits[3], "RIGHT", 6, 0)
        row.totalText:SetTextColor(unpack(ns.COLORS.mutedText))

        row:Hide()
        simReagentRows[i] = row
    end

    -- Finishing reagent label
    detail.simFinishingLabel = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simFinishingLabel:SetFont(ns.FONT, 11, "")
    detail.simFinishingLabel:SetText("Finishing:")
    detail.simFinishingLabel:SetTextColor(unpack(ns.COLORS.mutedText))
    detail.simFinishingLabel:Hide()

    -- Finishing dropdowns
    for i = 1, SIM_FINISHING_SLOTS do
        local dd = KazGUI:CreateDropdown(detail.simFrame, 140, {"None"}, "None", function()
            ProfRecipes:RefreshSimResults()
        end)
        dd:Hide()
        simFinishingDrops[i] = dd
    end

    -- ── Sim Result section ──
    detail.simDivider = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simDivider:SetFont(ns.FONT, 12, "")
    detail.simDivider:SetText("RESULT")
    detail.simDivider:SetTextColor(unpack(ns.COLORS.headerText))

    detail.simQualityText = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simQualityText:SetFont(ns.FONT, 12, "")
    detail.simQualityText:SetTextColor(unpack(ns.COLORS.brightText))

    detail.simSkillText = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simSkillText:SetFont(ns.FONT, 12, "")
    detail.simSkillText:SetTextColor(unpack(ns.COLORS.mutedText))

    detail.simCostText = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simCostText:SetFont(ns.FONT, 12, "")
    detail.simCostText:SetTextColor(unpack(ns.COLORS.brightText))

    detail.simProfitText = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simProfitText:SetFont(ns.FONT, 12, "")

    detail.simConcText = detail.simFrame:CreateFontString(nil, "OVERLAY")
    detail.simConcText:SetFont(ns.FONT, 12, "")
    detail.simConcText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Optimize button
    detail.simOptBtn = ns.CreateButton(detail.simFrame, "Optimize", 70, 22)
    detail.simOptBtn:SetScript("OnClick", function()
        if not simRecipeData or not CraftSimLib then return end

        -- Phase 1: Optimize quality reagent tiers (synchronous)
        local ok, result = pcall(function()
            return CraftSimLib.REAGENT_OPTIMIZATION:OptimizeReagentAllocation(simRecipeData)
        end)
        if ok and result and result.reagents then
            local rowIdx = 0
            for _, reagent in pairs(result.reagents) do
                if reagent.hasQuality then
                    rowIdx = rowIdx + 1
                    local row = simReagentRows[rowIdx]
                    if row and row:IsShown() then
                        for t = 1, 3 do
                            local qty = 0
                            if reagent.items and reagent.items[t] then
                                qty = reagent.items[t].quantity or 0
                            end
                            row.edits[t]:SetText(tostring(qty))
                        end
                    end
                end
            end
        end

        -- Phase 2: Optimize finishing reagents (async — uses CraftSim's profit-based picker)
        local hasFinishing = simRecipeData.reagentData and simRecipeData.reagentData.finishingReagentSlots
            and #simRecipeData.reagentData.finishingReagentSlots > 0
        if hasFinishing and simRecipeData.OptimizeFinishingReagents then
            pcall(function()
                simRecipeData:OptimizeFinishingReagents({
                    finally = function()
                        -- Read CraftSim's optimal finishing selections and update our dropdowns
                        local dropIdx = 0
                        for _, slot in ipairs(simRecipeData.reagentData.finishingReagentSlots) do
                            dropIdx = dropIdx + 1
                            local dd = simFinishingDrops[dropIdx]
                            if dd and dd:IsShown() and slot.activeReagent then
                                local optItemID = slot.activeReagent.item:GetItemID()
                                -- Find the matching option label
                                if dd.optItemIDs then
                                    for idx, iid in ipairs(dd.optItemIDs) do
                                        if iid == optItemID then
                                            dd:SetSelected(dd.options[idx])
                                            break
                                        end
                                    end
                                end
                            elseif dd and dd:IsShown() then
                                dd:SetSelected("None")
                            end
                        end
                        ProfRecipes:RefreshSimResults()
                    end,
                })
            end)
        else
            ProfRecipes:RefreshSimResults()
        end
    end)

    -- Apply button — writes sim allocation back to the real transaction
    detail.simApplyBtn = ns.CreateButton(detail.simFrame, "Apply", 60, 22)
    detail.simApplyBtn:SetScript("OnClick", function()
        ProfRecipes:ApplySimToTransaction()
    end)

    -- +Queue button — applies sim allocation then queues the recipe
    detail.simQueueBtn = ns.CreateButton(detail.simFrame, "+Queue", 70, 22)
    detail.simQueueBtn:SetScript("OnClick", function()
        if not selectedRecipeID then return end
        ProfRecipes:ApplySimToTransaction()
        local qty = tonumber(detail.qtyBox:GetText()) or 1
        if qty < 1 then qty = 1 end
        if not KazCraftDB.recipeCache[selectedRecipeID] then
            ns.Data:CacheSchematic(selectedRecipeID, ns.currentProfName)
        end
        ns.Data:AddToQueue(selectedRecipeID, qty)
        if ns.ProfessionUI and ns.ProfessionUI:IsShown() then
            ns.ProfessionUI:RefreshAll()
        end
        if ns.ProfFrame then ns.ProfFrame:UpdateFooter() end
        local recipeName = KazCraftDB.recipeCache[selectedRecipeID] and KazCraftDB.recipeCache[selectedRecipeID].recipeName or "Recipe"
        print("|cff00ccffKazCraft|r: Queued " .. qty .. "x " .. recipeName .. " (sim allocation)")
    end)

    -- TSM cost / profit (above craft controls)
    detail.tsmCostLabel = rightPanel:CreateFontString(nil, "OVERLAY")
    detail.tsmCostLabel:SetFont(ns.FONT, 12, "")
    detail.tsmCostLabel:SetTextColor(unpack(ns.COLORS.headerText))
    detail.tsmCostLabel:SetText("To Craft:")

    detail.tsmCostValue = rightPanel:CreateFontString(nil, "OVERLAY")
    detail.tsmCostValue:SetFont(ns.FONT, 12, "")
    detail.tsmCostValue:SetPoint("LEFT", detail.tsmCostLabel, "RIGHT", 4, 0)

    detail.tsmProfitLabel = rightPanel:CreateFontString(nil, "OVERLAY")
    detail.tsmProfitLabel:SetFont(ns.FONT, 12, "")
    detail.tsmProfitLabel:SetTextColor(unpack(ns.COLORS.headerText))
    detail.tsmProfitLabel:SetText("Profit:")

    detail.tsmProfitValue = rightPanel:CreateFontString(nil, "OVERLAY")
    detail.tsmProfitValue:SetFont(ns.FONT, 12, "")
    detail.tsmProfitValue:SetPoint("LEFT", detail.tsmProfitLabel, "RIGHT", 4, 0)

    -- Craft controls — pinned to bottom of right panel
    detail.controlFrame = CreateFrame("Frame", nil, rightPanel)
    detail.controlFrame:SetHeight(60)
    detail.controlFrame:SetPoint("BOTTOMLEFT", rightPanel, "BOTTOMLEFT", 12, 8)
    detail.controlFrame:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -12, 8)

    -- Best Quality checkbox (reads from global setting)
    detail.bestQualCheck = CreateFrame("CheckButton", nil, detail.controlFrame, "UICheckButtonTemplate")
    detail.bestQualCheck:SetSize(22, 22)
    detail.bestQualCheck:SetPoint("TOPLEFT", detail.controlFrame, "TOPLEFT", 0, 0)
    detail.bestQualCheck:SetChecked(KazCraftDB and KazCraftDB.settings and KazCraftDB.settings.useBestQuality)
    detail.bestQualCheck:SetScript("OnClick", function(self)
        if KazCraftDB and KazCraftDB.settings then
            KazCraftDB.settings.useBestQuality = self:GetChecked() and true or false
        end
        -- Re-allocate basic reagents with new quality preference
        if currentTransaction and Professions and Professions.AllocateAllBasicReagents then
            Professions.AllocateAllBasicReagents(currentTransaction, self:GetChecked() and true or false)
        end
        ProfRecipes:RefreshDetail()
    end)

    detail.bestQualLabel = detail.controlFrame:CreateFontString(nil, "OVERLAY")
    detail.bestQualLabel:SetFont(ns.FONT, 14, "")
    detail.bestQualLabel:SetPoint("LEFT", detail.bestQualCheck, "RIGHT", 2, 0)
    detail.bestQualLabel:SetText("Best Quality")
    detail.bestQualLabel:SetTextColor(unpack(ns.COLORS.brightText))

    -- Concentration checkbox
    detail.concCheck = CreateFrame("CheckButton", nil, detail.controlFrame, "UICheckButtonTemplate")
    detail.concCheck:SetSize(22, 22)
    detail.concCheck:SetPoint("LEFT", detail.bestQualLabel, "RIGHT", 16, 0)
    detail.concCheck:SetScript("OnClick", function()
        ProfRecipes:RefreshDetail()
    end)

    detail.concLabel = detail.controlFrame:CreateFontString(nil, "OVERLAY")
    detail.concLabel:SetFont(ns.FONT, 14, "")
    detail.concLabel:SetPoint("LEFT", detail.concCheck, "RIGHT", 2, 0)
    detail.concLabel:SetText("Concentration")
    detail.concLabel:SetTextColor(unpack(ns.COLORS.brightText))

    -- Craft button row
    -- Quantity input
    detail.qtyBox = CreateFrame("EditBox", nil, detail.controlFrame, "BackdropTemplate")
    detail.qtyBox:SetSize(40, 24)
    detail.qtyBox:SetPoint("BOTTOMLEFT", detail.controlFrame, "BOTTOMLEFT", 0, 0)
    detail.qtyBox:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    detail.qtyBox:SetBackdropColor(unpack(ns.COLORS.searchBg))
    detail.qtyBox:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    detail.qtyBox:SetFont(ns.FONT, 14, "")
    detail.qtyBox:SetTextColor(unpack(ns.COLORS.brightText))
    detail.qtyBox:SetJustifyH("CENTER")
    detail.qtyBox:SetAutoFocus(false)
    detail.qtyBox:SetNumeric(true)
    detail.qtyBox:SetMaxLetters(4)
    detail.qtyBox:SetText("1")
    detail.qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    detail.qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Craft button
    detail.craftBtn = ns.CreateButton(detail.controlFrame, "Craft", 70, 24)
    detail.craftBtn:SetPoint("LEFT", detail.qtyBox, "RIGHT", 4, 0)
    detail.craftBtn:SetScript("OnClick", function()
        if not selectedRecipeID or isCrafting then return end
        local qty = tonumber(detail.qtyBox:GetText()) or 1
        if qty < 1 then qty = 1 end
        local applyConc = detail.concCheck:GetChecked() and true or false
        if currentTransaction then
            currentTransaction:SetApplyConcentration(applyConc)
        end
        ns.lastCraftedRecipeID = nil -- don't decrement queue for manual crafts
        if currentTransaction and currentTransaction:IsRecipeType(Enum.TradeskillRecipeType.Salvage) then
            currentTransaction:CraftSalvage(qty)
        elseif currentTransaction and currentTransaction:IsRecraft() then
            currentTransaction:RecraftRecipe()
        elseif currentTransaction and currentTransaction:IsRecipeType(Enum.TradeskillRecipeType.Enchant) then
            currentTransaction:CraftEnchant(selectedRecipeID, qty)
        else
            local reagentInfoTbl = currentTransaction and currentTransaction:CreateCraftingReagentInfoTbl() or {}
            C_TradeSkillUI.CraftRecipe(selectedRecipeID, qty, reagentInfoTbl, nil, nil, applyConc)
        end
    end)

    -- Craft All button (crafts qty from box, same as Craft)
    detail.craftAllBtn = ns.CreateButton(detail.controlFrame, "Craft All", 70, 24)
    detail.craftAllBtn:SetPoint("LEFT", detail.craftBtn, "RIGHT", 4, 0)
    detail.craftAllBtn:SetScript("OnClick", function()
        if not selectedRecipeID or isCrafting then return end
        local qty = tonumber(detail.qtyBox:GetText()) or 1
        if qty < 1 then qty = 1 end
        local applyConc = detail.concCheck:GetChecked() and true or false
        if currentTransaction then
            currentTransaction:SetApplyConcentration(applyConc)
        end
        ns.lastCraftedRecipeID = nil
        if currentTransaction and currentTransaction:IsRecipeType(Enum.TradeskillRecipeType.Salvage) then
            currentTransaction:CraftSalvage(qty)
        elseif currentTransaction and currentTransaction:IsRecraft() then
            currentTransaction:RecraftRecipe()
        elseif currentTransaction and currentTransaction:IsRecipeType(Enum.TradeskillRecipeType.Enchant) then
            local enchantItem = currentTransaction:GetEnchantAllocation()
            if enchantItem then
                currentTransaction:CraftEnchant(selectedRecipeID, qty)
            end
        else
            local reagentInfoTbl = currentTransaction and currentTransaction:CreateCraftingReagentInfoTbl() or {}
            C_TradeSkillUI.CraftRecipe(selectedRecipeID, qty, reagentInfoTbl, nil, nil, applyConc)
        end
    end)

    -- +Queue button
    detail.queueBtn = ns.CreateButton(detail.controlFrame, "+Queue", 70, 24)
    detail.queueBtn:SetPoint("LEFT", detail.craftAllBtn, "RIGHT", 4, 0)
    detail.queueBtn:SetScript("OnClick", function()
        if not selectedRecipeID then return end
        local qty = tonumber(detail.qtyBox:GetText()) or 1
        if qty < 1 then qty = 1 end

        if not KazCraftDB.recipeCache[selectedRecipeID] then
            ns.Data:CacheSchematic(selectedRecipeID, ns.currentProfName)
        end

        ns.Data:AddToQueue(selectedRecipeID, qty)
        if ns.ProfessionUI and ns.ProfessionUI:IsShown() then
            ns.ProfessionUI:RefreshAll()
        end
        if ns.ProfFrame then ns.ProfFrame:UpdateFooter() end

        -- Report missing materials
        local mats = ns.Data:GetMaterialList(ns.charKey)
        local missing = {}
        for _, mat in ipairs(mats) do
            if mat.short > 0 and not mat.soulbound then
                table.insert(missing, mat)
            end
        end
        if #missing > 0 then
            local recipeName = KazCraftDB.recipeCache[selectedRecipeID] and KazCraftDB.recipeCache[selectedRecipeID].recipeName or "Recipe"
            print("|cff00ccffKazCraft|r: Queued " .. qty .. "x " .. recipeName .. " — missing materials:")
            local totalCost = 0
            for _, mat in ipairs(missing) do
                local priceStr = ""
                if mat.price > 0 then
                    priceStr = " (" .. C_CurrencyInfo.GetCoinTextureString(mat.short * mat.price) .. ")"
                end
                print("  |cffff6666Need " .. mat.short .. "x|r " .. mat.itemName .. priceStr)
                totalCost = totalCost + (mat.short * mat.price)
            end
            if totalCost > 0 then
                print("  |cffffd100Total cost:|r " .. C_CurrencyInfo.GetCoinTextureString(totalCost))
            end
        else
            local recipeName = KazCraftDB.recipeCache[selectedRecipeID] and KazCraftDB.recipeCache[selectedRecipeID].recipeName or "Recipe"
            print("|cff00ccffKazCraft|r: Queued " .. qty .. "x " .. recipeName .. " — all materials available!")
        end
    end)

    -- No-selection message
    detail.emptyText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.emptyText:SetFont(ns.FONT, 14, "")
    detail.emptyText:SetPoint("CENTER", detailFrame, "CENTER", 0, 0)
    detail.emptyText:SetText("Select a recipe")
    detail.emptyText:SetTextColor(unpack(ns.COLORS.mutedText))
end

--------------------------------------------------------------------
-- Refresh recipe rows (virtual scroll)
--------------------------------------------------------------------
function ProfRecipes:RefreshRows()
    for i = 1, MAX_VISIBLE_ROWS do
        local dataIdx = scrollOffset + i
        local entry = displayList[dataIdx]
        UpdateRecipeRow(recipeRows[i], entry, i)
    end
    UpdateRecipeScrollbar()
end

--------------------------------------------------------------------
-- Refresh recipe list (rebuild from API)
--------------------------------------------------------------------
function ProfRecipes:RefreshRecipeList(resetScroll)
    if not initialized then return end
    BuildDisplayList()
    if resetScroll then
        scrollOffset = 0
    else
        -- Clamp scroll to new list size
        scrollOffset = math.max(0, math.min(scrollOffset, math.max(0, #displayList - MAX_VISIBLE_ROWS)))
    end
    self:RefreshRows()
end

--------------------------------------------------------------------
-- Refresh detail panel
--------------------------------------------------------------------
local function SetupSlotBox(box, slotIndex, slotSchematic, transaction, recipeInfo)
    box.slotIndex = slotIndex
    box.slotSchematic = slotSchematic
    box.itemID = nil

    -- Check if slot is locked (spec tree not unlocked)
    local isLocked = false
    local lockReason = nil
    if recipeInfo and Professions and Professions.GetReagentSlotStatus then
        isLocked, lockReason = Professions.GetReagentSlotStatus(slotSchematic, recipeInfo)
    end
    box._locked = isLocked

    if isLocked then
        -- Show lock icon
        box.icon:Hide()
        box.plusText:Hide()
        if not box.lockIcon then
            box.lockIcon = box:CreateTexture(nil, "OVERLAY")
            box.lockIcon:SetSize(16, 16)
            box.lockIcon:SetPoint("CENTER")
            box.lockIcon:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")
        end
        box.lockIcon:Show()
        box:SetAlpha(0.5)
        box:Show()
        box:SetScript("OnClick", nil)
        box:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(unpack(ns.COLORS.accent))
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Locked", 1, 0.3, 0.3)
            if lockReason then
                GameTooltip:AddLine(lockReason, 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        box:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
            GameTooltip:Hide()
        end)
        return
    end

    -- Not locked — hide lock icon if it exists
    if box.lockIcon then box.lockIcon:Hide() end
    box:SetAlpha(1)

    -- Check if transaction has an allocation for this slot
    local allocs = transaction and transaction:GetAllocations(slotIndex)
    local firstAlloc = allocs and type(allocs.GetFirstAllocation) == "function" and allocs:GetFirstAllocation()

    if firstAlloc then
        local reagent = firstAlloc:GetReagent()
        if reagent and reagent.itemID then
            box.itemID = reagent.itemID
            local itemIcon = C_Item.GetItemIconByID(reagent.itemID)
            if not itemIcon then
                C_Item.RequestLoadItemDataByID(reagent.itemID)
            end
            box.icon:SetTexture(itemIcon or 134400)
            box.icon:Show()
            box.plusText:Hide()
        else
            box.icon:Hide()
            box.plusText:Show()
        end
    else
        box.icon:Hide()
        box.plusText:Show()
    end

    box:Show()

    -- OnClick: left = open flyout, right = clear
    box:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if transaction and transaction:HasAnyAllocations(slotIndex) then
                transaction:ClearAllocations(slotIndex)
                ProfRecipes:RefreshDetail()
            end
            return
        end

        -- Left click — toggle Blizzard flyout
        if not transaction or not slotSchematic then return end
        if not CreateProfessionsMCRFlyout then return end

        -- If flyout is already open for this box, close and bail
        if self._flyoutOpen then
            if CloseProfessionsItemFlyout then CloseProfessionsItemFlyout() end
            self._flyoutOpen = false
            return
        end

        if CloseProfessionsItemFlyout then
            CloseProfessionsItemFlyout()
        end

        -- Duck-type a slot object for MCRFlyout
        local fakeSlot = {
            IsOriginalReagentSet = function() return true end,
            GetOriginalReagent = function() return nil end,
            SetReagent = function() end,
            ClearReagent = function() end,
            RestoreOriginalReagent = function() end,
            GetReagentSlotSchematic = function() return slotSchematic end,
            GetSlotIndex = function() return slotIndex end,
            IsUnallocatable = function() return false end,
            Button = self,
        }

        local behavior = CreateProfessionsMCRFlyout(transaction, slotSchematic, fakeSlot)
        local flyout = OpenProfessionsItemFlyout(self, detailFrame, behavior)

        if flyout then
            flyout:SetFrameStrata("TOOLTIP")
            flyout:SetFrameLevel(900)
            self._flyoutOpen = true

            -- Clear flag when flyout closes (selection or outside click)
            local ownerBox = self
            flyout:HookScript("OnHide", function()
                ownerBox._flyoutOpen = false
            end)

            local function OnFlyoutItemSelected(o, f, elementData)
                local reagent = elementData.reagent
                if not reagent then return end

                -- Determine quantity required (method or field fallback)
                local qtyReq = 1
                if type(slotSchematic.GetQuantityRequired) == "function" then
                    local ok, val = pcall(slotSchematic.GetQuantityRequired, slotSchematic, reagent)
                    if ok and val then qtyReq = val end
                else
                    qtyReq = slotSchematic.quantityRequired or 1
                end

                transaction:OverwriteAllocation(slotIndex, reagent, qtyReq)
                ProfRecipes:RefreshDetail()
            end
            flyout:RegisterCallback(ProfessionsFlyoutMixin.Event.ItemSelected, OnFlyoutItemSelected, box)
        end
    end)
end

function ProfRecipes:RefreshDetail()
    if not initialized or not detailFrame then return end

    if not selectedRecipeID then
        detail.emptyText:Show()
        detail.nameText:SetText("")
        detail.icon:SetTexture(nil)
        detail.iconQualityPip:Hide()
        detail.subtypeText:SetText("")
        detail.descText:SetText("")
        detail.descText:Hide()
        detail.reagentHeader:Hide()
        detail.reagentFrame:Hide()
        detail.salvageBox:Hide()
        detail.recraftBox:Hide()
        detail.recraftArrow:Hide()
        detail.recraftOutput:Hide()
        detail.enchantHeader:Hide()
        detail.enchantBox:Hide()
        detail.enchantName:Hide()
        detail.optionalHeader:Hide()
        detail.optionalFrame:Hide()
        detail.finishingHeader:Hide()
        detail.finishingFrame:Hide()
        detail.detailHeader:Hide()
        detail.qualityText:Hide()
        detail.skillText:Hide()
        detail.concText:Hide()
        detail.cooldownText:Hide()
        detail.sourceFrame:Hide()
        detail.tsmCostLabel:Hide()
        detail.tsmCostValue:Hide()
        detail.tsmProfitLabel:Hide()
        detail.tsmProfitValue:Hide()
        detail.controlFrame:Hide()
        detail.favBtn:Hide()
        detail.simFrame:Hide()
        simRecipeData = nil
        return
    end

    detail.emptyText:Hide()
    detail.favBtn:Show()

    -- Sync Best Quality checkbox with global setting
    local useBest = KazCraftDB and KazCraftDB.settings and KazCraftDB.settings.useBestQuality
    if detail.bestQualCheck then
        detail.bestQualCheck:SetChecked(useBest and true or false)
    end

    local info = C_TradeSkillUI.GetRecipeInfo(selectedRecipeID)
    if not info then return end

    -- Name
    detail.nameText:SetText(info.name or "?")

    -- Favorite star
    detail.favBtn.t:SetTextColor(info.favorite and 1 or 0.5, info.favorite and 0.84 or 0.5, info.favorite and 0 or 0.5)

    -- Icon + subtype
    detail.icon:SetTexture(info.icon or 134400)
    detail.iconBtn.recipeID = selectedRecipeID
    local subtype = ""
    if info.categoryID then
        local catInfo = C_TradeSkillUI.GetCategoryInfo(info.categoryID)
        if catInfo then subtype = catInfo.name or "" end
    end
    detail.subtypeText:SetText(subtype)

    -- ── Transaction lifecycle ──
    local isRecraft = info.isRecraft or false
    local hasProfTemplates = (Professions and Professions.AllocateAllBasicReagents and
                              ProfessionsUtil and ProfessionsUtil.GetRecipeSchematic and
                              CreateProfessionsRecipeTransaction) and true or false

    if hasProfTemplates then
        if selectedRecipeID ~= lastTransactionRecipeID then
            currentSchematic = ProfessionsUtil.GetRecipeSchematic(selectedRecipeID, isRecraft)
            currentTransaction = CreateProfessionsRecipeTransaction(currentSchematic)
            currentTransaction:SetRecraft(isRecraft)
            lastTransactionRecipeID = selectedRecipeID
            if not isRecraft then
                pcall(Professions.AllocateAllBasicReagents, currentTransaction, useBest and true or false)
            end
        end
    else
        -- Fallback: plain schematic, no transaction
        currentSchematic = C_TradeSkillUI.GetRecipeSchematic(selectedRecipeID, isRecraft)
        currentTransaction = nil
    end

    local schematic = currentSchematic

    -- ── Recipe description / flavor text ──
    local reagentInfos = currentTransaction and currentTransaction:CreateCraftingReagentInfoTbl() or {}
    local desc = C_TradeSkillUI.GetRecipeDescription(selectedRecipeID, reagentInfos)
    if desc and desc ~= "" then
        local textureID, height = string.match(desc, "|T(%d+):(%d+)|t")
        if textureID then
            local size = height or 24
            desc = string.gsub(desc, "|T.*|t", CreateSimpleTextureMarkup(textureID, size, size, 0, 3))
        end
        detail.descText:SetText(desc)
        detail.descText:Show()
    else
        detail.descText:SetText("")
        detail.descText:Hide()
    end

    -- Anchor reagent header dynamically below description (or icon if no desc)
    local reagentAnchor = detail.descText:IsShown() and detail.descText or detail.icon
    detail.reagentHeader:ClearAllPoints()
    detail.reagentHeader:SetPoint("TOPLEFT", reagentAnchor, "BOTTOMLEFT", 0, -8)
    detail.reagentFrame:ClearAllPoints()
    detail.reagentFrame:SetPoint("TOPLEFT", detail.reagentHeader, "BOTTOMLEFT", 0, -4)
    detail.reagentFrame:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -8, 0)

    -- ── Salvage slot (Disassemble, Scour, Pilfer) ──
    local isSalvage = schematic and schematic.recipeType == Enum.TradeskillRecipeType.Salvage
    if isSalvage and currentTransaction then
        detail.reagentHeader:SetText("TARGET ITEM")
        detail.reagentHeader:Show()
        detail.reagentFrame:Hide()
        detail.recraftBox:Hide()
        detail.recraftArrow:Hide()
        detail.recraftOutput:Hide()

        local sBox = detail.salvageBox
        sBox:ClearAllPoints()
        sBox:SetPoint("TOPLEFT", detail.reagentHeader, "BOTTOMLEFT", 0, -6)

        -- Show current salvage allocation if any
        local salvageItem = currentTransaction:GetSalvageAllocation()
        if salvageItem then
            local itemID = salvageItem:GetItemID()
            if itemID then
                local _, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
                sBox.icon:SetTexture(itemIcon or 134400)
                sBox.icon:Show()
                sBox.plusText:Hide()
                sBox.itemID = itemID
            else
                sBox.icon:Hide()
                sBox.plusText:Show()
                sBox.itemID = nil
            end
        else
            sBox.icon:Hide()
            sBox.plusText:Show()
            sBox.itemID = nil
        end

        sBox:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                currentTransaction:ClearSalvageAllocations()
                ProfRecipes:RefreshDetail()
                return
            end
            -- Left click — toggle salvage flyout
            if self._flyoutOpen then
                if CloseProfessionsItemFlyout then CloseProfessionsItemFlyout() end
                self._flyoutOpen = false
                return
            end
            if CloseProfessionsItemFlyout then CloseProfessionsItemFlyout() end
            if not CreateProfessionsSalvageFlyout then return end

            local behavior = CreateProfessionsSalvageFlyout(currentTransaction)
            local flyout = OpenProfessionsItemFlyout(self, detailFrame, behavior)
            if flyout then
                flyout:SetFrameStrata("TOOLTIP")
                flyout:SetFrameLevel(900)
                self._flyoutOpen = true
                flyout:HookScript("OnHide", function() sBox._flyoutOpen = false end)

                flyout:RegisterCallback(ProfessionsFlyoutMixin.Event.ItemSelected, function(_, _, elementData)
                    local item = elementData.item
                    if not item then return end
                    currentTransaction:SetSalvageAllocation(item)
                    ProfRecipes:RefreshDetail()
                end)
            end
        end)
        sBox:Show()
    elseif isRecraft and currentTransaction then
        -- ── Recraft slot (Recraft Equipment) ──
        detail.salvageBox:Hide()

        local rBox = detail.recraftBox
        rBox:ClearAllPoints()
        rBox:SetPoint("TOPLEFT", reagentAnchor, "BOTTOMLEFT", 0, -8)

        -- Show current recraft allocation if any
        local recraftGUID = currentTransaction:GetRecraftAllocation()
        if recraftGUID then
            local item = Item:CreateFromItemGUID(recraftGUID)
            if item and item:GetItemID() then
                local itemIcon = C_Item.GetItemIconByID(item:GetItemID())
                rBox.icon:SetTexture(itemIcon or 134400)
                rBox.icon:Show()
                rBox.plusText:Hide()
                rBox.itemID = item:GetItemID()

                -- Quality pip on input item (equipment needs GetItemCraftedQualityByItemInfo with a link)
                local inputLink = item:GetItemLink()
                local inputQuality = inputLink and C_TradeSkillUI.GetItemCraftedQualityByItemInfo(inputLink) or nil
                if inputQuality and inputQuality > 0 then
                    if not rBox.qualityPip then
                        rBox.qualityPip = rBox:CreateTexture(nil, "OVERLAY", nil, 2)
                        rBox.qualityPip:SetSize(14, 14)
                        rBox.qualityPip:SetPoint("TOPLEFT", rBox, "TOPLEFT", -2, 2)
                    end
                    rBox.qualityPip:SetAtlas(ns.GetQualityAtlas(inputQuality), false)
                    rBox.qualityPip:Show()
                elseif rBox.qualityPip then
                    rBox.qualityPip:Hide()
                end

                -- Update title to "Recrafting: Item Name"
                local itemName = C_Item.GetItemInfo(item:GetItemID())
                if itemName then
                    detail.nameText:SetText("Recrafting: " .. itemName)
                end

                -- Show output preview: input → output
                detail.recraftArrow:ClearAllPoints()
                detail.recraftArrow:SetPoint("LEFT", rBox, "RIGHT", 6, 0)
                detail.recraftArrow:Show()

                local outBox = detail.recraftOutput
                outBox:ClearAllPoints()
                outBox:SetPoint("LEFT", detail.recraftArrow, "RIGHT", 6, 0)

                -- Get predicted output item
                local reagentInfoTbl = currentTransaction:CreateCraftingReagentInfoTbl() or {}
                local outputData = C_TradeSkillUI.GetRecipeOutputItemData(
                    selectedRecipeID, reagentInfoTbl, recraftGUID)
                if outputData and outputData.hyperlink then
                    local outIcon = C_Item.GetItemIconByID(outputData.hyperlink)
                    outBox.icon:SetTexture(outIcon or itemIcon or 134400)
                    outBox.icon:Show()
                    outBox.plusText:Hide()
                    outBox.itemLink = outputData.hyperlink
                    -- Output pip set later from Details section opInfo
                else
                    outBox.icon:SetTexture(itemIcon or 134400)
                    outBox.icon:Show()
                    outBox.plusText:Hide()
                    outBox.itemLink = nil
                    if outBox.qualityPip then outBox.qualityPip:Hide() end
                end
                outBox:SetScript("OnEnter", function(self)
                    self:SetBackdropBorderColor(unpack(ns.COLORS.accent))
                    if IsShiftKeyDown() then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        if self.itemLink then
                            GameTooltip:SetHyperlink(self.itemLink)
                        elseif rBox.itemID then
                            GameTooltip:SetItemByID(rBox.itemID)
                        end
                        GameTooltip:Show()
                    end
                end)
                outBox:SetScript("OnLeave", function(self)
                    self:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
                    GameTooltip:Hide()
                end)
                outBox:SetScript("OnClick", nil)
                outBox:Show()
            else
                rBox.icon:Hide()
                rBox.plusText:Show()
                rBox.itemID = nil
                if rBox.qualityPip then rBox.qualityPip:Hide() end
                detail.recraftArrow:Hide()
                detail.recraftOutput:Hide()
            end
        else
            rBox.icon:Hide()
            rBox.plusText:Show()
            rBox.itemID = nil
            if rBox.qualityPip then rBox.qualityPip:Hide() end
            detail.recraftArrow:Hide()
            detail.recraftOutput:Hide()
        end

        rBox:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                -- Reset to generic recraft schematic (no item = no reagent slots)
                currentSchematic = ProfessionsUtil.GetRecipeSchematic(selectedRecipeID, true)
                currentTransaction = CreateProfessionsRecipeTransaction(currentSchematic)
                lastTransactionRecipeID = selectedRecipeID
                ProfRecipes:RefreshDetail()
                return
            end
            -- Left click — toggle recraft flyout
            if self._flyoutOpen then
                if CloseProfessionsItemFlyout then CloseProfessionsItemFlyout() end
                self._flyoutOpen = false
                return
            end
            if CloseProfessionsItemFlyout then CloseProfessionsItemFlyout() end
            if not CreateProfessionsRecraftFlyout then return end

            local behavior = CreateProfessionsRecraftFlyout(currentTransaction)
            local flyout = OpenProfessionsItemFlyout(self, detailFrame, behavior)
            if flyout then
                flyout:SetFrameStrata("TOOLTIP")
                flyout:SetFrameLevel(900)
                self._flyoutOpen = true
                flyout:HookScript("OnHide", function() rBox._flyoutOpen = false end)

                flyout:RegisterCallback(ProfessionsFlyoutMixin.Event.ItemSelected, function(_, _, elementData)
                    local itemGUID = elementData.itemGUID
                    if not itemGUID then return end
                    -- Get the ORIGINAL recipe that crafted this item — it has the real reagent slots
                    local origRecipeID = C_TradeSkillUI.GetOriginalCraftRecipeID(itemGUID)
                    if origRecipeID and origRecipeID > 0 then
                        currentSchematic = ProfessionsUtil.GetRecipeSchematic(origRecipeID, true)
                    end
                    currentTransaction = CreateProfessionsRecipeTransaction(currentSchematic)
                    currentTransaction:SetRecraft(true)
                    currentTransaction:SetRecraftAllocation(itemGUID)
                    local bestQ = KazCraftDB and KazCraftDB.settings and KazCraftDB.settings.useBestQuality
                    pcall(Professions.AllocateAllBasicReagents, currentTransaction, bestQ and true or false)
                    ProfRecipes:RefreshDetail()
                end)
            end
        end)
        rBox:Show()

        -- Re-anchor reagent header below the recraft preview
        local recraftBottomAnchor = detail.recraftOutput:IsShown() and detail.recraftOutput or rBox
        detail.reagentHeader:SetText("REAGENTS")
        detail.reagentHeader:ClearAllPoints()
        detail.reagentHeader:SetPoint("TOPLEFT", recraftBottomAnchor, "BOTTOMLEFT", 0, -8)
        detail.reagentFrame:ClearAllPoints()
        detail.reagentFrame:SetPoint("TOPLEFT", detail.reagentHeader, "BOTTOMLEFT", 0, -4)
        detail.reagentFrame:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -8, 0)
    else
        detail.reagentHeader:SetText("REAGENTS")
        detail.salvageBox:Hide()
        detail.recraftBox:Hide()
        detail.recraftArrow:Hide()
        detail.recraftOutput:Hide()
    end

    -- ── Basic Reagents ──
    if not isSalvage then
        detail.reagentHeader:Show()
        detail.reagentFrame:Show()
    end

    local reagentCount = 0
    local optionalSlots = {}
    local finishingSlots = {}

    if schematic and schematic.reagentSlotSchematics then
        for slotIndex, slot in ipairs(schematic.reagentSlotSchematics) do
            if slot.reagentType == Enum.CraftingReagentType.Basic then
                reagentCount = reagentCount + 1
                local row = reagentRows[reagentCount]
                if not row then
                    row = CreateReagentRow(detail.reagentFrame, reagentCount)
                    reagentRows[reagentCount] = row
                end

                local inputMode = hasProfTemplates and Professions.GetReagentInputMode(slot) or nil
                local isQuality = inputMode and inputMode == Professions.ReagentInputMode.Quality

                if isQuality and currentTransaction then
                    -- Quality reagent — show allocated tier + per-tier counts
                    local needed = slot.quantityRequired or 0
                    local totalHave = 0
                    local allocStr = ""
                    local displayIcon = 134400
                    local displayName = ""

                    for tierIdx, reagent in ipairs(slot.reagents) do
                        local tierHave = ProfessionsUtil.GetReagentQuantityInPossession(reagent, false)
                        totalHave = totalHave + tierHave

                        local allocated = 0
                        local allocs = currentTransaction:GetAllocations(slotIndex)
                        if allocs and type(allocs.GetQuantityAllocated) == "function" then
                            allocated = allocs:GetQuantityAllocated(reagent)
                        end

                        -- Use the tier that has the most allocation for display
                        if allocated > 0 and displayName == "" then
                            local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(reagent.itemID)
                            displayIcon = itemIcon or 134400
                            displayName = itemName or ("Item:" .. reagent.itemID)
                        end

                        -- Build per-tier count string for tooltip-style inline display
                        if tierHave > 0 or allocated > 0 then
                            local tierColor = tierIdx == 1 and "ffffff" or (tierIdx == 2 and "4dff4d" or "4d9fff")
                            if allocStr ~= "" then allocStr = allocStr .. " " end
                            allocStr = allocStr .. "|cff" .. tierColor .. tierHave .. "|r"
                        end
                    end

                    -- Fallback if nothing allocated yet
                    if displayName == "" then
                        local firstReagent = slot.reagents[1]
                        if firstReagent then
                            local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(firstReagent.itemID)
                            displayIcon = itemIcon or 134400
                            displayName = itemName or ("Item:" .. firstReagent.itemID)
                            if not itemName then
                                C_Item.RequestLoadItemDataByID(firstReagent.itemID)
                            end
                        end
                    end

                    row.icon:SetTexture(displayIcon)
                    row.itemID = slot.reagents[1] and slot.reagents[1].itemID

                    -- Quality pips inline: T1/T2/T3 counts
                    local nameStr = displayName
                    if needed > 1 then nameStr = nameStr .. " x" .. needed end
                    if allocStr ~= "" then nameStr = nameStr .. "  [" .. allocStr .. "]" end
                    row.nameText:SetText(nameStr)

                    if totalHave >= needed then
                        row.countText:SetText("|cff4dff4d" .. totalHave .. "/" .. needed .. "|r")
                    else
                        row.countText:SetText("|cffff4d4d" .. totalHave .. "/" .. needed .. "|r")
                    end
                else
                    -- Fixed reagent (single tier) — original display logic
                    local firstReagent = slot.reagents and slot.reagents[1]
                    local itemID = firstReagent and firstReagent.itemID
                    local needed = slot.quantityRequired or 0

                    local itemName, _, _, _, _, _, _, _, _, itemIcon
                    if itemID then
                        itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
                        if not itemName then
                            C_Item.RequestLoadItemDataByID(itemID)
                        end
                    end

                    row.icon:SetTexture(itemIcon or 134400)
                    row.itemID = itemID
                    row.nameText:SetText((itemName or ("Item:" .. (itemID or "?"))) ..
                        (needed > 1 and (" x" .. needed) or ""))

                    local have = itemID and C_Item.GetItemCount(itemID, true, false, true, true) or 0
                    if have >= needed then
                        row.countText:SetText("|cff4dff4d" .. have .. "/" .. needed .. "|r")
                    else
                        row.countText:SetText("|cffff4d4d" .. have .. "/" .. needed .. "|r")
                    end
                end

                row:Show()

            elseif slot.reagentType == Enum.CraftingReagentType.Modifying then
                table.insert(optionalSlots, { slotIndex = slotIndex, slot = slot })
            elseif slot.reagentType == Enum.CraftingReagentType.Finishing then
                table.insert(finishingSlots, { slotIndex = slotIndex, slot = slot })
            end
        end
    end

    -- Hide unused reagent rows
    for i = reagentCount + 1, #reagentRows do
        reagentRows[i].itemID = nil
        reagentRows[i]:Hide()
    end

    -- Adjust reagent frame height
    detail.reagentFrame:SetHeight(math.max(1, reagentCount * REAGENT_ROW_HEIGHT))

    -- ── Enchant target slot ──
    local isEnchant = schematic and schematic.recipeType == Enum.TradeskillRecipeType.Enchant
        and not C_TradeSkillUI.IsRuneforging()
    if isEnchant and currentTransaction then
        detail.enchantHeader:ClearAllPoints()
        detail.enchantHeader:SetPoint("TOPLEFT", detail.reagentFrame, "BOTTOMLEFT", 0, -10)
        detail.enchantHeader:Show()

        local eBox = detail.enchantBox
        eBox:ClearAllPoints()
        eBox:SetPoint("TOPLEFT", detail.enchantHeader, "BOTTOMLEFT", 0, -4)

        -- Show current enchant allocation
        local enchantItem = currentTransaction:GetEnchantAllocation()
        if enchantItem then
            local itemID = enchantItem:GetItemID()
            if itemID then
                local itemIcon = C_Item.GetItemIconByID(itemID)
                eBox.icon:SetTexture(itemIcon or 134400)
                eBox.icon:Show()
                eBox.plusText:Hide()
                eBox.itemID = itemID
                detail.enchantName:SetText(enchantItem:GetItemName() or "")
            else
                eBox.icon:Hide()
                eBox.plusText:Show()
                eBox.itemID = nil
                detail.enchantName:SetText("Select an item to enchant")
            end
        else
            eBox.icon:Hide()
            eBox.plusText:Show()
            eBox.itemID = nil
            detail.enchantName:SetText("Select an item to enchant")
        end

        eBox:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                currentTransaction:ClearEnchantAllocations()
                ProfRecipes:RefreshDetail()
                return
            end
            -- Left click — toggle enchant flyout
            if self._flyoutOpen then
                if CloseProfessionsItemFlyout then CloseProfessionsItemFlyout() end
                self._flyoutOpen = false
                return
            end
            if CloseProfessionsItemFlyout then CloseProfessionsItemFlyout() end
            if not CreateProfessionsEnchantFlyout then return end

            local behavior = CreateProfessionsEnchantFlyout(currentTransaction)
            local flyout = OpenProfessionsItemFlyout(self, detailFrame, behavior)
            if flyout then
                flyout:SetFrameStrata("TOOLTIP")
                flyout:SetFrameLevel(900)
                self._flyoutOpen = true
                flyout:HookScript("OnHide", function() eBox._flyoutOpen = false end)

                flyout:RegisterCallback(ProfessionsFlyoutMixin.Event.ItemSelected, function(_, _, elementData)
                    local item = elementData.item
                    if not item then return end
                    currentTransaction:SetEnchantAllocation(item)
                    ProfRecipes:RefreshDetail()
                end)
            end
        end)
        eBox:Show()
        detail.enchantName:Show()
    else
        detail.enchantHeader:Hide()
        detail.enchantBox:Hide()
        detail.enchantName:Hide()
    end

    -- ── Optional Reagents section ──
    local chainAnchor, chainAnchorPoint, chainOffset
    if isSalvage then
        chainAnchor = detail.salvageBox
        chainAnchorPoint = "BOTTOMLEFT"
        chainOffset = -10
    elseif isEnchant then
        chainAnchor = detail.enchantBox
        chainAnchorPoint = "BOTTOMLEFT"
        chainOffset = -10
    else
        chainAnchor = detail.reagentFrame
        chainAnchorPoint = "BOTTOMLEFT"
        chainOffset = -10
    end

    if #optionalSlots > 0 and currentTransaction then
        detail.optionalHeader:ClearAllPoints()
        detail.optionalHeader:SetPoint("TOPLEFT", chainAnchor, chainAnchorPoint, 0, chainOffset)
        detail.optionalHeader:Show()

        detail.optionalFrame:ClearAllPoints()
        detail.optionalFrame:SetPoint("TOPLEFT", detail.optionalHeader, "BOTTOMLEFT", 0, -4)
        detail.optionalFrame:SetPoint("TOPRIGHT", detail.optionalHeader, "BOTTOMRIGHT", 0, -4)
        detail.optionalFrame:Show()

        for i, entry in ipairs(optionalSlots) do
            if i > MAX_OPTIONAL_SLOTS then break end
            local box = optionalSlotFrames[i]
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", detail.optionalFrame, "TOPLEFT", (i - 1) * (SLOT_BOX_SIZE + SLOT_BOX_SPACING), 0)
            local ok, err = pcall(SetupSlotBox, box, entry.slotIndex, entry.slot, currentTransaction, info)
            if not ok then
                box.icon:Hide()
                box.plusText:Show()
                box:Show()
            end
        end
        for i = #optionalSlots + 1, MAX_OPTIONAL_SLOTS do
            optionalSlotFrames[i]:Hide()
        end

        chainAnchor = detail.optionalFrame
        chainAnchorPoint = "BOTTOMLEFT"
        chainOffset = -10
    else
        detail.optionalHeader:Hide()
        detail.optionalFrame:Hide()
        for i = 1, MAX_OPTIONAL_SLOTS do
            optionalSlotFrames[i]:Hide()
        end
    end

    -- ── Finishing Reagents section ──
    if #finishingSlots > 0 and currentTransaction then
        detail.finishingHeader:ClearAllPoints()
        detail.finishingHeader:SetPoint("TOPLEFT", chainAnchor, chainAnchorPoint, 0, chainOffset)
        detail.finishingHeader:Show()

        detail.finishingFrame:ClearAllPoints()
        detail.finishingFrame:SetPoint("TOPLEFT", detail.finishingHeader, "BOTTOMLEFT", 0, -4)
        detail.finishingFrame:SetPoint("TOPRIGHT", detail.finishingHeader, "BOTTOMRIGHT", 0, -4)
        detail.finishingFrame:Show()

        for i, entry in ipairs(finishingSlots) do
            if i > MAX_FINISHING_SLOTS then break end
            local box = finishingSlotFrames[i]
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", detail.finishingFrame, "TOPLEFT", (i - 1) * (SLOT_BOX_SIZE + SLOT_BOX_SPACING), 0)
            local ok, err = pcall(SetupSlotBox, box, entry.slotIndex, entry.slot, currentTransaction, info)
            if not ok then
                box.icon:Hide()
                box.plusText:Show()
                box:Show()
            end
        end
        for i = #finishingSlots + 1, MAX_FINISHING_SLOTS do
            finishingSlotFrames[i]:Hide()
        end

        chainAnchor = detail.finishingFrame
        chainAnchorPoint = "BOTTOMLEFT"
        chainOffset = -10
    else
        detail.finishingHeader:Hide()
        detail.finishingFrame:Hide()
        for i = 1, MAX_FINISHING_SLOTS do
            finishingSlotFrames[i]:Hide()
        end
    end

    -- ── Details section — anchor below last reagent section ──
    detail.detailHeader:ClearAllPoints()
    detail.detailHeader:SetPoint("TOPLEFT", chainAnchor, chainAnchorPoint, 0, chainOffset)
    detail.detailHeader:Show()

    -- Quality + skill info from GetCraftingOperationInfo
    local applyConc = detail.concCheck:GetChecked()
    local reagentInfoTbl = currentTransaction and currentTransaction:CreateCraftingReagentInfoTbl() or {}
    local recraftItemGUID = currentTransaction and currentTransaction:GetRecraftAllocation() or nil
    local opRecipeID = (recraftItemGUID and currentSchematic) and currentSchematic.recipeID or selectedRecipeID
    local opInfo = C_TradeSkillUI.GetCraftingOperationInfo(opRecipeID, reagentInfoTbl, recraftItemGUID, applyConc)

    if opInfo then
        -- Quality display with atlas pips
        if opInfo.craftingQualityID and opInfo.craftingQualityID > 0 then
            local qTier = opInfo.craftingQuality or 0
            local maxTier = opInfo.maxCraftingQuality or 5
            local pips = ""
            for i = 1, maxTier do
                if i <= qTier then
                    pips = pips .. "|A:Professions-Icon-Quality-Tier" .. i .. "-Small:0:0|a"
                else
                    pips = pips .. "|cff666666*|r"
                end
            end
            detail.qualityText:SetText("Quality: " .. pips)
            -- Pip overlay on output icon
            if qTier > 0 then
                detail.iconQualityPip:SetAtlas("Professions-Icon-Quality-Tier" .. qTier .. "-Small", false)
                detail.iconQualityPip:Show()
            else
                detail.iconQualityPip:Hide()
            end
            -- Also set recraft output box pip if visible
            local outBox = detail.recraftOutput
            if outBox and outBox:IsShown() then
                if qTier > 0 then
                    if not outBox.qualityPip then
                        outBox.qualityPip = outBox:CreateTexture(nil, "OVERLAY", nil, 2)
                        outBox.qualityPip:SetSize(14, 14)
                        outBox.qualityPip:SetPoint("TOPLEFT", outBox, "TOPLEFT", -2, 2)
                    end
                    outBox.qualityPip:SetAtlas(ns.GetQualityAtlas(qTier), false)
                    outBox.qualityPip:Show()
                elseif outBox.qualityPip then
                    outBox.qualityPip:Hide()
                end
            end
        else
            detail.qualityText:SetText("")
            detail.iconQualityPip:Hide()
        end
        detail.qualityText:ClearAllPoints()
        detail.qualityText:SetPoint("TOPLEFT", detail.detailHeader, "BOTTOMLEFT", 0, -6)
        detail.qualityText:Show()

        -- Skill vs difficulty
        if opInfo.baseSkill and opInfo.baseDifficulty then
            local totalSkill = (opInfo.baseSkill or 0) + (opInfo.bonusSkill or 0)
            detail.skillText:SetText("Skill: " .. totalSkill .. "  Difficulty: " .. opInfo.baseDifficulty)
        else
            detail.skillText:SetText("")
        end
        detail.skillText:ClearAllPoints()
        detail.skillText:SetPoint("TOPLEFT", detail.qualityText, "BOTTOMLEFT", 0, -4)
        detail.skillText:Show()

        -- Concentration info
        local concCurrID = opInfo.concentrationCurrencyID or 0
        local concCost = opInfo.concentrationCost or 0
        if concCurrID ~= 0 then
            local currInfo = C_CurrencyInfo.GetCurrencyInfo(concCurrID)
            local current = currInfo and currInfo.quantity or 0
            local maxConc = currInfo and currInfo.maxQuantity or 0
            local concStr = "Concentration: " .. current .. "/" .. maxConc
            if concCost > 0 then
                concStr = concStr .. "  (cost: " .. concCost .. ")"
            end
            detail.concText:SetText(concStr)

            -- Enable/disable concentration checkbox
            if concCost > 0 and current >= concCost then
                detail.concCheck:Enable()
                detail.concLabel:SetTextColor(unpack(ns.COLORS.brightText))
            else
                detail.concCheck:SetChecked(false)
                detail.concCheck:Disable()
                detail.concLabel:SetTextColor(unpack(ns.COLORS.mutedText))
            end
        else
            detail.concText:SetText("")
            detail.concCheck:SetChecked(false)
            detail.concCheck:Disable()
            detail.concLabel:SetTextColor(unpack(ns.COLORS.mutedText))
        end
        detail.concText:ClearAllPoints()
        detail.concText:SetPoint("TOPLEFT", detail.skillText, "BOTTOMLEFT", 0, -4)
        detail.concText:Show()
    else
        detail.qualityText:ClearAllPoints()
        detail.qualityText:SetPoint("TOPLEFT", detail.detailHeader, "BOTTOMLEFT", 0, -6)
        detail.qualityText:SetText("")
        detail.qualityText:Show()
        detail.iconQualityPip:Hide()
        detail.skillText:Hide()
        detail.concText:Hide()
        detail.concCheck:SetChecked(false)
        detail.concCheck:Disable()
        detail.concLabel:SetTextColor(unpack(ns.COLORS.mutedText))
    end

    -- ── Cooldown ──
    local cooldown, isDayCooldown, charges, maxCharges = C_TradeSkillUI.GetRecipeCooldown(selectedRecipeID)
    local cdAnchor = detail.concText:IsShown() and detail.concText or
                     (detail.skillText:IsShown() and detail.skillText or detail.qualityText)

    if charges and maxCharges and maxCharges > 0 then
        -- Charge-based cooldown (e.g. Transmute)
        local cdStr
        if charges < maxCharges and cooldown then
            cdStr = string.format("Charges: %d/%d  (next in %s)", charges, maxCharges, SecondsToTime(cooldown))
        else
            cdStr = string.format("Charges: %d/%d", charges, maxCharges)
        end
        detail.cooldownText:SetText(cdStr)
        detail.cooldownText:SetTextColor(charges > 0 and 0.9 or 0.9, charges > 0 and 0.82 or 0.3, charges > 0 and 0.3 or 0.3)
        detail.cooldownText:ClearAllPoints()
        detail.cooldownText:SetPoint("TOPLEFT", cdAnchor, "BOTTOMLEFT", 0, -4)
        detail.cooldownText:Show()
    elseif cooldown then
        -- Simple cooldown
        local cdStr
        if isDayCooldown and cooldown <= 86400 then
            cdStr = "Cooldown expires at midnight"
        else
            cdStr = "Cooldown remaining: " .. SecondsToTime(cooldown)
        end
        detail.cooldownText:SetText(cdStr)
        detail.cooldownText:SetTextColor(0.9, 0.3, 0.3)
        detail.cooldownText:ClearAllPoints()
        detail.cooldownText:SetPoint("TOPLEFT", cdAnchor, "BOTTOMLEFT", 0, -4)
        detail.cooldownText:Show()
    else
        detail.cooldownText:Hide()
    end

    -- Recipe source info (unlearned or next rank)
    local sourceText, sourceLabel
    if not info.learned then
        sourceText = C_TradeSkillUI.GetRecipeSourceText(selectedRecipeID)
        sourceLabel = "Recipe Unlearned"
    elseif info.nextRecipeID then
        sourceText = C_TradeSkillUI.GetRecipeSourceText(info.nextRecipeID)
        sourceLabel = "Next Rank"
    end

    local lastAnchor = detail.cooldownText:IsShown() and detail.cooldownText or
                       (detail.concText:IsShown() and detail.concText or
                       (detail.skillText:IsShown() and detail.skillText or detail.qualityText))

    if sourceText then
        detail.sourceLabel:SetText(sourceLabel)
        detail.sourceText:SetText(sourceText)
        detail.sourceFrame:ClearAllPoints()
        detail.sourceFrame:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", -8, -8)
        detail.sourceFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
        -- Force layout so GetStringHeight returns correct value
        detail.sourceFrame:SetHeight(200)
        detail.sourceFrame:Show()
        local labelH = detail.sourceLabel:GetStringHeight() or 12
        local textH = detail.sourceText:GetStringHeight() or 14
        -- 6 top pad + label + 4 gap + text + 8 bottom pad
        detail.sourceFrame:SetHeight(labelH + textH + 18)
        lastAnchor = detail.sourceFrame
    else
        detail.sourceFrame:Hide()
    end

    -- CraftSim Specialization Info (cached per recipe)
    -- CraftSim uses a local namespace; we access it via CraftSimLib global
    local specData = nil
    if CraftSimLib and selectedRecipeID then
        -- Use cache if same recipe
        if ProfRecipes._specCacheID == selectedRecipeID and ProfRecipes._specCacheData then
            specData = ProfRecipes._specCacheData
        else
            -- Try CraftSim's tracked recipe first
            local rd = CraftSimLib.INIT and CraftSimLib.INIT.currentRecipeData
            if rd and rd.recipeID == selectedRecipeID and rd.specializationData then
                specData = rd.specializationData
            elseif CraftSimLib.RecipeData then
                -- Create our own RecipeData (CraftSim doesn't track KC's selection)
                local ok, newRd = pcall(function()
                    return CraftSimLib.RecipeData({ recipeID = selectedRecipeID })
                end)
                if ok and newRd and newRd.specializationData then
                    specData = newRd.specializationData
                end
            end
            ProfRecipes._specCacheID = selectedRecipeID
            ProfRecipes._specCacheData = specData
        end
    end

    if specData and specData.isImplemented ~= false then
        -- Stats summary line
        local statsLines = {}
        local ps = specData.professionStats
        local mps = specData.maxProfessionStats
        if ps and mps then
            if ps.skill and ps.skill.value and ps.skill.value > 0 then
                table.insert(statsLines, string.format("Skill: |cffffffff%d|r / %d",
                    ps.skill.value, mps.skill and mps.skill.value or 0))
            end
            if ps.multicraft and ps.multicraft.value and ps.multicraft.value > 0 then
                table.insert(statsLines, string.format("MC: |cffffffff%d|r / %d",
                    ps.multicraft.value, mps.multicraft and mps.multicraft.value or 0))
            end
            if ps.ingenuity and ps.ingenuity.value and ps.ingenuity.value > 0 then
                table.insert(statsLines, string.format("Ing: |cffffffff%d|r / %d",
                    ps.ingenuity.value, mps.ingenuity and mps.ingenuity.value or 0))
            end
            if ps.resourcefulness and ps.resourcefulness.value and ps.resourcefulness.value > 0 then
                table.insert(statsLines, string.format("Res: |cffffffff%d|r / %d",
                    ps.resourcefulness.value, mps.resourcefulness and mps.resourcefulness.value or 0))
            end
        end

        detail.specHeader:ClearAllPoints()
        detail.specHeader:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -8, -8)
        detail.specHeader:Show()

        if #statsLines > 0 then
            detail.specStatsText:SetText(table.concat(statsLines, "\n"))
            detail.specStatsText:ClearAllPoints()
            detail.specStatsText:SetPoint("TOPRIGHT", detail.specHeader, "BOTTOMRIGHT", 0, -4)
            detail.specStatsText:SetJustifyH("RIGHT")
            detail.specStatsText:SetWidth(200)
            detail.specStatsText:Show()
        else
            detail.specStatsText:Hide()
        end

        -- Node list — sort: active first, then by rank descending
        local nodeList = {}
        for _, nd in pairs(specData.nodeData) do
            table.insert(nodeList, nd)
        end
        table.sort(nodeList, function(a, b)
            if a.active ~= b.active then return a.active end
            if a.active and b.active then
                if a.rank == a.maxRank and b.rank ~= b.maxRank then return true end
                if b.rank == b.maxRank and a.rank ~= a.maxRank then return false end
                return a.rank > b.rank
            end
            return false
        end)

        local nodeCount = math.min(#nodeList, MAX_SPEC_NODE_ROWS)
        for i = 1, nodeCount do
            local nd = nodeList[i]
            local row = detail.specNodeRows[i]
            row.icon:SetTexture(nd.icon or 134400)
            if nd.active then
                row.nameText:SetText(nd.name or "?")
                row.nameText:SetTextColor(unpack(ns.COLORS.brightText))
                local rankColor = (nd.rank == nd.maxRank) and "|cff4ecc4e" or "|cffffffff"
                row.rankText:SetText(string.format("(%s%d|r/%d)", rankColor, nd.rank, nd.maxRank))
                row.rankText:SetTextColor(unpack(ns.COLORS.mutedText))
                row.icon:SetDesaturated(false)
            else
                row.nameText:SetText(nd.name or "?")
                row.nameText:SetTextColor(0.5, 0.5, 0.5)
                row.rankText:SetText(string.format("(-/%d)", nd.maxRank))
                row.rankText:SetTextColor(0.5, 0.5, 0.5)
                row.icon:SetDesaturated(true)
            end

            -- Tooltip on hover
            row:EnableMouse(true)
            row.nodeData = nd
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if nd.GetTooltipText then
                    GameTooltip:SetText(nd.name or "Specialization", 1, 0.82, 0)
                    local tt = nd:GetTooltipText()
                    if tt and tt ~= "" then
                        GameTooltip:AddLine(tt, 1, 1, 1, true)
                    end
                else
                    GameTooltip:SetText(nd.name or "Specialization", 1, 0.82, 0)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row:Show()
        end
        for i = nodeCount + 1, MAX_SPEC_NODE_ROWS do
            detail.specNodeRows[i]:Hide()
        end

        detail.specNodeFrame:ClearAllPoints()
        local nodeAnchor = detail.specStatsText:IsShown() and detail.specStatsText or detail.specHeader
        detail.specNodeFrame:SetPoint("TOPRIGHT", nodeAnchor, "BOTTOMRIGHT", 0, -4)
        detail.specNodeFrame:SetWidth(200)
        detail.specNodeFrame:SetHeight(math.max(1, nodeCount * SPEC_NODE_ROW_HEIGHT))
        detail.specNodeFrame:Show()
    else
        detail.specHeader:Hide()
        detail.specStatsText:Hide()
        detail.specNodeFrame:Hide()
        for i = 1, MAX_SPEC_NODE_ROWS do
            detail.specNodeRows[i]:Hide()
        end
    end

    -- ── SIM Panel ──
    ProfRecipes:RefreshSimPanel(schematic, lastAnchor)

    -- TSM cost / profit — hide when sim panel is active (sim has better data)
    local hasTSM = ns.TSMData and ns.TSMData:IsAvailable()
    if detail.simFrame:IsShown() then
        hasTSM = false -- sim panel handles cost/profit display
    end
    if hasTSM and schematic then
        -- Get the crafted item
        local outputItemID = schematic.outputItemID
        local craftCost, sellValue

        -- Market sell value
        if outputItemID then
            sellValue = ns.TSMData:GetPrice(outputItemID, "DBMarket")
        end

        -- Crafting cost: sum reagent costs
        if schematic.reagentSlotSchematics then
            local total = 0
            local missing = false
            for _, slot in ipairs(schematic.reagentSlotSchematics) do
                if slot.reagentType == Enum.CraftingReagentType.Basic then
                    local reagents = slot.reagents
                    local qty = slot.quantityRequired or 1
                    if reagents and reagents[1] then
                        local rItemID = reagents[1].itemID
                        if rItemID then
                            local val = ns.TSMData:GetPrice(rItemID, "DBMinBuyout")
                            if val and val > 0 then
                                total = total + (val * qty)
                            else
                                missing = true
                            end
                        end
                    end
                end
            end
            if total > 0 then craftCost = total end
            if missing then craftCost = nil end
        end

        if craftCost then
            detail.tsmCostLabel:ClearAllPoints()
            detail.tsmCostLabel:SetPoint("BOTTOMLEFT", detail.controlFrame, "TOPLEFT", 0, 22)
            detail.tsmCostValue:SetText(ns.FormatGold(craftCost))
            detail.tsmCostValue:SetTextColor(unpack(ns.COLORS.brightText))
            detail.tsmCostLabel:Show()
            detail.tsmCostValue:Show()

            detail.tsmProfitLabel:ClearAllPoints()
            detail.tsmProfitLabel:SetPoint("BOTTOMLEFT", detail.controlFrame, "TOPLEFT", 0, 6)

            if sellValue then
                local profit = sellValue - craftCost
                detail.tsmProfitValue:SetText(ns.FormatGold(math.abs(profit)))
                if profit >= 0 then
                    detail.tsmProfitValue:SetTextColor(0.3, 0.85, 0.3)
                    detail.tsmProfitLabel:SetText("Profit:")
                else
                    detail.tsmProfitValue:SetTextColor(0.85, 0.3, 0.3)
                    detail.tsmProfitLabel:SetText("Loss:")
                end
            else
                detail.tsmProfitValue:SetText("|cff888888(no price data)|r")
                detail.tsmProfitValue:SetTextColor(unpack(ns.COLORS.mutedText))
                detail.tsmProfitLabel:SetText("Profit:")
            end
            detail.tsmProfitLabel:Show()
            detail.tsmProfitValue:Show()
        else
            detail.tsmCostLabel:Hide()
            detail.tsmCostValue:Hide()
            detail.tsmProfitLabel:Hide()
            detail.tsmProfitValue:Hide()
        end
    else
        detail.tsmCostLabel:Hide()
        detail.tsmCostValue:Hide()
        detail.tsmProfitLabel:Hide()
        detail.tsmProfitValue:Hide()
    end

    -- Craft controls (pinned to bottom, just show/hide)
    detail.controlFrame:Show()

    -- Craft All label
    local craftable = info.numAvailable or 0
    if craftable > 0 then
        detail.craftAllBtn.label:SetText("Craft All: " .. craftable)
    else
        detail.craftAllBtn.label:SetText("Craft All")
    end

    -- Enable/disable craft buttons
    if isCrafting then
        detail.craftBtn:Disable()
        detail.craftAllBtn:Disable()
        detail.craftBtn.label:SetTextColor(unpack(ns.COLORS.mutedText))
        detail.craftAllBtn.label:SetTextColor(unpack(ns.COLORS.mutedText))
    else
        detail.craftBtn:Enable()
        detail.craftAllBtn:Enable()
        detail.craftBtn.label:SetTextColor(unpack(ns.COLORS.ctrlText))
        detail.craftAllBtn.label:SetTextColor(unpack(ns.COLORS.ctrlText))
    end

end

--------------------------------------------------------------------
-- Sim Panel — populate UI & create CraftSim RecipeData
--------------------------------------------------------------------
function ProfRecipes:RefreshSimPanel(schematic, detailAnchor)
    if not CraftSimLib or not schematic or not selectedRecipeID then
        detail.simFrame:Hide()
        simRecipeData = nil
        return
    end

    -- Determine if recipe has quality reagents or finishing reagent slots
    local qualitySlots = {}
    local finishSlots = {}
    if schematic.reagentSlotSchematics then
        local hasProfTemplates = (Professions and Professions.GetReagentInputMode) and true or false
        for slotIndex, slot in ipairs(schematic.reagentSlotSchematics) do
            if slot.reagentType == Enum.CraftingReagentType.Basic and hasProfTemplates then
                local inputMode = Professions.GetReagentInputMode(slot)
                if inputMode == Professions.ReagentInputMode.Quality then
                    table.insert(qualitySlots, { slotIndex = slotIndex, slot = slot })
                end
            elseif slot.reagentType == Enum.CraftingReagentType.Finishing then
                table.insert(finishSlots, { slotIndex = slotIndex, slot = slot })
            end
        end
    end

    if #qualitySlots == 0 and #finishSlots == 0 then
        detail.simFrame:Hide()
        simRecipeData = nil
        return
    end

    -- Create/refresh CraftSim RecipeData for simulation
    local isNewRecipe = not simRecipeData or simRecipeData.recipeID ~= selectedRecipeID
    if isNewRecipe then
        local ok, rd = pcall(function()
            return CraftSimLib.RecipeData({ recipeID = selectedRecipeID })
        end)
        if ok and rd then
            simRecipeData = rd
        else
            detail.simFrame:Hide()
            simRecipeData = nil
            return
        end
    end

    -- Anchor sim panel below detailAnchor (which is the last detail element)
    detail.simFrame:ClearAllPoints()
    detail.simFrame:SetPoint("TOPLEFT", detailAnchor, "BOTTOMLEFT", -8, -10)
    detail.simFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)

    -- Populate quality reagent rows
    local reagentRowCount = math.min(#qualitySlots, MAX_SIM_REAGENT_ROWS)
    local showReagents = reagentRowCount > 0

    if showReagents then
        detail.simReagentLabel:Show()
        detail.simReagentFrame:Show()
    else
        detail.simReagentLabel:Hide()
        detail.simReagentFrame:Hide()
    end

    for i = 1, reagentRowCount do
        local qs = qualitySlots[i]
        local slot = qs.slot
        local row = simReagentRows[i]
        row.slotData = slot
        row.slotIndex = qs.slotIndex

        -- Icon from first reagent tier + tooltip itemID
        local firstR = slot.reagents and slot.reagents[1]
        if firstR then
            local _, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(firstR.itemID)
            row.icon:SetTexture(itemIcon or 134400)
            row.iconBtn.itemID = firstR.itemID
            if not itemIcon then
                C_Item.RequestLoadItemDataByID(firstR.itemID)
            end
        end

        -- Pre-populate from current transaction allocation (only on recipe change)
        local needed = slot.quantityRequired or 0
        for t = 1, 3 do
            if isNewRecipe then
                local allocated = 0
                if currentTransaction and slot.reagents[t] then
                    local allocs = currentTransaction:GetAllocations(qs.slotIndex)
                    if allocs and type(allocs.GetQuantityAllocated) == "function" then
                        allocated = allocs:GetQuantityAllocated(slot.reagents[t])
                    end
                end
                row.edits[t]:SetText(tostring(allocated))
            end
            -- Hide T3 edit if only 2 tiers exist
            if t > #slot.reagents then
                row.edits[t]:Hide()
            else
                row.edits[t]:Show()
            end
        end

        local total = 0
        for t = 1, math.min(3, #slot.reagents) do
            total = total + (tonumber(row.edits[t]:GetText()) or 0)
        end
        local totalColor = (total == needed) and "|cff4dff4d" or "|cffff4d4d"
        row.totalText:SetText(totalColor .. "= " .. total .. "/" .. needed .. "|r")
        row:Show()
    end
    for i = reagentRowCount + 1, MAX_SIM_REAGENT_ROWS do
        simReagentRows[i]:Hide()
    end
    detail.simReagentFrame:SetHeight(math.max(1, reagentRowCount * 24))

    -- Finishing reagent dropdowns
    local showFinishing = #finishSlots > 0
    if showFinishing then
        detail.simFinishingLabel:ClearAllPoints()
        if showReagents then
            detail.simFinishingLabel:SetPoint("TOPLEFT", detail.simReagentFrame, "BOTTOMLEFT", 0, -6)
        else
            detail.simFinishingLabel:SetPoint("TOPLEFT", detail.simHeader, "BOTTOMLEFT", 0, -6)
        end
        detail.simFinishingLabel:Show()

        for i = 1, math.min(#finishSlots, SIM_FINISHING_SLOTS) do
            local fs = finishSlots[i]
            local dd = simFinishingDrops[i]
            dd.slotData = fs.slot

            -- Build options list from slot reagents
            local opts = { "None" }
            local optItemIDs = { 0 }
            for _, r in ipairs(fs.slot.reagents) do
                local itemName = C_Item.GetItemInfo(r.itemID)
                if not itemName then
                    C_Item.RequestLoadItemDataByID(r.itemID)
                    itemName = "Item:" .. r.itemID
                end
                table.insert(opts, itemName)
                table.insert(optItemIDs, r.itemID)
            end
            dd:SetOptions(opts)
            dd.optItemIDs = optItemIDs

            -- Set default from current transaction (only on recipe change)
            if isNewRecipe then
                local currentName = "None"
                if currentTransaction then
                    local allocs = currentTransaction:GetAllocations(fs.slotIndex)
                    if allocs then
                        for _, r in ipairs(fs.slot.reagents) do
                            if allocs.GetQuantityAllocated and allocs:GetQuantityAllocated(r) > 0 then
                                local rName = C_Item.GetItemInfo(r.itemID)
                                if rName then currentName = rName end
                                break
                            end
                        end
                    end
                end
                dd:SetSelected(currentName)
            end

            dd:ClearAllPoints()
            if i == 1 then
                dd:SetPoint("TOPLEFT", detail.simFinishingLabel, "BOTTOMLEFT", 0, -4)
            else
                dd:SetPoint("LEFT", simFinishingDrops[i - 1], "RIGHT", 6, 0)
            end
            dd:Show()
        end
        for i = #finishSlots + 1, SIM_FINISHING_SLOTS do
            simFinishingDrops[i]:Hide()
        end
    else
        detail.simFinishingLabel:Hide()
        for i = 1, SIM_FINISHING_SLOTS do
            simFinishingDrops[i]:Hide()
        end
    end

    -- Result section anchoring
    local resultAnchor
    if showFinishing then
        resultAnchor = simFinishingDrops[1]
    elseif showReagents then
        resultAnchor = detail.simReagentFrame
    else
        resultAnchor = detail.simHeader
    end

    detail.simDivider:ClearAllPoints()
    detail.simDivider:SetPoint("TOPLEFT", resultAnchor, "BOTTOMLEFT", 0, -8)
    detail.simDivider:SetPoint("RIGHT", detail.simFrame, "RIGHT", -8, 0)

    detail.simQualityText:ClearAllPoints()
    detail.simQualityText:SetPoint("TOPLEFT", detail.simDivider, "BOTTOMLEFT", 0, -4)

    detail.simSkillText:ClearAllPoints()
    detail.simSkillText:SetPoint("TOPLEFT", detail.simQualityText, "BOTTOMLEFT", 0, -2)

    detail.simCostText:ClearAllPoints()
    detail.simCostText:SetPoint("TOPLEFT", detail.simSkillText, "BOTTOMLEFT", 0, -2)

    detail.simProfitText:ClearAllPoints()
    detail.simProfitText:SetPoint("TOPLEFT", detail.simCostText, "BOTTOMLEFT", 0, -2)

    detail.simConcText:ClearAllPoints()
    detail.simConcText:SetPoint("TOPLEFT", detail.simProfitText, "BOTTOMLEFT", 0, -2)

    detail.simOptBtn:ClearAllPoints()
    detail.simOptBtn:SetPoint("TOPLEFT", detail.simConcText, "BOTTOMLEFT", 0, -6)

    detail.simApplyBtn:ClearAllPoints()
    detail.simApplyBtn:SetPoint("LEFT", detail.simOptBtn, "RIGHT", 6, 0)

    detail.simQueueBtn:ClearAllPoints()
    detail.simQueueBtn:SetPoint("LEFT", detail.simApplyBtn, "RIGHT", 6, 0)

    -- Set total height
    local totalH = 6 -- top pad
    totalH = totalH + 14 -- header
    totalH = totalH + 6 -- gap
    if showReagents then
        totalH = totalH + 12 + (reagentRowCount * 24) + 6 -- label + rows + gap
    end
    if showFinishing then
        totalH = totalH + 12 + 4 + 24 + 6 -- label + gap + dropdown + gap
    end
    totalH = totalH + 12 + 4 + 14 + 2 + 14 + 2 + 14 + 2 + 14 + 2 + 14 + 6 + 22 + 8 -- result section (header + quality + skill + cost + profit + conc + buttons)
    detail.simFrame:SetHeight(totalH)

    detail.simFrame:Show()

    -- Run initial sim calculation
    ProfRecipes:RefreshSimResults()
end

--------------------------------------------------------------------
-- Sim Panel — recalculate results from current editbox values
--------------------------------------------------------------------
function ProfRecipes:RefreshSimResults()
    if not simRecipeData or not CraftSimLib then return end

    -- Build reagent list from editboxes
    local reagentList = {}
    for i = 1, MAX_SIM_REAGENT_ROWS do
        local row = simReagentRows[i]
        if not row:IsShown() then break end
        local slot = row.slotData
        if slot and slot.reagents then
            for t = 1, math.min(3, #slot.reagents) do
                local qty = tonumber(row.edits[t]:GetText()) or 0
                if qty > 0 and slot.reagents[t] then
                    table.insert(reagentList, {
                        itemID = slot.reagents[t].itemID,
                        quantity = qty,
                    })
                end
            end
        end
    end

    -- Apply reagents to sim RecipeData
    local ok = pcall(function()
        simRecipeData:SetReagents(reagentList)
    end)
    if not ok then return end

    -- Apply finishing reagents from dropdowns
    local finishingIDs = {}
    for i = 1, SIM_FINISHING_SLOTS do
        local dd = simFinishingDrops[i]
        if dd:IsShown() and dd.optItemIDs then
            local sel = dd:GetSelected()
            if sel and sel ~= "None" then
                -- Find matching itemID
                for idx, opt in ipairs(dd.options) do
                    if opt == sel and dd.optItemIDs[idx] and dd.optItemIDs[idx] > 0 then
                        table.insert(finishingIDs, dd.optItemIDs[idx])
                        break
                    end
                end
            end
        end
    end

    if #finishingIDs > 0 then
        pcall(function() simRecipeData:SetOptionalReagents(finishingIDs) end)
    end

    -- Update (SetOptionalReagents calls Update internally, but SetReagents does not)
    pcall(function() simRecipeData:Update() end)

    -- Get quality from Blizzard API with sim reagent allocation
    local reagentInfoTbl = {}
    pcall(function()
        reagentInfoTbl = simRecipeData.reagentData:GetCraftingReagentInfoTbl()
    end)
    local applyConc = detail.concCheck:GetChecked() and true or false
    local opInfo = C_TradeSkillUI.GetCraftingOperationInfo(selectedRecipeID, reagentInfoTbl, nil, applyConc)

    -- Quality display
    if opInfo and opInfo.craftingQualityID and opInfo.craftingQualityID > 0 then
        local qTier = opInfo.craftingQuality or 0
        local maxTier = opInfo.maxCraftingQuality or 5
        local pips = ""
        for j = 1, maxTier do
            if j <= qTier then
                pips = pips .. "|A:Professions-Icon-Quality-Tier" .. j .. "-Small:0:0|a"
            else
                pips = pips .. "|cff666666*|r"
            end
        end
        detail.simQualityText:SetText("Quality: " .. pips)
    else
        detail.simQualityText:SetText("Quality: —")
    end

    -- Skill display
    if opInfo and opInfo.baseSkill and opInfo.baseDifficulty then
        local totalSkill = (opInfo.baseSkill or 0) + (opInfo.bonusSkill or 0)
        detail.simSkillText:SetText("Skill: " .. totalSkill .. " / " .. opInfo.baseDifficulty)
    else
        detail.simSkillText:SetText("Skill: —")
    end

    -- Craft cost via CraftSim
    local craftCost = simRecipeData.priceData and simRecipeData.priceData.craftingCosts
    if craftCost and craftCost > 0 then
        detail.simCostText:SetText("Cost: " .. ns.FormatGold(craftCost))
    else
        detail.simCostText:SetText("Cost: —")
    end

    -- Profit via CraftSim
    local profit = simRecipeData.averageProfitCached
    if profit then
        local absProfit = math.abs(profit)
        if profit >= 0 then
            detail.simProfitText:SetText("Profit: |cff4dff4d" .. ns.FormatGold(absProfit) .. "|r")
        else
            detail.simProfitText:SetText("Loss: |cffff4d4d" .. ns.FormatGold(absProfit) .. "|r")
        end
    else
        detail.simProfitText:SetText("Profit: —")
        detail.simProfitText:SetTextColor(unpack(ns.COLORS.mutedText))
    end

    -- Concentration cost
    if opInfo and opInfo.concentrationCost and opInfo.concentrationCost > 0 then
        detail.simConcText:SetText("Conc: " .. opInfo.concentrationCost)
    else
        detail.simConcText:SetText("Conc: —")
    end

    -- Update reagent row totals (validate)
    for i = 1, MAX_SIM_REAGENT_ROWS do
        local row = simReagentRows[i]
        if not row:IsShown() then break end
        local slot = row.slotData
        if slot then
            local needed = slot.quantityRequired or 0
            local total = 0
            for t = 1, math.min(3, #slot.reagents) do
                total = total + (tonumber(row.edits[t]:GetText()) or 0)
            end
            local totalColor = (total == needed) and "|cff4dff4d" or "|cffff4d4d"
            row.totalText:SetText(totalColor .. "= " .. total .. "/" .. needed .. "|r")
        end
    end
end

--------------------------------------------------------------------
-- Sim Panel — apply sim allocation to real transaction
--------------------------------------------------------------------
function ProfRecipes:ApplySimToTransaction()
    if not currentTransaction or not currentSchematic then return end
    if not currentSchematic.reagentSlotSchematics then return end

    local hasProfTemplates = (Professions and Professions.GetReagentInputMode) and true or false
    if not hasProfTemplates then return end

    -- Apply quality reagent allocations from sim editboxes
    local rowIdx = 0
    for slotIndex, slot in ipairs(currentSchematic.reagentSlotSchematics) do
        if slot.reagentType == Enum.CraftingReagentType.Basic then
            local inputMode = Professions.GetReagentInputMode(slot)
            if inputMode == Professions.ReagentInputMode.Quality then
                rowIdx = rowIdx + 1
                local row = simReagentRows[rowIdx]
                if row and row:IsShown() then
                    currentTransaction:ClearAllocations(slotIndex)
                    for t = 1, math.min(3, #slot.reagents) do
                        local qty = tonumber(row.edits[t]:GetText()) or 0
                        if qty > 0 then
                            currentTransaction:OverwriteAllocation(slotIndex, slot.reagents[t], qty)
                        end
                    end
                end
            end
        end
    end

    -- Apply finishing reagent selections from sim dropdowns
    for i = 1, SIM_FINISHING_SLOTS do
        local dd = simFinishingDrops[i]
        if dd:IsShown() and dd.slotData then
            local sel = dd:GetSelected()
            -- Find matching slot in schematic
            for slotIndex, slot in ipairs(currentSchematic.reagentSlotSchematics) do
                if slot == dd.slotData then
                    currentTransaction:ClearAllocations(slotIndex)
                    if sel and sel ~= "None" and dd.optItemIDs then
                        for idx, opt in ipairs(dd.options) do
                            if opt == sel and dd.optItemIDs[idx] and dd.optItemIDs[idx] > 0 then
                                -- Find matching reagent in slot
                                for _, r in ipairs(slot.reagents) do
                                    if r.itemID == dd.optItemIDs[idx] then
                                        currentTransaction:OverwriteAllocation(slotIndex, r, 1)
                                        break
                                    end
                                end
                                break
                            end
                        end
                    end
                    break
                end
            end
        end
    end

    -- Refresh detail to show updated allocation
    ProfRecipes:RefreshDetail()
    print("|cff00ccffKazCraft|r: Sim allocation applied")
end

--------------------------------------------------------------------
-- Init / Show / Hide / Refresh (tab interface)
--------------------------------------------------------------------
function ProfRecipes:Init(parent)
    if initialized then return end
    initialized = true
    parentFrame = parent

    CreateLeftPanel(parent)
    CreateRightPanel(parent)
end

function ProfRecipes:Show()
    if not initialized then return end
    -- Restore last selected recipe
    if not selectedRecipeID and KazCraftDB and ns.currentProfName then
        if type(KazCraftDB.lastRecipeID) ~= "table" then KazCraftDB.lastRecipeID = {} end
        selectedRecipeID = KazCraftDB.lastRecipeID[ns.currentProfName]
    end
    leftPanel:Show()
    rightPanel:Show()
    self:OnResize()  -- recalculate visible rows from actual panel height
    self:RefreshRecipeList(true)
    -- Scroll to selected recipe if possible
    if selectedRecipeID then
        for i, entry in ipairs(displayList) do
            if entry.type == "recipe" and entry.recipeID == selectedRecipeID then
                scrollOffset = math.max(0, i - 5)
                scrollOffset = math.min(scrollOffset, math.max(0, #displayList - MAX_VISIBLE_ROWS))
                self:RefreshRows()
                break
            end
        end
    end
    self:RefreshDetail()
end

function ProfRecipes:Hide()
    if not initialized then return end
    leftPanel:Hide()
    rightPanel:Hide()
    if filterMenu then filterMenu:Hide() end
    if CloseProfessionsItemFlyout then
        pcall(CloseProfessionsItemFlyout)
    end
    currentTransaction = nil
    currentSchematic = nil
    lastTransactionRecipeID = nil
    simRecipeData = nil
end

function ProfRecipes:IsShown()
    return initialized and leftPanel and leftPanel:IsShown()
end

function ProfRecipes.GetConcentrationChecked()
    return detail.concCheck and detail.concCheck:GetChecked() and true or false
end

function ProfRecipes:Refresh()
    self:RefreshRecipeList()
    self:RefreshDetail()
end

function ProfRecipes:SetCrafting(crafting)
    isCrafting = crafting
    if detail.craftBtn then
        if crafting then
            detail.craftBtn:Disable()
            detail.craftAllBtn:Disable()
        else
            detail.craftBtn:Enable()
            detail.craftAllBtn:Enable()
        end
    end
end

function ProfRecipes:OnResize()
    -- Recalculate visible rows based on new height
    if recipeContent then
        local height = recipeContent:GetHeight()
        MAX_VISIBLE_ROWS = math.floor(height / RECIPE_ROW_HEIGHT)
        -- Create additional rows if needed
        for i = #recipeRows + 1, MAX_VISIBLE_ROWS do
            recipeRows[i] = CreateRecipeRow(recipeContent, i)
        end
        self:RefreshRows()
    end
end
