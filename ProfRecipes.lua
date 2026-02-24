local addonName, ns = ...

local ProfRecipes = {}
ns.ProfRecipes = ProfRecipes

local LEFT_WIDTH = 300
local RECIPE_ROW_HEIGHT = 22
local REAGENT_ROW_HEIGHT = 26
local QUEUE_ROW_HEIGHT = 24
local MAX_VISIBLE_ROWS = 28
local MAX_REAGENT_ROWS = 10
local MAX_QUEUE_ROWS = 8

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
local queueSection = {}
local queueRows = {}

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
end

--------------------------------------------------------------------
-- Recipe difficulty color
--------------------------------------------------------------------
local function GetDifficultyColor(info)
    if not info then return DIFFICULTY_COLORS.default end
    -- difficulty: 0 = trivial, 1 = easy, 2 = medium, 3 = optimal
    local d = info.difficulty
    if d == nil or d == 0 then return DIFFICULTY_COLORS.trivial end
    if d == 1 then return DIFFICULTY_COLORS.easy end
    if d == 2 then return DIFFICULTY_COLORS.medium end
    if d == 3 then return DIFFICULTY_COLORS.optimal end
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

    -- Favorite star
    row.favText = row:CreateFontString(nil, "OVERLAY")
    row.favText:SetFont(ns.FONT, 12, "")
    row.favText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.favText:SetText("|cffffd700*|r")
    row.favText:Hide()

    row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        self.leftAccent:Show()
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
        row:Show()
        row.icon:Hide()
        row.arrow:Hide()
        row.countText:Hide()
        row.favText:Hide()
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
        row.arrow:Hide()

        -- Craftable count (left of icon)
        local craftable = info and info.numAvailable or 0
        row.countText:ClearAllPoints()
        row.countText:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
        if craftable > 0 then
            row.countText:SetText(craftable)
            row.countText:SetTextColor(unpack(ns.COLORS.greenText))
            row.countText:Show()
        else
            row.countText:SetText("")
            row.countText:Hide()
        end

        row.icon:Show()
        row.icon:ClearAllPoints()
        if craftable > 0 then
            row.icon:SetPoint("LEFT", row.countText, "RIGHT", 2, 0)
        else
            row.icon:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
        end
        row.icon:SetTexture(info and info.icon or 134400)

        row.nameText:Show()
        row.nameText:ClearAllPoints()
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.nameText:SetPoint("RIGHT", row, "RIGHT", -20, 0)
        row.nameText:SetText(info and info.name or ("Recipe " .. entry.recipeID))
        row.nameText:SetFont(ns.FONT, 14, "")
        local color = GetDifficultyColor(info)
        row.nameText:SetTextColor(color[1], color[2], color[3])

        -- Favorite
        if info and info.favorite then
            row.favText:Show()
        else
            row.favText:Hide()
        end

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
            if KazCraftDB then KazCraftDB.lastRecipeID = selectedRecipeID end
            ProfRecipes:RefreshRows()
            ProfRecipes:RefreshDetail()
        end)
    end

    row:Show()
end

