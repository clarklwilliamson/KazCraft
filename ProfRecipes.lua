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

--------------------------------------------------------------------
-- Category tree → flat display list
--------------------------------------------------------------------
local function BuildDisplayList()
    wipe(displayList)

    local recipeIDs = C_TradeSkillUI.GetFilteredRecipeIDs()
    if not recipeIDs or #recipeIDs == 0 then return end

    -- Get current child profession ID to filter recipes to this expansion only
    local childProfInfo = C_TradeSkillUI.GetChildProfessionInfo()
    local childProfID = childProfInfo and childProfInfo.professionID

    -- Build category hierarchy
    -- categoryID → { name, parentCategoryID, recipes = {}, subcats = {} }
    local categories = {}
    local rootCats = {}

    for _, recipeID in ipairs(recipeIDs) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        -- Filter to current expansion skill line (same as Blizzard)
        if info and (not childProfID or C_TradeSkillUI.IsRecipeInSkillLine(recipeID, childProfID)) then
            local catID = info.categoryID
            -- Ensure category chain exists
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
                        hasRecipes = false,
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
                            hasRecipes = false,
                        }
                    end
                    -- Register as subcat (avoid dupes)
                    local found = false
                    for _, sc in ipairs(categories[parentID].subcats) do
                        if sc == curCat then found = true; break end
                    end
                    if not found then
                        table.insert(categories[parentID].subcats, curCat)
                    end
                else
                    -- Root category
                    rootCats[curCat] = true
                end
                curCat = parentID
            end

            -- Add recipe to its direct category
            if categories[catID] then
                table.insert(categories[catID].recipes, { recipeID = recipeID, info = info })
                categories[catID].hasRecipes = true
            end
        end
    end

    -- Get collapse state
    local collapses = KazCraftDB.profCollapses or {}

    -- Recursive flatten
    local function Flatten(catID, depth)
        local cat = categories[catID]
        if not cat then return end

        local isCollapsed = collapses[catID] or false

        table.insert(displayList, {
            type = "category",
            catID = catID,
            name = cat.name,
            depth = depth,
            collapsed = isCollapsed,
        })

        if not isCollapsed then
            -- Subcategories first
            -- Sort by name
            table.sort(cat.subcats, function(a, b)
                local oa = categories[a] and categories[a].uiOrder or 0
                local ob = categories[b] and categories[b].uiOrder or 0
                return oa < ob
            end)
            for _, subID in ipairs(cat.subcats) do
                Flatten(subID, depth + 1)
            end

            -- Then recipes
            for _, r in ipairs(cat.recipes) do
                table.insert(displayList, {
                    type = "recipe",
                    recipeID = r.recipeID,
                    info = r.info,
                    depth = depth + 1,
                })
            end
        end
    end

    -- Strip root wrapper categories (expansion-level wrappers with no direct
    -- recipes). Promote their children as new roots. Blizzard does the same.
    local effectiveRoots = {}
    for catID in pairs(rootCats) do
        local cat = categories[catID]
        if cat and #cat.recipes == 0 and #cat.subcats > 0 then
            -- Wrapper — promote subcategories
            for _, subID in ipairs(cat.subcats) do
                effectiveRoots[subID] = true
            end
        else
            effectiveRoots[catID] = true
        end
    end

    -- Sort root categories by name
    local sortedRoots = {}
    for catID in pairs(effectiveRoots) do
        table.insert(sortedRoots, catID)
    end
    table.sort(sortedRoots, function(a, b)
        local oa = categories[a] and categories[a].uiOrder or 0
        local ob = categories[b] and categories[b].uiOrder or 0
        return oa < ob
    end)

    for _, catID in ipairs(sortedRoots) do
        Flatten(catID, 0)
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
    row.arrow:SetFont(ns.FONT, 10, "")
    row.arrow:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Icon for recipes
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)

    -- Name
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    -- Count (craftable)
    row.countText = row:CreateFontString(nil, "OVERLAY")
    row.countText:SetFont(ns.FONT, 10, "")
    row.countText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.countText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Favorite star
    row.favText = row:CreateFontString(nil, "OVERLAY")
    row.favText:SetFont(ns.FONT, 10, "")
    row.favText:SetPoint("RIGHT", row.countText, "LEFT", -4, 0)
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
        row.nameText:SetFont(ns.FONT, 11, "")

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

        row.icon:Show()
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
        row.icon:SetTexture(info and info.icon or 134400)

        row.nameText:Show()
        row.nameText:ClearAllPoints()
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.nameText:SetPoint("RIGHT", row.countText, "LEFT", -24, 0)
        row.nameText:SetText(info and info.name or ("Recipe " .. entry.recipeID))
        row.nameText:SetFont(ns.FONT, 11, "")
        local color = GetDifficultyColor(info)
        row.nameText:SetTextColor(color[1], color[2], color[3])

        -- Craftable count
        local craftable = info and info.numAvailable or 0
        if craftable > 0 then
            row.countText:SetText("[" .. craftable .. "]")
            row.countText:SetTextColor(unpack(ns.COLORS.greenText))
        else
            row.countText:SetText("")
        end

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
            selectedRecipeID = entry.recipeID
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
    searchBox:SetFont(ns.FONT, 11, "")
    searchBox:SetTextColor(unpack(ns.COLORS.brightText))
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(40)

    -- Placeholder text
    searchBox.placeholder = searchBox:CreateFontString(nil, "OVERLAY")
    searchBox.placeholder:SetFont(ns.FONT, 11, "")
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
    recipeContent:EnableMouseWheel(true)
    recipeContent:SetScript("OnMouseWheel", OnRecipeScroll)

    -- Pre-allocate recipe rows
    for i = 1, MAX_VISIBLE_ROWS do
        recipeRows[i] = CreateRecipeRow(recipeContent, i)
    end