--------------------------------------------------------------------
-- Scroll handling
--------------------------------------------------------------------
local function OnRecipeScroll(self, delta)
    scrollOffset = math.max(0, math.min(scrollOffset - delta, math.max(0, #displayList - MAX_VISIBLE_ROWS)))
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
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.itemID then
            GameTooltip:SetItemByID(self.itemID)
        elseif self.slotSchematic then
            GameTooltip:SetText(self.slotSchematic.slotText or "Optional Reagent", 1, 1, 1)
            GameTooltip:AddLine("Click to select a reagent", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
        GameTooltip:Hide()
    end)

    box:Hide()
    return box
end

local function CreateQueueRowSmall(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(QUEUE_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * QUEUE_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * QUEUE_ROW_HEIGHT)
    row:Hide()

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 12, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -72, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    row.qtyText = row:CreateFontString(nil, "OVERLAY")
    row.qtyText:SetFont(ns.FONT, 12, "")
    row.qtyText:SetPoint("RIGHT", row, "RIGHT", -52, 0)
    row.qtyText:SetWidth(24)
    row.qtyText:SetJustifyH("CENTER")
    row.qtyText:SetTextColor(unpack(ns.COLORS.brightText))

    -- [-] [+] [x] buttons
    local function MiniBtn(parent, text, offsetX, defaultColor, hoverColor)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(16, 16)
        btn:SetPoint("RIGHT", parent, "RIGHT", offsetX, 0)
        btn.t = btn:CreateFontString(nil, "OVERLAY")
        btn.t:SetFont(ns.FONT, 14, "")
        btn.t:SetPoint("CENTER")
        btn.t:SetText(text)
        btn.t:SetTextColor(unpack(defaultColor))
        btn:SetScript("OnEnter", function(self) self.t:SetTextColor(unpack(hoverColor)) end)
        btn:SetScript("OnLeave", function(self) self.t:SetTextColor(unpack(defaultColor)) end)
        return btn
    end

    row.minusBtn = MiniBtn(row, "-", -36, ns.COLORS.btnDefault, ns.COLORS.btnHover)
    row.plusBtn  = MiniBtn(row, "+", -20, ns.COLORS.btnDefault, ns.COLORS.btnHover)
    row.removeBtn = MiniBtn(row, "x", -4, ns.COLORS.closeDefault, ns.COLORS.closeHover)

    return row
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

    -- Detail content (direct child, no scroll)
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

    detail.subtypeText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.subtypeText:SetFont(ns.FONT, 14, "")
    detail.subtypeText:SetPoint("LEFT", detail.icon, "RIGHT", 8, 0)
    detail.subtypeText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- ── Reagents ──
    local reagentY = -80
    detail.reagentHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.reagentHeader:SetFont(ns.FONT, 12, "")
    detail.reagentHeader:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 8, reagentY)
    detail.reagentHeader:SetText("REAGENTS")
    detail.reagentHeader:SetTextColor(unpack(ns.COLORS.headerText))

    detail.reagentFrame = CreateFrame("Frame", nil, detailFrame)
    detail.reagentFrame:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 8, reagentY - 18)
    detail.reagentFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    detail.reagentFrame:SetHeight(MAX_REAGENT_ROWS * REAGENT_ROW_HEIGHT)

    for i = 1, MAX_REAGENT_ROWS do
        reagentRows[i] = CreateReagentRow(detail.reagentFrame, i)
    end

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
        ns.lastCraftedRecipeID = nil -- don't decrement queue for manual crafts
        local reagentInfoTbl = currentTransaction and currentTransaction:CreateCraftingReagentInfoTbl() or {}
        C_TradeSkillUI.CraftRecipe(selectedRecipeID, qty, reagentInfoTbl, nil, nil, applyConc)
    end)

    -- Craft All button
    detail.craftAllBtn = ns.CreateButton(detail.controlFrame, "Craft All", 70, 24)
    detail.craftAllBtn:SetPoint("LEFT", detail.craftBtn, "RIGHT", 4, 0)
    detail.craftAllBtn:SetScript("OnClick", function()
        if not selectedRecipeID or isCrafting then return end
        local info = C_TradeSkillUI.GetRecipeInfo(selectedRecipeID)
        local count = info and info.numAvailable or 0
        if count > 0 then
            local applyConc = detail.concCheck:GetChecked() and true or false
            ns.lastCraftedRecipeID = nil
            local reagentInfoTbl = currentTransaction and currentTransaction:CreateCraftingReagentInfoTbl() or {}
            C_TradeSkillUI.CraftRecipe(selectedRecipeID, count, reagentInfoTbl, nil, nil, applyConc)
        end
    end)

    -- +Queue button (hidden for now — queue UI coming later)
    detail.queueBtn = ns.CreateButton(detail.controlFrame, "+Queue", 70, 24)
    detail.queueBtn:SetPoint("LEFT", detail.craftAllBtn, "RIGHT", 4, 0)
    detail.queueBtn:Hide()
    detail.queueBtn:SetScript("OnClick", function()
        if not selectedRecipeID then return end
        local qty = tonumber(detail.qtyBox:GetText()) or 1
        if qty < 1 then qty = 1 end

        if not KazCraftDB.recipeCache[selectedRecipeID] then
            ns.Data:CacheSchematic(selectedRecipeID, ns.currentProfName)
        end

        ns.Data:AddToQueue(selectedRecipeID, qty)
        ProfRecipes:RefreshQueue()
        if ns.ProfFrame then ns.ProfFrame:UpdateFooter() end
    end)

    -- ── Queue (above craft controls) ──
    detail.queueHeader = rightPanel:CreateFontString(nil, "OVERLAY")
    detail.queueHeader:SetFont(ns.FONT, 12, "")
    detail.queueHeader:SetTextColor(unpack(ns.COLORS.headerText))
    -- anchored dynamically

    detail.queueFrame = CreateFrame("Frame", nil, rightPanel)
    detail.queueFrame:SetPoint("LEFT", rightPanel, "LEFT", 12, 0)
    detail.queueFrame:SetPoint("RIGHT", rightPanel, "RIGHT", -12, 0)
    detail.queueFrame:SetHeight(MAX_QUEUE_ROWS * QUEUE_ROW_HEIGHT)
    -- anchored dynamically

    for i = 1, MAX_QUEUE_ROWS do
        queueRows[i] = CreateQueueRowSmall(detail.queueFrame, i)
    end

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
local function SetupSlotBox(box, slotIndex, slotSchematic, transaction)
    box.slotIndex = slotIndex
    box.slotSchematic = slotSchematic
    box.itemID = nil

    -- Check if transaction has an allocation for this slot
    local allocs = transaction and transaction:GetAllocations(slotIndex)
    local hasAlloc = allocs and allocs:HasAllocations()

    if hasAlloc then
        for _, alloc in allocs:Enumerate() do
            local reagent = alloc:GetReagent()
            if reagent and reagent.itemID then
                box.itemID = reagent.itemID
                local _, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(reagent.itemID)
                box.icon:SetTexture(itemIcon or 134400)
                box.icon:Show()
                box.plusText:Hide()
                break
            end
        end
    else
        box.icon:Hide()
        box.plusText:Show()
    end

    -- OnClick: left = open flyout, right = clear
    box:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if transaction and transaction:HasAnyAllocations(slotIndex) then
                transaction:ClearAllocations(slotIndex)
                ProfRecipes:RefreshDetail()
            end
            return
        end

        -- Left click — open Blizzard flyout
        if not transaction or not slotSchematic then return end
        if not CreateProfessionsMCRFlyout then return end

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
            local function OnFlyoutItemSelected(o, f, elementData)
                local reagent = elementData.reagent
                if not reagent then return end
                local count = ProfessionsUtil.GetReagentQuantityInPossession(reagent, false)
                if count == 0 then return end
                local qtyReq = slotSchematic:GetQuantityRequired(reagent)
                if slotSchematic.required and count < qtyReq then return end
                transaction:OverwriteAllocation(slotIndex, reagent, qtyReq)
                ProfRecipes:RefreshDetail()
            end
            flyout:RegisterCallback(ProfessionsFlyoutMixin.Event.ItemSelected, OnFlyoutItemSelected, box)
        end
    end)

    box:Show()