end

--------------------------------------------------------------------
-- Filter dropdown menu
--------------------------------------------------------------------
local filterMenu
function ProfRecipes:ToggleFilterMenu(anchorBtn)
    if filterMenu and filterMenu:IsShown() then
        filterMenu:Hide()
        return
    end

    if not filterMenu then
        filterMenu = CreateFrame("Frame", nil, leftPanel, "BackdropTemplate")
        filterMenu:SetSize(180, 100)
        filterMenu:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        filterMenu:SetBackdropColor(20/255, 20/255, 20/255, 0.98)
        filterMenu:SetBackdropBorderColor(unpack(ns.COLORS.accent))
        filterMenu:SetFrameStrata("DIALOG")
        filterMenu:EnableMouse(true)

        local function CreateFilterCheck(parent, text, y, getter, setter)
            local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
            check:SetSize(22, 22)
            check:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, y)
            check:SetChecked(getter())
            check:SetScript("OnClick", function(self)
                setter(self:GetChecked())
            end)

            local label = parent:CreateFontString(nil, "OVERLAY")
            label:SetFont(ns.FONT, 11, "")
            label:SetPoint("LEFT", check, "RIGHT", 2, 0)
            label:SetText(text)
            label:SetTextColor(unpack(ns.COLORS.brightText))

            return check
        end

        CreateFilterCheck(filterMenu, "Have Materials", -6,
            function() return C_TradeSkillUI.GetOnlyShowMakeableRecipes() end,
            function(v) C_TradeSkillUI.SetOnlyShowMakeableRecipes(v) end)

        CreateFilterCheck(filterMenu, "Skill Up", -30,
            function() return C_TradeSkillUI.GetOnlyShowSkillUpRecipes() end,
            function(v) C_TradeSkillUI.SetOnlyShowSkillUpRecipes(v) end)

        CreateFilterCheck(filterMenu, "First Craft", -54,
            function() return C_TradeSkillUI.GetOnlyShowFirstCraftRecipes() end,
            function(v) C_TradeSkillUI.SetOnlyShowFirstCraftRecipes(v) end)
    end

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

    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    row.countText = row:CreateFontString(nil, "OVERLAY")
    row.countText:SetFont(ns.FONT, 11, "")
    row.countText:SetPoint("RIGHT", row, "RIGHT", -24, 0)
    row.countText:SetJustifyH("RIGHT")

    row.checkText = row:CreateFontString(nil, "OVERLAY")
    row.checkText:SetFont(ns.FONT, 11, "")
    row.checkText:SetPoint("RIGHT", row, "RIGHT", -4, 0)

    return row
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
    row.nameText:SetFont(ns.FONT, 10, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -72, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    row.qtyText = row:CreateFontString(nil, "OVERLAY")
    row.qtyText:SetFont(ns.FONT, 10, "")
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
        btn.t:SetFont(ns.FONT, 11, "")
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
    rightPanel = CreateFrame("Frame", nil, parent)
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 0, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    -- Scrollable detail content
    local scroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -22, 4)

    detailFrame = CreateFrame("Frame", nil, scroll)
    detailFrame:SetWidth(scroll:GetWidth() or 500)
    detailFrame:SetHeight(800)
    scroll:SetScrollChild(detailFrame)

    -- Recipe name
    detail.nameText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.nameText:SetFont(ns.FONT, 15, "")
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
    detail.subtypeText:SetFont(ns.FONT, 11, "")
    detail.subtypeText:SetPoint("LEFT", detail.icon, "RIGHT", 8, 0)
    detail.subtypeText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- ── Reagents ──
    local reagentY = -80
    detail.reagentHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.reagentHeader:SetFont(ns.FONT, 10, "")
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

    -- ── Details ──
    detail.detailHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.detailHeader:SetFont(ns.FONT, 10, "")
    detail.detailHeader:SetText("DETAILS")
    detail.detailHeader:SetTextColor(unpack(ns.COLORS.headerText))
    -- anchored dynamically after reagents

    detail.qualityText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.qualityText:SetFont(ns.FONT, 11, "")
    detail.qualityText:SetTextColor(unpack(ns.COLORS.brightText))

    detail.skillText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.skillText:SetFont(ns.FONT, 11, "")
    detail.skillText:SetTextColor(unpack(ns.COLORS.mutedText))

    detail.concText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.concText:SetFont(ns.FONT, 11, "")
    detail.concText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Craft controls
    detail.controlFrame = CreateFrame("Frame", nil, detailFrame)
    detail.controlFrame:SetHeight(60)
    detail.controlFrame:SetPoint("LEFT", detailFrame, "LEFT", 8, 0)
    detail.controlFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    -- anchored dynamically

    -- Best Quality checkbox
    detail.bestQualCheck = CreateFrame("CheckButton", nil, detail.controlFrame, "UICheckButtonTemplate")
    detail.bestQualCheck:SetSize(22, 22)
    detail.bestQualCheck:SetPoint("TOPLEFT", detail.controlFrame, "TOPLEFT", 0, 0)

    detail.bestQualLabel = detail.controlFrame:CreateFontString(nil, "OVERLAY")
    detail.bestQualLabel:SetFont(ns.FONT, 11, "")
    detail.bestQualLabel:SetPoint("LEFT", detail.bestQualCheck, "RIGHT", 2, 0)
    detail.bestQualLabel:SetText("Best Quality")
    detail.bestQualLabel:SetTextColor(unpack(ns.COLORS.brightText))

    -- Concentration checkbox
    detail.concCheck = CreateFrame("CheckButton", nil, detail.controlFrame, "UICheckButtonTemplate")
    detail.concCheck:SetSize(22, 22)
    detail.concCheck:SetPoint("LEFT", detail.bestQualLabel, "RIGHT", 16, 0)

    detail.concLabel = detail.controlFrame:CreateFontString(nil, "OVERLAY")
    detail.concLabel:SetFont(ns.FONT, 11, "")
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
    detail.qtyBox:SetFont(ns.FONT, 11, "")
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
        ns.lastCraftedRecipeID = nil -- don't decrement queue for manual crafts
        C_TradeSkillUI.CraftRecipe(selectedRecipeID, qty)
    end)

    -- Craft All button
    detail.craftAllBtn = ns.CreateButton(detail.controlFrame, "Craft All", 70, 24)
    detail.craftAllBtn:SetPoint("LEFT", detail.craftBtn, "RIGHT", 4, 0)
    detail.craftAllBtn:SetScript("OnClick", function()
        if not selectedRecipeID or isCrafting then return end
        local info = C_TradeSkillUI.GetRecipeInfo(selectedRecipeID)
        local count = info and info.numAvailable or 0
        if count > 0 then
            ns.lastCraftedRecipeID = nil
            C_TradeSkillUI.CraftRecipe(selectedRecipeID, count)
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
        ProfRecipes:RefreshQueue()
        if ns.ProfFrame then ns.ProfFrame:UpdateFooter() end
    end)

    -- ── Queue ──
    detail.queueHeader = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.queueHeader:SetFont(ns.FONT, 10, "")
    detail.queueHeader:SetTextColor(unpack(ns.COLORS.headerText))
    -- anchored dynamically

    detail.queueFrame = CreateFrame("Frame", nil, detailFrame)
    detail.queueFrame:SetPoint("LEFT", detailFrame, "LEFT", 8, 0)
    detail.queueFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
    detail.queueFrame:SetHeight(MAX_QUEUE_ROWS * QUEUE_ROW_HEIGHT)
    -- anchored dynamically

    for i = 1, MAX_QUEUE_ROWS do
        queueRows[i] = CreateQueueRowSmall(detail.queueFrame, i)
    end

    -- No-selection message
    detail.emptyText = detailFrame:CreateFontString(nil, "OVERLAY")
    detail.emptyText:SetFont(ns.FONT, 13, "")
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
function ProfRecipes:RefreshRecipeList()
    if not initialized then return end
    BuildDisplayList()
    scrollOffset = 0
    self:RefreshRows()