end

function ProfRecipes:RefreshDetail()
    if not initialized or not detailFrame then return end

    if not selectedRecipeID then
        detail.emptyText:Show()
        detail.nameText:SetText("")
        detail.icon:SetTexture(nil)
        detail.subtypeText:SetText("")
        detail.reagentHeader:Hide()
        detail.reagentFrame:Hide()
        detail.optionalHeader:Hide()
        detail.optionalFrame:Hide()
        detail.finishingHeader:Hide()
        detail.finishingFrame:Hide()
        detail.detailHeader:Hide()
        detail.qualityText:Hide()
        detail.skillText:Hide()
        detail.concText:Hide()
        detail.sourceFrame:Hide()
        detail.controlFrame:Hide()
        detail.queueHeader:Hide()
        detail.queueFrame:Hide()
        detail.favBtn:Hide()
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
    local subtype = ""
    if info.categoryID then
        local catInfo = C_TradeSkillUI.GetCategoryInfo(info.categoryID)
        if catInfo then subtype = catInfo.name or "" end
    end
    detail.subtypeText:SetText(subtype)

    -- ── Transaction lifecycle ──
    local hasProfTemplates = (Professions and Professions.AllocateAllBasicReagents and
                              ProfessionsUtil and ProfessionsUtil.GetRecipeSchematic and
                              CreateProfessionsRecipeTransaction) and true or false

    if hasProfTemplates then
        if selectedRecipeID ~= lastTransactionRecipeID then
            currentSchematic = ProfessionsUtil.GetRecipeSchematic(selectedRecipeID, false)
            currentTransaction = CreateProfessionsRecipeTransaction(currentSchematic)
            lastTransactionRecipeID = selectedRecipeID
            Professions.AllocateAllBasicReagents(currentTransaction, useBest and true or false)
        end
    else
        -- Fallback: plain schematic, no transaction
        currentSchematic = C_TradeSkillUI.GetRecipeSchematic(selectedRecipeID, false)
        currentTransaction = nil
    end

    local schematic = currentSchematic

    -- ── Basic Reagents ──
    detail.reagentHeader:Show()
    detail.reagentFrame:Show()

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
                        if allocs then
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
        reagentRows[i]:Hide()
    end

    -- Adjust reagent frame height
    detail.reagentFrame:SetHeight(math.max(1, reagentCount * REAGENT_ROW_HEIGHT))

    -- ── Optional Reagents section ──
    local chainAnchor = detail.reagentFrame
    local chainAnchorPoint = "BOTTOMLEFT"
    local chainOffset = -10

    if #optionalSlots > 0 and currentTransaction then
        detail.optionalHeader:ClearAllPoints()
        detail.optionalHeader:SetPoint("TOPLEFT", chainAnchor, chainAnchorPoint, 0, chainOffset)
        detail.optionalHeader:Show()

        detail.optionalFrame:ClearAllPoints()
        detail.optionalFrame:SetPoint("TOPLEFT", detail.optionalHeader, "BOTTOMLEFT", 0, -4)
        detail.optionalFrame:Show()

        for i, entry in ipairs(optionalSlots) do
            if i > MAX_OPTIONAL_SLOTS then break end
            local box = optionalSlotFrames[i]
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", detail.optionalFrame, "TOPLEFT", (i - 1) * (SLOT_BOX_SIZE + SLOT_BOX_SPACING), 0)
            SetupSlotBox(box, entry.slotIndex, entry.slot, currentTransaction)
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
        detail.finishingFrame:Show()

        for i, entry in ipairs(finishingSlots) do
            if i > MAX_FINISHING_SLOTS then break end
            local box = finishingSlotFrames[i]
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", detail.finishingFrame, "TOPLEFT", (i - 1) * (SLOT_BOX_SIZE + SLOT_BOX_SPACING), 0)
            SetupSlotBox(box, entry.slotIndex, entry.slot, currentTransaction)
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
    local opInfo = C_TradeSkillUI.GetCraftingOperationInfo(selectedRecipeID, reagentInfoTbl, nil, applyConc)

    if opInfo then
        -- Quality display
        if opInfo.craftingQualityID and opInfo.craftingQualityID > 0 then
            local qTier = opInfo.craftingQuality or 0
            local maxTier = opInfo.maxCraftingQuality or 5
            local stars = ""
            for i = 1, maxTier do
                if i <= qTier then
                    stars = stars .. "|cffffd700*|r"
                else
                    stars = stars .. "|cff666666*|r"
                end
            end
            detail.qualityText:SetText("Quality: " .. stars)
        else
            detail.qualityText:SetText("")
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
        detail.skillText:Hide()
        detail.concText:Hide()
        detail.concCheck:SetChecked(false)
        detail.concCheck:Disable()
        detail.concLabel:SetTextColor(unpack(ns.COLORS.mutedText))
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

    local lastAnchor = detail.concText:IsShown() and detail.concText or
                       (detail.skillText:IsShown() and detail.skillText or detail.qualityText)

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

    -- Craft controls (pinned to bottom, just show/hide)
    detail.controlFrame:Show()

    -- Craft All label
    local craftable = info.numAvailable or 0
    if craftable > 0 then
        detail.craftAllBtn.label:SetText("Craft All: " .. craftable)
        detail.craftAllBtn:Enable()
    else
        detail.craftAllBtn.label:SetText("Craft All")
        detail.craftAllBtn:Disable()
    end

    -- Enable/disable craft button
    if isCrafting then
        detail.craftBtn:Disable()
        detail.craftAllBtn:Disable()
    else
        detail.craftBtn:Enable()
    end

    -- Queue section (hidden for now)
    detail.queueHeader:Hide()
    detail.queueFrame:Hide()