end

--------------------------------------------------------------------
-- Refresh detail panel
--------------------------------------------------------------------
function ProfRecipes:RefreshDetail()
    if not initialized or not detailFrame then return end

    if not selectedRecipeID then
        detail.emptyText:Show()
        detail.nameText:SetText("")
        detail.icon:SetTexture(nil)
        detail.subtypeText:SetText("")
        detail.reagentHeader:Hide()
        detail.reagentFrame:Hide()
        detail.detailHeader:Hide()
        detail.qualityText:Hide()
        detail.skillText:Hide()
        detail.concText:Hide()
        detail.controlFrame:Hide()
        detail.queueHeader:Hide()
        detail.queueFrame:Hide()
        detail.favBtn:Hide()
        return
    end

    detail.emptyText:Hide()
    detail.favBtn:Show()

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

    -- Reagents
    detail.reagentHeader:Show()
    detail.reagentFrame:Show()

    local schematic = C_TradeSkillUI.GetRecipeSchematic(selectedRecipeID, false)
    local reagentCount = 0

    if schematic and schematic.reagentSlotSchematics then
        for _, slot in ipairs(schematic.reagentSlotSchematics) do
            if slot.reagentType == Enum.CraftingReagentType.Basic then
                reagentCount = reagentCount + 1
                local row = reagentRows[reagentCount]
                if not row then
                    row = CreateReagentRow(detail.reagentFrame, reagentCount)
                    reagentRows[reagentCount] = row
                end

                local firstReagent = slot.reagents and slot.reagents[1]
                local itemID = firstReagent and firstReagent.itemID
                local needed = slot.quantityRequired or 0

                -- Item info
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

                -- Have count
                local have = itemID and C_Item.GetItemCount(itemID, true, false, true, true) or 0
                row.countText:SetText(have .. "/" .. needed)

                if have >= needed then
                    row.countText:SetTextColor(unpack(ns.COLORS.greenText))
                    row.checkText:SetText("|cff4dff4dOK|r") -- ✓
                else
                    row.countText:SetTextColor(unpack(ns.COLORS.redText))
                    row.checkText:SetText("")
                end

                row:Show()
            end
        end
    end

    -- Hide unused reagent rows
    for i = reagentCount + 1, #reagentRows do
        reagentRows[i]:Hide()
    end

    -- Adjust reagent frame height
    detail.reagentFrame:SetHeight(math.max(1, reagentCount * REAGENT_ROW_HEIGHT))

    -- Details section — anchor below reagents
    local detailY = -80 - 18 - (reagentCount * REAGENT_ROW_HEIGHT) - 10
    detail.detailHeader:ClearAllPoints()
    detail.detailHeader:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 8, detailY)
    detail.detailHeader:Show()

    -- Quality + skill info from GetCraftingOperationInfo
    local applyConc = detail.concCheck:GetChecked()
    local opInfo = C_TradeSkillUI.GetCraftingOperationInfo(selectedRecipeID, {}, nil, applyConc)

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

        -- Concentration cost
        if opInfo.concentrationCost and opInfo.concentrationCost > 0 then
            detail.concText:SetText("Concentration cost: " .. opInfo.concentrationCost)
        else
            detail.concText:SetText("")
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
    end

    -- Craft controls
    detail.controlFrame:ClearAllPoints()
    local controlAnchor = detail.concText:IsShown() and detail.concText or
                          (detail.skillText:IsShown() and detail.skillText or detail.qualityText)
    detail.controlFrame:SetPoint("TOPLEFT", controlAnchor, "BOTTOMLEFT", 0, -12)
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

    -- Queue section
    self:RefreshQueue()