end

--------------------------------------------------------------------
-- Refresh queue section in detail panel
--------------------------------------------------------------------
function ProfRecipes:RefreshQueue()
    if not initialized or not detail.queueFrame then return end

    local queue = ns.Data:GetCharacterQueue()
    local count = #queue

    -- Anchor queue above craft controls
    detail.queueHeader:ClearAllPoints()
    detail.queueHeader:SetPoint("BOTTOMLEFT", detail.controlFrame, "TOPLEFT", 0, math.min(count, MAX_QUEUE_ROWS) * QUEUE_ROW_HEIGHT + 16)
    detail.queueHeader:SetText("QUEUE (" .. count .. ")")
    detail.queueHeader:Show()

    detail.queueFrame:ClearAllPoints()
    detail.queueFrame:SetPoint("TOPLEFT", detail.queueHeader, "BOTTOMLEFT", 0, -4)
    detail.queueFrame:SetPoint("RIGHT", rightPanel, "RIGHT", -12, 0)
    detail.queueFrame:SetHeight(math.max(1, math.min(count, MAX_QUEUE_ROWS) * QUEUE_ROW_HEIGHT))
    detail.queueFrame:Show()

    for i = 1, math.max(count, #queueRows) do
        local row = queueRows[i]
        if not row and i <= count then
            row = CreateQueueRowSmall(detail.queueFrame, i)
            queueRows[i] = row
        end
        if row then
            if i <= count then
                local entry = queue[i]
                local cached = KazCraftDB.recipeCache[entry.recipeID]

                row.icon:SetTexture(cached and cached.icon or 134400)
                row.nameText:SetText(cached and cached.recipeName or ("Recipe " .. entry.recipeID))
                row.qtyText:SetText("x" .. entry.quantity)

                local idx = i
                row.minusBtn:SetScript("OnClick", function()
                    ns.Data:AdjustQuantity(idx, -1)
                    ProfRecipes:RefreshQueue()
                    if ns.ProfFrame then ns.ProfFrame:UpdateFooter() end
                end)
                row.plusBtn:SetScript("OnClick", function()
                    ns.Data:AdjustQuantity(idx, 1)
                    ProfRecipes:RefreshQueue()
                    if ns.ProfFrame then ns.ProfFrame:UpdateFooter() end
                end)
                row.removeBtn:SetScript("OnClick", function()
                    ns.Data:RemoveFromQueue(idx)
                    ProfRecipes:RefreshQueue()
                    if ns.ProfFrame then ns.ProfFrame:UpdateFooter() end
                end)

                row:Show()
            else
                row:Hide()
            end
        end
    end

    -- Update footer
    if ns.ProfFrame then
        ns.ProfFrame:UpdateFooter()
    end
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
    if not selectedRecipeID and KazCraftDB and KazCraftDB.lastRecipeID then
        selectedRecipeID = KazCraftDB.lastRecipeID
    end
    leftPanel:Show()
    rightPanel:Show()
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