end

--------------------------------------------------------------------
-- Refresh queue section in detail panel
--------------------------------------------------------------------
function ProfRecipes:RefreshQueue()
    if not initialized or not detail.queueFrame then return end

    local queue = ns.Data:GetCharacterQueue()
    local count = #queue

    -- Anchor queue header below controls
    detail.queueHeader:ClearAllPoints()
    detail.queueHeader:SetPoint("TOPLEFT", detail.controlFrame, "BOTTOMLEFT", 0, -12)
    detail.queueHeader:SetText("── Queue (" .. count .. ") ──")
    detail.queueHeader:Show()

    detail.queueFrame:ClearAllPoints()
    detail.queueFrame:SetPoint("TOPLEFT", detail.queueHeader, "BOTTOMLEFT", 0, -4)
    detail.queueFrame:SetPoint("RIGHT", detailFrame, "RIGHT", -8, 0)
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
    leftPanel:Show()
    rightPanel:Show()
    self:RefreshRecipeList()
    self:RefreshDetail()
end

function ProfRecipes:Hide()
    if not initialized then return end
    leftPanel:Hide()
    rightPanel:Hide()
    if filterMenu then filterMenu:Hide() end
end

function ProfRecipes:IsShown()
    return initialized and leftPanel and leftPanel:IsShown()
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
