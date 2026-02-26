local addonName, ns = ...

local AHBrowse = {}
ns.AHBrowse = AHBrowse

local ROW_HEIGHT = 26
local MAX_ROWS = 15
local SIDEBAR_WIDTH = 170
local CAT_HEIGHT = 20

-- State
local container
local searchBox
local sidebarScroll, sidebarContent
local catNodePool = {}
local resultArea, resultContent
local resultRows = {}
local statusText
local browseResults = {}
local selectedResult = nil
local selectedItemKey = nil
local selectedRowIndex = nil

-- Category tree
local categoryTree = {}
local selectedCatNode = nil
local visibleNodes = {}

-- Sort state
local currentSortOrder = Enum.AuctionHouseSortOrder.Price
local currentSortReverse = false
local colHeaderBtns = {}
local lastSearchText = nil
local lastSearchCatNode = nil

-- Detail overlay
local detailOverlay
local filterPanel
local filterBtn

-- Filter state defaults
local FILTER_DEFAULTS = {
    minLevel = nil,
    maxLevel = nil,
    uncollectedOnly = false,
    usableOnly = false,
    currentExpansionOnly = false,
    upgradesOnly = false,
    qualities = {
        [Enum.AuctionHouseFilter.PoorQuality] = true,
        [Enum.AuctionHouseFilter.CommonQuality] = true,
        [Enum.AuctionHouseFilter.UncommonQuality] = true,
        [Enum.AuctionHouseFilter.RareQuality] = true,
        [Enum.AuctionHouseFilter.EpicQuality] = true,
        [Enum.AuctionHouseFilter.LegendaryQuality] = true,
        [Enum.AuctionHouseFilter.ArtifactQuality] = true,
    },
    -- Client-side crafting quality tier filter (0 = no tier / non-crafted)
    craftTiers = { [0] = true, [1] = true, [2] = true, [3] = true },
}

local filterState = {}
local UpdateFilterBtnGlow  -- forward declare

local function SaveFilterState()
    -- Save to DB (convert enum keys to numbers for serialization)
    local saved = {
        minLevel = filterState.minLevel,
        maxLevel = filterState.maxLevel,
        uncollectedOnly = filterState.uncollectedOnly,
        usableOnly = filterState.usableOnly,
        currentExpansionOnly = filterState.currentExpansionOnly,
        upgradesOnly = filterState.upgradesOnly,
        qualities = {},
        craftTiers = {},
    }
    for k, v in pairs(filterState.qualities) do
        saved.qualities[k] = v
    end
    for k, v in pairs(filterState.craftTiers) do
        saved.craftTiers[k] = v
    end
    KazCraftDB.ahFilters = saved
    UpdateFilterBtnGlow()
end

local function LoadFilterState()
    local saved = KazCraftDB and KazCraftDB.ahFilters
    if saved then
        filterState.minLevel = saved.minLevel
        filterState.maxLevel = saved.maxLevel
        filterState.uncollectedOnly = saved.uncollectedOnly or false
        filterState.usableOnly = saved.usableOnly or false
        filterState.currentExpansionOnly = saved.currentExpansionOnly or false
        filterState.upgradesOnly = saved.upgradesOnly or false
        filterState.qualities = {}
        if saved.qualities then
            for k, v in pairs(saved.qualities) do
                filterState.qualities[k] = v
            end
        else
            for k, v in pairs(FILTER_DEFAULTS.qualities) do
                filterState.qualities[k] = v
            end
        end
        filterState.craftTiers = {}
        if saved.craftTiers then
            for k, v in pairs(saved.craftTiers) do
                filterState.craftTiers[k] = v
            end
        else
            for k, v in pairs(FILTER_DEFAULTS.craftTiers) do
                filterState.craftTiers[k] = v
            end
        end
    else
        -- First time: use defaults
        filterState.minLevel = FILTER_DEFAULTS.minLevel
        filterState.maxLevel = FILTER_DEFAULTS.maxLevel
        filterState.uncollectedOnly = FILTER_DEFAULTS.uncollectedOnly
        filterState.usableOnly = FILTER_DEFAULTS.usableOnly
        filterState.currentExpansionOnly = FILTER_DEFAULTS.currentExpansionOnly
        filterState.upgradesOnly = FILTER_DEFAULTS.upgradesOnly
        filterState.qualities = {}
        for k, v in pairs(FILTER_DEFAULTS.qualities) do
            filterState.qualities[k] = v
        end
        filterState.craftTiers = {}
        for k, v in pairs(FILTER_DEFAULTS.craftTiers) do
            filterState.craftTiers[k] = v
        end
    end
end

-- Check if any filter deviates from defaults; glow the Filter button gold
UpdateFilterBtnGlow = function()
    if not filterBtn then return end
    local active = false
    if filterState.uncollectedOnly or filterState.usableOnly
       or filterState.currentExpansionOnly or filterState.upgradesOnly then
        active = true
    end
    if not active and filterState.minLevel then active = true end
    if not active and filterState.maxLevel then active = true end
    if not active then
        for k, v in pairs(FILTER_DEFAULTS.qualities) do
            if filterState.qualities[k] ~= v then active = true; break end
        end
    end
    if not active then
        for k, v in pairs(FILTER_DEFAULTS.craftTiers) do
            if filterState.craftTiers[k] ~= v then active = true; break end
        end
    end
    filterBtn._active = active
    if active then
        filterBtn.label:SetTextColor(unpack(ns.COLORS.tabActive))
        filterBtn:SetBackdropBorderColor(unpack(ns.COLORS.tabActive))
    else
        filterBtn.label:SetTextColor(unpack(ns.COLORS.btnDefault))
        filterBtn:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
    end
end

--------------------------------------------------------------------
-- Category tree builder (matches Blizzard's AuctionData.lua)
--------------------------------------------------------------------
local function BuildCategoryTree()
    local tree = {}

    -- Filter constructor
    local function F(classID, subClassID, invType)
        local f = { classID = classID }
        if subClassID ~= nil then f.subClassID = subClassID end
        if invType ~= nil then f.inventoryType = invType end
        return f
    end

    -- Localized subclass name
    local function SubName(classID, subClassID)
        return C_Item.GetItemSubClassInfo(classID, subClassID) or ("Subclass " .. subClassID)
    end

    -- Localized inventory slot name
    local function SlotName(invType)
        return C_Item.GetItemInventorySlotInfo(invType) or ("Slot " .. invType)
    end

    -- Auto-generate children from API (for simple categories)
    local function AutoChildren(classID)
        local children = {}
        local subs = C_AuctionHouse.GetAuctionItemSubClasses(classID) or {}
        for _, subID in ipairs(subs) do
            table.insert(children, {
                label = SubName(classID, subID),
                filters = { F(classID, subID) },
            })
        end
        return children
    end

    -- Armor slot children (Head, Shoulder, Chest, etc.)
    local ARMOR_SLOTS = {
        Enum.InventoryType.IndexHeadType,
        Enum.InventoryType.IndexShoulderType,
        Enum.InventoryType.IndexChestType,
        Enum.InventoryType.IndexWaistType,
        Enum.InventoryType.IndexLegsType,
        Enum.InventoryType.IndexFeetType,
        Enum.InventoryType.IndexWristType,
        Enum.InventoryType.IndexHandType,
    }

    local function ArmorSlotChildren(subClassID)
        local children = {}
        for _, invType in ipairs(ARMOR_SLOTS) do
            table.insert(children, {
                label = SlotName(invType),
                filters = { F(Enum.ItemClass.Armor, subClassID, invType) },
            })
        end
        return children
    end

    ----------------------------------------------------------------
    -- WEAPONS (3 levels: Weapons > One-Handed > One-Handed Axes)
    ----------------------------------------------------------------
    local W = Enum.ItemClass.Weapon
    local WS = Enum.ItemWeaponSubclass
    table.insert(tree, {
        label = AUCTION_CATEGORY_WEAPONS or "Weapons",
        filters = { F(W) },
        children = {
            {
                label = AUCTION_SUBCATEGORY_ONE_HANDED or "One-Handed",
                filters = {
                    F(W, WS.Axe1H), F(W, WS.Mace1H), F(W, WS.Sword1H),
                    F(W, WS.Warglaive), F(W, WS.Dagger), F(W, WS.Unarmed), F(W, WS.Wand),
                },
                children = {
                    { label = SubName(W, WS.Axe1H),    filters = { F(W, WS.Axe1H) } },
                    { label = SubName(W, WS.Mace1H),   filters = { F(W, WS.Mace1H) } },
                    { label = SubName(W, WS.Sword1H),  filters = { F(W, WS.Sword1H) } },
                    { label = SubName(W, WS.Warglaive), filters = { F(W, WS.Warglaive) } },
                    { label = SubName(W, WS.Dagger),    filters = { F(W, WS.Dagger) } },
                    { label = SubName(W, WS.Unarmed),   filters = { F(W, WS.Unarmed) } },
                    { label = SubName(W, WS.Wand),      filters = { F(W, WS.Wand) } },
                },
            },
            {
                label = AUCTION_SUBCATEGORY_TWO_HANDED or "Two-Handed",
                filters = {
                    F(W, WS.Axe2H), F(W, WS.Mace2H), F(W, WS.Sword2H),
                    F(W, WS.Polearm), F(W, WS.Staff),
                },
                children = {
                    { label = SubName(W, WS.Axe2H),    filters = { F(W, WS.Axe2H) } },
                    { label = SubName(W, WS.Mace2H),   filters = { F(W, WS.Mace2H) } },
                    { label = SubName(W, WS.Sword2H),  filters = { F(W, WS.Sword2H) } },
                    { label = SubName(W, WS.Polearm),   filters = { F(W, WS.Polearm) } },
                    { label = SubName(W, WS.Staff),     filters = { F(W, WS.Staff) } },
                },
            },
            {
                label = AUCTION_SUBCATEGORY_RANGED or "Ranged",
                filters = {
                    F(W, WS.Bows), F(W, WS.Crossbow), F(W, WS.Guns), F(W, WS.Thrown),
                },
                children = {
                    { label = SubName(W, WS.Bows),     filters = { F(W, WS.Bows) } },
                    { label = SubName(W, WS.Crossbow), filters = { F(W, WS.Crossbow) } },
                    { label = SubName(W, WS.Guns),     filters = { F(W, WS.Guns) } },
                    { label = SubName(W, WS.Thrown),    filters = { F(W, WS.Thrown) } },
                },
            },
            {
                label = AUCTION_SUBCATEGORY_MISCELLANEOUS or "Miscellaneous",
                filters = { F(W, WS.Fishingpole), F(W, WS.Generic) },
                children = {
                    { label = SubName(W, WS.Fishingpole), filters = { F(W, WS.Fishingpole) } },
                },
            },
        },
    })

    ----------------------------------------------------------------
    -- ARMOR (3 levels: Armor > Plate > Head/Shoulder/etc.)
    ----------------------------------------------------------------
    local A = Enum.ItemClass.Armor
    local AS = Enum.ItemArmorSubclass
    table.insert(tree, {
        label = AUCTION_CATEGORY_ARMOR or "Armor",
        filters = { F(A) },
        children = {
            { label = SubName(A, AS.Plate),   filters = { F(A, AS.Plate) },   children = ArmorSlotChildren(AS.Plate) },
            { label = SubName(A, AS.Mail),    filters = { F(A, AS.Mail) },    children = ArmorSlotChildren(AS.Mail) },
            { label = SubName(A, AS.Leather), filters = { F(A, AS.Leather) }, children = ArmorSlotChildren(AS.Leather) },
            { label = SubName(A, AS.Cloth),   filters = { F(A, AS.Cloth) },   children = ArmorSlotChildren(AS.Cloth) },
            {
                label = SubName(A, AS.Generic) ~= "" and SubName(A, AS.Generic) or "Miscellaneous",
                filters = { F(A, AS.Generic) },
                children = {
                    { label = SlotName(Enum.InventoryType.IndexNeckType),     filters = { F(A, AS.Generic, Enum.InventoryType.IndexNeckType) } },
                    { label = AUCTION_SUBCATEGORY_CLOAK or "Cloak",           filters = { F(A, AS.Cloth, Enum.InventoryType.IndexCloakType) } },
                    { label = SlotName(Enum.InventoryType.IndexFingerType),   filters = { F(A, AS.Generic, Enum.InventoryType.IndexFingerType) } },
                    { label = SlotName(Enum.InventoryType.IndexTrinketType),  filters = { F(A, AS.Generic, Enum.InventoryType.IndexTrinketType) } },
                    { label = SlotName(Enum.InventoryType.IndexHoldableType), filters = { F(A, AS.Generic, Enum.InventoryType.IndexHoldableType) } },
                    { label = SubName(A, AS.Shield),                          filters = { F(A, AS.Shield) } },
                    { label = SlotName(Enum.InventoryType.IndexBodyType),     filters = { F(A, AS.Generic, Enum.InventoryType.IndexBodyType) } },
                },
            },
            { label = SubName(A, AS.Cosmetic), filters = { F(A, AS.Cosmetic) } },
        },
    })

    ----------------------------------------------------------------
    -- SIMPLE AUTO-GEN CATEGORIES (2 levels)
    ----------------------------------------------------------------
    local simpleCategories = {
        { label = AUCTION_CATEGORY_CONTAINERS or "Containers",                  classID = Enum.ItemClass.Container },
        { label = AUCTION_CATEGORY_GEMS or "Gems",                              classID = Enum.ItemClass.Gem },
        { label = AUCTION_CATEGORY_ITEM_ENHANCEMENT or "Item Enhancements",    classID = Enum.ItemClass.ItemEnhancement },
        { label = AUCTION_CATEGORY_CONSUMABLES or "Consumables",                classID = Enum.ItemClass.Consumable },
        { label = AUCTION_CATEGORY_GLYPHS or "Glyphs",                          classID = Enum.ItemClass.Glyph },
        { label = AUCTION_CATEGORY_TRADE_GOODS or "Reagents",                   classID = Enum.ItemClass.Tradegoods },
        { label = AUCTION_CATEGORY_RECIPES or "Recipes",                         classID = Enum.ItemClass.Recipe },
    }

    for _, cat in ipairs(simpleCategories) do
        table.insert(tree, {
            label = cat.label,
            filters = { F(cat.classID) },
            children = AutoChildren(cat.classID),
        })
    end

    ----------------------------------------------------------------
    -- PROFESSION EQUIPMENT (3 levels: ProfEquip > Alchemy > Tools/Accessories)
    ----------------------------------------------------------------
    do
        local PE = Enum.ItemClass.Profession
        local profChildren = {}
        local subs = C_AuctionHouse.GetAuctionItemSubClasses(PE) or {}
        for _, subID in ipairs(subs) do
            local toolLabel = AUCTION_SUBCATEGORY_PROFESSION_TOOLS or "Tools"
            local accLabel = AUCTION_SUBCATEGORY_PROFESSION_ACCESSORIES or "Accessories"
            table.insert(profChildren, {
                label = SubName(PE, subID),
                filters = { F(PE, subID) },
                children = {
                    { label = toolLabel, filters = { F(PE, subID, Enum.InventoryType.IndexProfessionToolType) } },
                    { label = accLabel,  filters = { F(PE, subID, Enum.InventoryType.IndexProfessionGearType) } },
                },
            })
        end
        table.insert(tree, {
            label = AUCTION_CATEGORY_PROFESSION_EQUIPMENT or "Profession Equipment",
            filters = { F(PE) },
            children = profChildren,
        })
    end

    ----------------------------------------------------------------
    -- HOUSING
    ----------------------------------------------------------------
    if Enum.ItemClass.Housing then
        local H = Enum.ItemClass.Housing
        local housingChildren = AutoChildren(H)
        table.insert(tree, {
            label = AUCTION_CATEGORY_HOUSING or "Housing",
            filters = { F(H) },
            children = housingChildren,
        })
    end

    ----------------------------------------------------------------
    -- BATTLE PETS
    ----------------------------------------------------------------
    do
        local BP = Enum.ItemClass.Battlepet
        local bpChildren = AutoChildren(BP)
        if Enum.ItemMiscellaneousSubclass and Enum.ItemMiscellaneousSubclass.CompanionPet then
            table.insert(bpChildren, {
                label = SubName(Enum.ItemClass.Miscellaneous, Enum.ItemMiscellaneousSubclass.CompanionPet),
                filters = { F(Enum.ItemClass.Miscellaneous, Enum.ItemMiscellaneousSubclass.CompanionPet) },
            })
        end
        table.insert(tree, {
            label = AUCTION_CATEGORY_BATTLE_PETS or "Battle Pets",
            filters = { F(BP) },
            children = bpChildren,
        })
    end

    ----------------------------------------------------------------
    -- QUEST ITEMS (flat)
    ----------------------------------------------------------------
    table.insert(tree, {
        label = AUCTION_CATEGORY_QUEST_ITEMS or "Quest Items",
        filters = { F(Enum.ItemClass.Questitem) },
    })

    ----------------------------------------------------------------
    -- MISCELLANEOUS
    ----------------------------------------------------------------
    do
        local M = Enum.ItemClass.Miscellaneous
        local MS = Enum.ItemMiscellaneousSubclass
        local miscChildren = {}
        if MS then
            if MS.Junk then table.insert(miscChildren, { label = SubName(M, MS.Junk), filters = { F(M, MS.Junk) } }) end
            if MS.Reagent then table.insert(miscChildren, { label = SubName(M, MS.Reagent), filters = { F(M, MS.Reagent) } }) end
            if MS.Holiday then table.insert(miscChildren, { label = SubName(M, MS.Holiday), filters = { F(M, MS.Holiday) } }) end
            if MS.Other then table.insert(miscChildren, { label = SubName(M, MS.Other), filters = { F(M, MS.Other) } }) end
            if MS.Mount then table.insert(miscChildren, { label = SubName(M, MS.Mount), filters = { F(M, MS.Mount) } }) end
            if MS.MountEquipment then table.insert(miscChildren, { label = SubName(M, MS.MountEquipment), filters = { F(M, MS.MountEquipment) } }) end
        end
        table.insert(tree, {
            label = AUCTION_CATEGORY_MISCELLANEOUS or "Miscellaneous",
            filters = { F(M) },
            children = #miscChildren > 0 and miscChildren or nil,
        })
    end

    ----------------------------------------------------------------
    -- WOW TOKEN (flat)
    ----------------------------------------------------------------
    table.insert(tree, {
        label = TOKEN_FILTER_LABEL or "WoW Token",
        filters = { F(18) },
    })

    return tree
end

--------------------------------------------------------------------
-- Flatten tree (respecting expanded state)
--------------------------------------------------------------------
local function FlattenTree(nodes, depth, result)
    for _, node in ipairs(nodes) do
        node._depth = depth
        table.insert(result, node)
        if node.children and #node.children > 0 and node._expanded then
            FlattenTree(node.children, depth + 1, result)
        end
    end
end

local function RebuildVisibleNodes()
    wipe(visibleNodes)
    FlattenTree(categoryTree, 0, visibleNodes)
end

--------------------------------------------------------------------
-- Sidebar node factory
--------------------------------------------------------------------
local function GetOrCreateNode(parent, index)
    if catNodePool[index] then return catNodePool[index] end

    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(CAT_HEIGHT)

    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(1, 1, 1, 0)

    btn.label = btn:CreateFontString(nil, "OVERLAY")
    btn.label:SetFont(ns.FONT, 10, "")
    btn.label:SetJustifyH("LEFT")
    btn.label:SetWordWrap(false)
    btn.label:SetTextColor(unpack(ns.COLORS.tabInactive))

    btn:SetScript("OnEnter", function(self)
        if not self._isActive then
            self.label:SetTextColor(unpack(ns.COLORS.tabHover))
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if not self._isActive then
            self.label:SetTextColor(unpack(ns.COLORS.tabInactive))
        end
    end)

    catNodePool[index] = btn
    return btn
end

--------------------------------------------------------------------
-- Rebuild sidebar from visible nodes
--------------------------------------------------------------------
local function RebuildSidebar()
    if not sidebarContent then return end

    RebuildVisibleNodes()

    -- Hide all existing nodes
    for _, btn in ipairs(catNodePool) do
        btn:Hide()
    end

    local yOff = -2

    for i, node in ipairs(visibleNodes) do
        local btn = GetOrCreateNode(sidebarContent, i)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", sidebarContent, "TOPLEFT", 0, yOff)
        btn:SetPoint("RIGHT", sidebarContent, "RIGHT", 0, 0)

        local indent = 6 + (node._depth * 12)
        btn.label:ClearAllPoints()
        btn.label:SetPoint("LEFT", indent, 0)
        btn.label:SetPoint("RIGHT", -4, 0)

        local hasChildren = node.children and #node.children > 0
        local prefix = ""
        if hasChildren then
            prefix = node._expanded and "- " or "+ "
        else
            prefix = "  "
        end
        btn.label:SetText(prefix .. node.label)

        local isActive = (selectedCatNode == node)
        btn._isActive = isActive
        if isActive then
            btn.label:SetTextColor(unpack(ns.COLORS.tabActive))
            btn.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        else
            btn.label:SetTextColor(unpack(ns.COLORS.tabInactive))
            btn.bg:SetColorTexture(1, 1, 1, 0)
        end

        local capturedNode = node
        btn:SetScript("OnClick", function()
            if hasChildren then
                capturedNode._expanded = not capturedNode._expanded
            end
            selectedCatNode = capturedNode
            RebuildSidebar()
        end)

        btn:Show()
        yOff = yOff - CAT_HEIGHT
    end

    sidebarContent:SetHeight(math.max(1, math.abs(yOff) + 2))
end

--------------------------------------------------------------------
-- Flat checkbox widget
--------------------------------------------------------------------
local function CreateFlatCheck(parent, text, initialChecked, textColor, onChange)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(18)

    -- Checkbox box
    local box = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    box:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    box:SetBackdropColor(20/255, 20/255, 20/255, 1)
    box:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    -- Check mark (small filled square)
    local checkMark = box:CreateTexture(nil, "OVERLAY")
    checkMark:SetSize(8, 8)
    checkMark:SetPoint("CENTER")
    checkMark:SetColorTexture(unpack(ns.COLORS.accent))

    -- Label
    local label = btn:CreateFontString(nil, "OVERLAY")
    label:SetFont(ns.FONT, 10, "")
    label:SetPoint("LEFT", box, "RIGHT", 4, 0)
    label:SetText(text)
    label:SetTextColor(unpack(textColor or ns.COLORS.brightText))

    btn._checked = initialChecked
    btn._checkMark = checkMark

    local function Update()
        if btn._checked then
            checkMark:Show()
        else
            checkMark:Hide()
        end
    end

    btn:SetScript("OnClick", function()
        btn._checked = not btn._checked
        Update()
        if onChange then onChange(btn._checked) end
    end)

    btn:SetScript("OnEnter", function()
        label:SetTextColor(unpack(ns.COLORS.tabHover))
    end)
    btn:SetScript("OnLeave", function()
        label:SetTextColor(unpack(textColor or ns.COLORS.brightText))
    end)

    Update()
    return btn
end

--------------------------------------------------------------------
-- Filter dropdown panel
--------------------------------------------------------------------
local function CreateFilterPanel(parent)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetSize(200, 360)
    panel:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(20/255, 20/255, 20/255, 0.98)
    panel:SetBackdropBorderColor(unpack(ns.COLORS.accent))
    panel:SetFrameStrata("DIALOG")
    panel:SetFrameLevel(200)
    panel:EnableMouse(true)
    panel:Hide()

    local yOff = -8

    -- Level Range header
    local lvlHeader = panel:CreateFontString(nil, "OVERLAY")
    lvlHeader:SetFont(ns.FONT, 10, "")
    lvlHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, yOff)
    lvlHeader:SetText("Level Range")
    lvlHeader:SetTextColor(unpack(ns.COLORS.headerText))
    yOff = yOff - 22

    -- Min/Max level boxes
    local function LevelBox(anchor, x)
        local box = CreateFrame("EditBox", nil, panel, "BackdropTemplate")
        box:SetSize(50, 20)
        box:SetPoint("TOPLEFT", panel, "TOPLEFT", x, yOff)
        box:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        box:SetBackdropColor(unpack(ns.COLORS.searchBg))
        box:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
        box:SetFont(ns.FONT, 10, "")
        box:SetTextColor(unpack(ns.COLORS.brightText))
        box:SetJustifyH("CENTER")
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(3)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEditFocusGained", function(self)
            self:SetBackdropBorderColor(unpack(ns.COLORS.searchFocus))
        end)
        box:SetScript("OnEditFocusLost", function(self)
            self:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
        end)
        return box
    end

    panel.minLevelBox = LevelBox("TOPLEFT", 10)

    local dash = panel:CreateFontString(nil, "OVERLAY")
    dash:SetFont(ns.FONT, 10, "")
    dash:SetPoint("LEFT", panel.minLevelBox, "RIGHT", 4, 0)
    dash:SetText("-")
    dash:SetTextColor(unpack(ns.COLORS.mutedText))

    panel.maxLevelBox = LevelBox("TOPLEFT", 72)
    yOff = yOff - 28

    -- Boolean filter checkboxes
    local function AddCheck(text, stateKey, textColor)
        local cb = CreateFlatCheck(panel, text, filterState[stateKey], textColor, function(checked)
            filterState[stateKey] = checked
            SaveFilterState()
        end)
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, yOff)
        cb:SetPoint("RIGHT", panel, "RIGHT", -6, 0)
        yOff = yOff - 20
        return cb
    end

    AddCheck("Uncollected Only", "uncollectedOnly")
    AddCheck("Usable Only", "usableOnly")
    AddCheck("Current Expansion Only", "currentExpansionOnly")

    yOff = yOff - 6

    -- Equipment header
    local equipHeader = panel:CreateFontString(nil, "OVERLAY")
    equipHeader:SetFont(ns.FONT, 10, "")
    equipHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, yOff)
    equipHeader:SetText("Equipment")
    equipHeader:SetTextColor(unpack(ns.COLORS.headerText))
    yOff = yOff - 18

    AddCheck("Upgrades Only", "upgradesOnly")

    yOff = yOff - 6

    -- Rarity header
    local rarityHeader = panel:CreateFontString(nil, "OVERLAY")
    rarityHeader:SetFont(ns.FONT, 10, "")
    rarityHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, yOff)
    rarityHeader:SetText("Rarity")
    rarityHeader:SetTextColor(unpack(ns.COLORS.headerText))
    yOff = yOff - 18

    -- Quality checkboxes with quality colors
    local qualityDefs = {
        { filter = Enum.AuctionHouseFilter.PoorQuality,      label = ITEM_QUALITY0_DESC or "Poor",      quality = 0 },
        { filter = Enum.AuctionHouseFilter.CommonQuality,    label = ITEM_QUALITY1_DESC or "Common",    quality = 1 },
        { filter = Enum.AuctionHouseFilter.UncommonQuality,  label = ITEM_QUALITY2_DESC or "Uncommon",  quality = 2 },
        { filter = Enum.AuctionHouseFilter.RareQuality,      label = ITEM_QUALITY3_DESC or "Rare",      quality = 3 },
        { filter = Enum.AuctionHouseFilter.EpicQuality,      label = ITEM_QUALITY4_DESC or "Epic",      quality = 4 },
        { filter = Enum.AuctionHouseFilter.LegendaryQuality, label = ITEM_QUALITY5_DESC or "Legendary", quality = 5 },
        { filter = Enum.AuctionHouseFilter.ArtifactQuality,  label = ITEM_QUALITY6_DESC or "Artifact",  quality = 6 },
    }

    for _, def in ipairs(qualityDefs) do
        local qc = ITEM_QUALITY_COLORS[def.quality]
        local color = qc and { qc.r, qc.g, qc.b } or ns.COLORS.brightText
        local cb = CreateFlatCheck(panel, def.label, filterState.qualities[def.filter], color, function(checked)
            filterState.qualities[def.filter] = checked
            SaveFilterState()
        end)
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, yOff)
        cb:SetPoint("RIGHT", panel, "RIGHT", -6, 0)
        yOff = yOff - 20
    end

    yOff = yOff - 6

    -- Crafting Quality header
    local craftHeader = panel:CreateFontString(nil, "OVERLAY")
    craftHeader:SetFont(ns.FONT, 10, "")
    craftHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, yOff)
    craftHeader:SetText("Crafting Quality")
    craftHeader:SetTextColor(unpack(ns.COLORS.headerText))
    yOff = yOff - 18

    local craftTierDefs = {
        { tier = 0, label = "No Tier" },
        { tier = 1, label = "Tier 1" },
        { tier = 2, label = "Tier 2" },
        { tier = 3, label = "Tier 3" },
    }

    for _, def in ipairs(craftTierDefs) do
        local cb = CreateFlatCheck(panel, def.label, filterState.craftTiers[def.tier], nil, function(checked)
            filterState.craftTiers[def.tier] = checked
            SaveFilterState()
            AHBrowse:RefreshRows()
            AHBrowse:UpdateResultStatus()
        end)
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, yOff)
        cb:SetPoint("RIGHT", panel, "RIGHT", -6, 0)
        -- Add tier atlas icon next to label for tiers 1-3
        if def.tier > 0 then
            local atlas = ns.GetQualityAtlas(def.tier)
            if atlas then
                local tierIcon = cb:CreateTexture(nil, "OVERLAY")
                tierIcon:SetSize(14, 14)
                tierIcon:SetAtlas(atlas)
                tierIcon:SetPoint("RIGHT", cb, "RIGHT", -4, 0)
            end
        end
        yOff = yOff - 20
    end

    -- Adjust panel height to content
    panel:SetHeight(math.abs(yOff) + 8)

    -- Update level state when focus lost
    panel.minLevelBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
        local val = tonumber(self:GetText())
        filterState.minLevel = (val and val > 0) and val or nil
        SaveFilterState()
    end)
    panel.maxLevelBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
        local val = tonumber(self:GetText())
        filterState.maxLevel = (val and val > 0) and val or nil
        SaveFilterState()
    end)

    return panel
end

--------------------------------------------------------------------
-- Build filters array for query
--------------------------------------------------------------------
local function BuildFiltersArray()
    local arr = {}

    if filterState.uncollectedOnly then
        table.insert(arr, Enum.AuctionHouseFilter.UncollectedOnly)
    end
    if filterState.usableOnly then
        table.insert(arr, Enum.AuctionHouseFilter.UsableOnly)
    end
    if filterState.currentExpansionOnly then
        table.insert(arr, Enum.AuctionHouseFilter.CurrentExpansionOnly)
    end
    if filterState.upgradesOnly then
        table.insert(arr, Enum.AuctionHouseFilter.UpgradesOnly)
    end

    -- Quality filters: include all checked qualities
    for filterEnum, checked in pairs(filterState.qualities) do
        if checked then
            table.insert(arr, filterEnum)
        end
    end

    return arr
end

--------------------------------------------------------------------
-- Result row factory — Price | Name | Available
--------------------------------------------------------------------
local function CreateResultRow(parent, index)
    local row = ns.CreateRow(parent, index, ROW_HEIGHT)

    -- Price (left column)
    row.priceText = row:CreateFontString(nil, "OVERLAY")
    row.priceText:SetFont(ns.FONT, 10, "")
    row.priceText:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.priceText:SetWidth(110)
    row.priceText:SetJustifyH("LEFT")
    row.priceText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Icon + Name (middle)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row, "LEFT", 120, 0)

    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -140, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Quality icon (crafting tier badge)
    row.qualityIcon = row:CreateTexture(nil, "OVERLAY")
    row.qualityIcon:SetSize(14, 14)
    row.qualityIcon:SetPoint("RIGHT", row, "RIGHT", -126, 0)
    row.qualityIcon:Hide()

    -- iLvl column
    row.ilvlText = row:CreateFontString(nil, "OVERLAY")
    row.ilvlText:SetFont(ns.FONT, 10, "")
    row.ilvlText:SetPoint("RIGHT", row, "RIGHT", -76, 0)
    row.ilvlText:SetWidth(40)
    row.ilvlText:SetJustifyH("RIGHT")
    row.ilvlText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Available (right column)
    row.availText = row:CreateFontString(nil, "OVERLAY")
    row.availText:SetFont(ns.FONT, 10, "")
    row.availText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.availText:SetWidth(70)
    row.availText:SetJustifyH("RIGHT")
    row.availText:SetTextColor(unpack(ns.COLORS.mutedText))

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if not self._browseResult then return end
        if button == "RightButton" then
            AHBrowse:QuickBuy(self._browseResult)
        else
            AHBrowse:SelectResult(self._browseResult, self._rowIndex)
        end
    end)

    -- Override OnEnter/OnLeave to add tooltip
    row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        self.leftAccent:Show()
        if self._browseResult and self._browseResult.itemKey then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemKey(self._browseResult.itemKey.itemID,
                self._browseResult.itemKey.itemLevel or 0,
                self._browseResult.itemKey.itemSuffix or 0)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(1, 1, 1, self._defaultBgAlpha)
        self.leftAccent:Hide()
        GameTooltip:Hide()
    end)

    return row
end

--------------------------------------------------------------------
-- Detail overlay (commodity buy / item buyout)
--------------------------------------------------------------------
local function CreateDetailOverlay(parent)
    local overlay = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
    })
    overlay:SetBackdropColor(18/255, 18/255, 18/255, 0.97)
    overlay:SetFrameLevel(parent:GetFrameLevel() + 10)
    overlay:EnableMouse(true)
    overlay:Hide()

    -- Back button
    local backBtn = ns.CreateButton(overlay, "< Back", 60, 22)
    backBtn:SetPoint("TOPLEFT", overlay, "TOPLEFT", 6, -4)
    backBtn:SetScript("OnClick", function()
        overlay:Hide()
    end)

    -- Icon (wrapped in button for tooltip)
    local iconBtn = CreateFrame("Button", nil, overlay)
    iconBtn:SetSize(40, 40)
    iconBtn:SetPoint("TOPLEFT", overlay, "TOPLEFT", 80, -6)
    iconBtn:SetScript("OnEnter", function(self)
        if self._itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self._itemID)
            GameTooltip:Show()
        end
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    overlay._iconBtn = iconBtn

    overlay.icon = iconBtn:CreateTexture(nil, "ARTWORK")
    overlay.icon:SetSize(40, 40)
    overlay.icon:SetPoint("CENTER")

    -- Quality badge (crafting tier)
    overlay.qualityIcon = overlay:CreateTexture(nil, "OVERLAY")
    overlay.qualityIcon:SetSize(17, 17)
    overlay.qualityIcon:SetPoint("LEFT", overlay.icon, "RIGHT", 10, 4)
    overlay.qualityIcon:Hide()

    -- Name (shifts right when quality badge is visible)
    overlay.nameText = overlay:CreateFontString(nil, "OVERLAY")
    overlay.nameText:SetFont(ns.FONT, 14, "")
    overlay.nameText:SetPoint("LEFT", overlay.icon, "RIGHT", 10, 4)
    overlay.nameText:SetPoint("RIGHT", overlay, "RIGHT", -12, 0)
    overlay.nameText:SetJustifyH("LEFT")
    overlay.nameText:SetWordWrap(false)
    overlay.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Type
    overlay.typeText = overlay:CreateFontString(nil, "OVERLAY")
    overlay.typeText:SetFont(ns.FONT, 10, "")
    overlay.typeText:SetPoint("TOPLEFT", overlay.icon, "BOTTOMLEFT", 0, -10)
    overlay.typeText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Available
    overlay.availText = overlay:CreateFontString(nil, "OVERLAY")
    overlay.availText:SetFont(ns.FONT, 10, "")
    overlay.availText:SetPoint("TOPLEFT", overlay.typeText, "BOTTOMLEFT", 0, -4)
    overlay.availText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Unit price
    overlay.priceLabel = overlay:CreateFontString(nil, "OVERLAY")
    overlay.priceLabel:SetFont(ns.FONT, 10, "")
    overlay.priceLabel:SetPoint("TOPLEFT", overlay.availText, "BOTTOMLEFT", 0, -12)
    overlay.priceLabel:SetText("Unit Price:")
    overlay.priceLabel:SetTextColor(unpack(ns.COLORS.headerText))

    overlay.priceText = overlay:CreateFontString(nil, "OVERLAY")
    overlay.priceText:SetFont(ns.FONT, 12, "")
    overlay.priceText:SetPoint("LEFT", overlay.priceLabel, "RIGHT", 8, 0)
    overlay.priceText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Commodity section: qty input + total + buy
    overlay.qtyLabel = overlay:CreateFontString(nil, "OVERLAY")
    overlay.qtyLabel:SetFont(ns.FONT, 10, "")
    overlay.qtyLabel:SetPoint("TOPLEFT", overlay.priceLabel, "BOTTOMLEFT", 0, -14)
    overlay.qtyLabel:SetText("Quantity:")
    overlay.qtyLabel:SetTextColor(unpack(ns.COLORS.headerText))

    overlay.qtyBox = CreateFrame("EditBox", nil, overlay, "BackdropTemplate")
    overlay.qtyBox:SetSize(70, 24)
    overlay.qtyBox:SetPoint("LEFT", overlay.qtyLabel, "RIGHT", 8, 0)
    overlay.qtyBox:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    overlay.qtyBox:SetBackdropColor(unpack(ns.COLORS.searchBg))
    overlay.qtyBox:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    overlay.qtyBox:SetFont(ns.FONT, 12, "")
    overlay.qtyBox:SetTextColor(unpack(ns.COLORS.brightText))
    overlay.qtyBox:SetJustifyH("CENTER")
    overlay.qtyBox:SetAutoFocus(false)
    overlay.qtyBox:SetNumeric(true)
    overlay.qtyBox:SetMaxLetters(5)
    overlay.qtyBox:SetText("1")
    overlay.qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    overlay.qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    overlay.qtyBox:SetScript("OnTextChanged", function()
        AHBrowse:UpdateTotalPrice()
    end)

    overlay.totalLabel = overlay:CreateFontString(nil, "OVERLAY")
    overlay.totalLabel:SetFont(ns.FONT, 10, "")
    overlay.totalLabel:SetPoint("TOPLEFT", overlay.qtyLabel, "BOTTOMLEFT", 0, -10)
    overlay.totalLabel:SetText("Total:")
    overlay.totalLabel:SetTextColor(unpack(ns.COLORS.headerText))

    overlay.totalText = overlay:CreateFontString(nil, "OVERLAY")
    overlay.totalText:SetFont(ns.FONT, 12, "")
    overlay.totalText:SetPoint("LEFT", overlay.totalLabel, "RIGHT", 8, 0)
    overlay.totalText:SetTextColor(unpack(ns.COLORS.goldText))

    overlay.buyBtn = ns.CreateButton(overlay, "Buy", 120, 28)
    overlay.buyBtn:SetPoint("TOPLEFT", overlay.totalLabel, "BOTTOMLEFT", 0, -16)
    overlay.buyBtn:SetScript("OnClick", function()
        AHBrowse:BuySelected()
    end)

    -- Item section: buyout button
    overlay.buyoutBtn = ns.CreateButton(overlay, "Buyout", 120, 28)
    overlay.buyoutBtn:SetPoint("TOPLEFT", overlay.priceLabel, "BOTTOMLEFT", 0, -16)
    overlay.buyoutBtn:SetScript("OnClick", function()
        AHBrowse:BuyoutSelected()
    end)
    overlay.buyoutBtn:Hide()

    return overlay
end

--------------------------------------------------------------------
-- Build UI
--------------------------------------------------------------------
function AHBrowse:Init(contentFrame)
    if container then return end

    -- Load saved filter state
    LoadFilterState()

    -- Build the category tree (needs AH to be open for API calls)
    categoryTree = BuildCategoryTree()

    container = CreateFrame("Frame", nil, contentFrame)
    container:SetAllPoints()
    container:Hide()

    -- Category sidebar (left) — scrollable
    local sidebarFrame = CreateFrame("Frame", nil, container, "BackdropTemplate")
    sidebarFrame:SetWidth(SIDEBAR_WIDTH)
    sidebarFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    sidebarFrame:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    sidebarFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    sidebarFrame:SetBackdropColor(unpack(ns.COLORS.panelBg))
    sidebarFrame:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    sidebarScroll = CreateFrame("ScrollFrame", nil, sidebarFrame, "UIPanelScrollFrameTemplate")
    sidebarScroll:SetPoint("TOPLEFT", 1, -1)
    sidebarScroll:SetPoint("BOTTOMRIGHT", -18, 1)

    sidebarContent = CreateFrame("Frame", nil, sidebarScroll)
    sidebarContent:SetWidth(SIDEBAR_WIDTH - 20)
    sidebarContent:SetHeight(1)
    sidebarScroll:SetScrollChild(sidebarContent)

    -- Status text (bottom of sidebar)
    statusText = sidebarFrame:CreateFontString(nil, "OVERLAY")
    statusText:SetFont(ns.FONT, 9, "")
    statusText:SetPoint("BOTTOMLEFT", sidebarFrame, "BOTTOMLEFT", 6, 4)
    statusText:SetPoint("RIGHT", sidebarFrame, "RIGHT", -4, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Search bar (top, right of sidebar)
    searchBox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    searchBox:SetHeight(24)
    searchBox:SetPoint("TOPLEFT", sidebarFrame, "TOPRIGHT", 8, -4)
    searchBox:SetPoint("RIGHT", container, "RIGHT", -150, 0)
    searchBox:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    searchBox:SetBackdropColor(unpack(ns.COLORS.searchBg))
    searchBox:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    searchBox:SetFont(ns.FONT, 12, "")
    searchBox:SetTextColor(unpack(ns.COLORS.brightText))
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(64)

    searchBox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchFocus))
    end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(ns.COLORS.searchBorder))
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        AHBrowse:DoSearch()
    end)

    -- Shift-click item → extract name, populate search, auto-fire
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if not searchBox:IsVisible() then return end
        if not link then return end
        local name = C_Item.GetItemNameByID(link) or link:match("%[(.-)%]")
        if name then
            searchBox:SetText(name)
            AHBrowse:DoSearch()
        end
    end)

    -- Filter button
    filterBtn = ns.CreateButton(container, "Filter", 66, 24)
    filterBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", -74, -4)
    filterBtn:SetScript("OnClick", function()
        searchBox:ClearFocus()
        if filterPanel then
            if filterPanel:IsShown() then
                filterPanel:Hide()
            else
                filterPanel:Show()
            end
        end
    end)
    filterBtn:SetScript("OnLeave", function(self)
        if self._active then
            self.label:SetTextColor(unpack(ns.COLORS.tabActive))
            self:SetBackdropBorderColor(unpack(ns.COLORS.tabActive))
        else
            self.label:SetTextColor(unpack(ns.COLORS.btnDefault))
            self:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
        end
    end)

    -- Search button
    local searchBtn = ns.CreateButton(container, "Search", 66, 24)
    searchBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", -4, -4)
    searchBtn:SetScript("OnClick", function()
        searchBox:ClearFocus()
        if filterPanel then filterPanel:Hide() end
        AHBrowse:DoSearch()
    end)

    -- Filter dropdown panel (positioned below Filter button)
    filterPanel = CreateFilterPanel(container)
    filterPanel:SetPoint("TOPRIGHT", filterBtn, "BOTTOMRIGHT", 0, -2)

    -- Populate level boxes from saved state
    if filterState.minLevel then
        filterPanel.minLevelBox:SetText(tostring(filterState.minLevel))
    end
    if filterState.maxLevel then
        filterPanel.maxLevelBox:SetText(tostring(filterState.maxLevel))
    end

    -- Set initial glow state from persisted filters
    UpdateFilterBtnGlow()

    -- Sortable column headers
    local colHeaders = CreateFrame("Frame", nil, container)
    colHeaders:SetHeight(18)
    colHeaders:SetPoint("TOPLEFT", sidebarFrame, "TOPRIGHT", 4, -32)
    colHeaders:SetPoint("RIGHT", container, "RIGHT", -4, 0)

    local function UpdateSortIndicators()
        for _, cb in pairs(colHeaderBtns) do
            if cb._sortOrder == currentSortOrder then
                local arrow = currentSortReverse and " v" or " ^"
                cb.label:SetText(cb._baseText .. arrow)
                cb.label:SetTextColor(unpack(ns.COLORS.tabActive))
            else
                cb.label:SetText(cb._baseText)
                cb.label:SetTextColor(unpack(ns.COLORS.headerText))
            end
        end
    end

    local function CreateSortHeader(text, sortOrder, anchor, x, w, justify)
        local btn = CreateFrame("Button", nil, colHeaders)
        btn:SetHeight(18)
        if justify == "RIGHT" then
            btn:SetPoint("RIGHT", colHeaders, "RIGHT", x, 0)
            btn:SetWidth(w)
        else
            btn:SetPoint("LEFT", colHeaders, "LEFT", x, 0)
            btn:SetWidth(w)
        end

        btn.label = btn:CreateFontString(nil, "OVERLAY")
        btn.label:SetFont(ns.FONT, 9, "")
        btn.label:SetAllPoints()
        btn.label:SetJustifyH(justify or "LEFT")
        btn.label:SetTextColor(unpack(ns.COLORS.headerText))
        btn.label:SetText(text)

        btn._baseText = text
        btn._sortOrder = sortOrder

        btn:SetScript("OnClick", function()
            if currentSortOrder == sortOrder then
                currentSortReverse = not currentSortReverse
            else
                currentSortOrder = sortOrder
                currentSortReverse = false
            end
            UpdateSortIndicators()
            AHBrowse:DoSearch()
        end)
        btn:SetScript("OnEnter", function(self)
            if self._sortOrder ~= currentSortOrder then
                self.label:SetTextColor(unpack(ns.COLORS.tabHover))
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if self._sortOrder ~= currentSortOrder then
                self.label:SetTextColor(unpack(ns.COLORS.headerText))
            end
        end)

        colHeaderBtns[sortOrder] = btn
        return btn
    end

    CreateSortHeader("Price", Enum.AuctionHouseSortOrder.Price, "LEFT", 6, 110, "LEFT")
    CreateSortHeader("Name", Enum.AuctionHouseSortOrder.Name, "LEFT", 120, 200, "LEFT")
    CreateSortHeader("iLvl", Enum.AuctionHouseSortOrder.Level, "RIGHT", -76, 40, "RIGHT")
    UpdateSortIndicators()

    -- Qual header (not sortable — client-side crafting quality)
    local qualLabel = colHeaders:CreateFontString(nil, "OVERLAY")
    qualLabel:SetFont(ns.FONT, 9, "")
    qualLabel:SetPoint("RIGHT", colHeaders, "RIGHT", -126, 0)
    qualLabel:SetWidth(20)
    qualLabel:SetJustifyH("CENTER")
    qualLabel:SetText("Qual")
    qualLabel:SetTextColor(unpack(ns.COLORS.headerText))

    -- Available header (not sortable — no server-side sort order for quantity)
    local availLabel = colHeaders:CreateFontString(nil, "OVERLAY")
    availLabel:SetFont(ns.FONT, 9, "")
    availLabel:SetPoint("RIGHT", colHeaders, "RIGHT", -6, 0)
    availLabel:SetWidth(70)
    availLabel:SetJustifyH("RIGHT")
    availLabel:SetText("Available")
    availLabel:SetTextColor(unpack(ns.COLORS.headerText))

    -- Result scroll area
    resultArea = CreateFrame("Frame", nil, container)
    resultArea:SetPoint("TOPLEFT", sidebarFrame, "TOPRIGHT", 4, -50)
    resultArea:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -4, 0)

    local resultScroll = CreateFrame("ScrollFrame", nil, resultArea, "UIPanelScrollFrameTemplate")
    resultScroll:SetPoint("TOPLEFT")
    resultScroll:SetPoint("BOTTOMRIGHT", -16, 0)

    resultContent = CreateFrame("Frame", nil, resultScroll)
    resultContent:SetWidth(1)
    resultContent:SetHeight(1)
    resultScroll:SetScrollChild(resultContent)

    resultScroll:SetScript("OnSizeChanged", function(self)
        resultContent:SetWidth(self:GetWidth())
    end)

    for i = 1, MAX_ROWS do
        resultRows[i] = CreateResultRow(resultContent, i)
    end

    -- Detail overlay
    detailOverlay = CreateDetailOverlay(resultArea)

    -- Build the sidebar
    RebuildSidebar()
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function AHBrowse:Show()
    if not container then return end
    selectedCatNode = nil
    RebuildSidebar()
    container:Show()
end

function AHBrowse:Hide()
    if container then container:Hide() end
end

function AHBrowse:IsShown()
    return container and container:IsShown()
end

--------------------------------------------------------------------
-- Search (fires on button click / Enter only)
--------------------------------------------------------------------
function AHBrowse:DoSearch()
    if not ns.AHUI or not ns.AHUI:IsAHOpen() then return end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        self:SetStatus("Throttled...")
        return
    end

    local text = searchBox and strtrim(searchBox:GetText()) or ""
    local catNode = selectedCatNode

    -- For re-sort: if no current input but we have a previous search, reuse it
    if text == "" and not catNode then
        if lastSearchText or lastSearchCatNode then
            text = lastSearchText or ""
            catNode = lastSearchCatNode
        else
            return
        end
    end

    -- Save for re-sort
    lastSearchText = text
    lastSearchCatNode = catNode

    -- Read level range from filter panel
    if filterPanel then
        local minVal = tonumber(filterPanel.minLevelBox:GetText())
        filterState.minLevel = (minVal and minVal > 0) and minVal or nil
        local maxVal = tonumber(filterPanel.maxLevelBox:GetText())
        filterState.maxLevel = (maxVal and maxVal > 0) and maxVal or nil
    end

    -- Blizzard always sends primary + secondary sort (max 2)
    local primarySort = { sortOrder = currentSortOrder, reverseSort = currentSortReverse }
    local secondaryOrder
    if currentSortOrder ~= Enum.AuctionHouseSortOrder.Price then
        secondaryOrder = Enum.AuctionHouseSortOrder.Price
    else
        secondaryOrder = Enum.AuctionHouseSortOrder.Name
    end
    local secondarySort = { sortOrder = secondaryOrder, reverseSort = false }

    local query = {
        searchString = text,
        sorts = { primarySort, secondarySort },
        filters = BuildFiltersArray(),
        itemClassFilters = {},
    }

    if filterState.minLevel then query.minLevel = filterState.minLevel end
    if filterState.maxLevel then query.maxLevel = filterState.maxLevel end

    if catNode and catNode.filters then
        for _, f in ipairs(catNode.filters) do
            table.insert(query.itemClassFilters, f)
        end
    end

    C_AuctionHouse.SendBrowseQuery(query)
    self:SetStatus("Searching...")
    wipe(browseResults)
    self:RefreshRows()
    if detailOverlay then detailOverlay:Hide() end
end

function AHBrowse:SetStatus(text)
    if statusText then
        statusText:SetText(text or "")
    end
end

--------------------------------------------------------------------
-- Refresh (called from AHUI on GET_ITEM_INFO_RECEIVED)
--------------------------------------------------------------------
function AHBrowse:Refresh()
    self:RefreshRows()
end

--------------------------------------------------------------------
-- Crafting tier client-side filter
--------------------------------------------------------------------
local function NeedsCraftTierFilter()
    if not filterState.craftTiers then return false end
    for k, v in pairs(FILTER_DEFAULTS.craftTiers) do
        if filterState.craftTiers[k] ~= v then return true end
    end
    return false
end

local function FilterBrowseResults()
    if not NeedsCraftTierFilter() then return browseResults end
    local filtered = {}
    for _, r in ipairs(browseResults) do
        local tier = ns.GetCraftingQuality(r.itemKey.itemID) or 0
        if filterState.craftTiers[tier] then
            table.insert(filtered, r)
        end
    end
    return filtered
end

--------------------------------------------------------------------
-- Browse results events
--------------------------------------------------------------------
function AHBrowse:UpdateResultStatus()
    local total = #browseResults
    if NeedsCraftTierFilter() then
        local filtered = FilterBrowseResults()
        self:SetStatus(#filtered .. " / " .. total .. " results")
    else
        self:SetStatus(total .. " results")
    end
end

function AHBrowse:OnBrowseResultsUpdated()
    browseResults = C_AuctionHouse.GetBrowseResults()
    self:RefreshRows()
    self:UpdateResultStatus()
end

function AHBrowse:OnBrowseResultsAdded(addedResults)
    if addedResults then
        for _, r in ipairs(addedResults) do
            table.insert(browseResults, r)
        end
    else
        browseResults = C_AuctionHouse.GetBrowseResults()
    end
    self:RefreshRows()
    self:UpdateResultStatus()
end

--------------------------------------------------------------------
-- Refresh result rows
--------------------------------------------------------------------
local pendingItemRequests = {}

function AHBrowse:RefreshRows()
    if not resultContent then return end
    local displayResults = FilterBrowseResults()
    local count = #displayResults

    resultContent:SetHeight(math.max(1, count * ROW_HEIGHT))
    selectedRowIndex = nil

    local needsRetry = false

    for i = 1, math.max(count, #resultRows) do
        local row = resultRows[i]
        if not row and i <= count then
            row = CreateResultRow(resultContent, i)
            resultRows[i] = row
        end
        if row then
            if i <= count then
                local r = displayResults[i]
                local keyInfo = C_AuctionHouse.GetItemKeyInfo(r.itemKey)

                if keyInfo and keyInfo.itemName then
                    row.icon:SetTexture(keyInfo.iconFileID or 134400)
                    local name = keyInfo.itemName
                    local qualityColor = ITEM_QUALITY_COLORS[keyInfo.quality]
                    if qualityColor then
                        row.nameText:SetText(qualityColor.hex .. name .. "|r")
                    else
                        row.nameText:SetText(name)
                    end
                else
                    local itemID = r.itemKey.itemID
                    if not pendingItemRequests[itemID] then
                        pendingItemRequests[itemID] = true
                        C_Item.RequestLoadItemDataByID(itemID)
                    end
                    local itemName, _, itemQuality, _, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(itemID)
                    if itemName then
                        row.icon:SetTexture(itemTexture or 134400)
                        local qualityColor = ITEM_QUALITY_COLORS[itemQuality]
                        if qualityColor then
                            row.nameText:SetText(qualityColor.hex .. itemName .. "|r")
                        else
                            row.nameText:SetText(itemName)
                        end
                    else
                        row.icon:SetTexture(134400)
                        row.nameText:SetText("Loading...")
                        needsRetry = true
                    end
                end

                row.priceText:SetText(ns.FormatGold(r.minPrice or 0))
                local ilvl = r.itemKey and r.itemKey.itemLevel or 0
                row.ilvlText:SetText(ilvl > 0 and tostring(ilvl) or "")
                row.availText:SetText(tostring(r.totalQuantity or 0))

                -- Crafting quality badge
                local cq = ns.GetCraftingQuality(r.itemKey.itemID)
                local cqAtlas = ns.GetQualityAtlas(cq)
                if cqAtlas then
                    row.qualityIcon:SetAtlas(cqAtlas)
                    row.qualityIcon:Show()
                else
                    row.qualityIcon:Hide()
                end

                row._browseResult = r
                row._rowIndex = i
                row:Show()
            else
                row._browseResult = nil
                row._rowIndex = nil
                row.qualityIcon:Hide()
                row:Hide()
            end
        end
    end

    if needsRetry and not self._retryTimer then
        self._retryTimer = C_Timer.After(0.5, function()
            self._retryTimer = nil
            wipe(pendingItemRequests)
            if self:IsShown() then
                self:RefreshRows()
            end
        end)
    end
end

--------------------------------------------------------------------
-- Select a browse result -> show detail overlay
--------------------------------------------------------------------
function AHBrowse:SelectResult(result, rowIndex)
    if not result or not result.itemKey then return end
    selectedResult = result
    selectedItemKey = result.itemKey
    selectedRowIndex = rowIndex

    -- Highlight selected row
    for i, row in ipairs(resultRows) do
        if row:IsShown() then
            if i == rowIndex then
                row.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
                row.leftAccent:Show()
            else
                row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)
                row.leftAccent:Hide()
            end
        end
    end

    local keyInfo = C_AuctionHouse.GetItemKeyInfo(result.itemKey)
    if not keyInfo then return end

    local d = detailOverlay
    if d._iconBtn then d._iconBtn._itemID = result.itemKey.itemID end
    d.icon:SetTexture(keyInfo.iconFileID or 134400)
    local qualityColor = ITEM_QUALITY_COLORS[keyInfo.quality]
    if qualityColor then
        d.nameText:SetText(qualityColor.hex .. (keyInfo.itemName or "?") .. "|r")
    else
        d.nameText:SetText(keyInfo.itemName or "?")
    end

    -- Crafting quality badge next to name
    local cq = ns.GetCraftingQuality(result.itemKey.itemID)
    local cqAtlas = ns.GetQualityAtlas(cq)
    d.nameText:ClearAllPoints()
    if cqAtlas then
        d.qualityIcon:SetAtlas(cqAtlas)
        d.qualityIcon:Show()
        d.nameText:SetPoint("LEFT", d.qualityIcon, "RIGHT", 4, 0)
    else
        d.qualityIcon:Hide()
        d.nameText:SetPoint("LEFT", d.icon, "RIGHT", 10, 4)
    end
    d.nameText:SetPoint("RIGHT", d, "RIGHT", -12, 0)

    d.priceText:SetText(ns.FormatGold(result.minPrice or 0))

    if keyInfo.isCommodity then
        d.typeText:SetText("Commodity")
        d.availText:SetText("Available: " .. (result.totalQuantity or 0))
        d.qtyLabel:Show()
        d.qtyBox:Show()
        d.qtyBox:SetText("1")
        d.totalLabel:Show()
        d.totalText:Show()
        d.buyBtn:Show()
        d.buyoutBtn:Hide()
        self:UpdateTotalPrice()

        local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
        C_AuctionHouse.SendSearchQuery(
            C_AuctionHouse.MakeItemKey(result.itemKey.itemID),
            sorts, true
        )
    else
        d.typeText:SetText(keyInfo.isEquipment and "Equipment" or "Item")
        d.availText:SetText("Available: " .. (result.totalQuantity or 0))
        d.qtyLabel:Hide()
        d.qtyBox:Hide()
        d.totalLabel:Hide()
        d.totalText:Hide()
        d.buyBtn:Hide()
        d.buyoutBtn:Show()

        local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
        C_AuctionHouse.SendSearchQuery(result.itemKey, sorts, true)
    end

    d:Show()
end

--------------------------------------------------------------------
-- Update total price (commodity)
--------------------------------------------------------------------
function AHBrowse:UpdateTotalPrice()
    if not detailOverlay or not selectedResult then return end
    local qty = tonumber(detailOverlay.qtyBox:GetText()) or 1
    if qty < 1 then qty = 1 end
    local unitPrice = selectedResult.minPrice or 0
    detailOverlay.totalText:SetText(ns.FormatGold(qty * unitPrice))
end

--------------------------------------------------------------------
-- Quick buy (right-click) — commodity: confirm dialog qty 1, item: direct buyout
--------------------------------------------------------------------
function AHBrowse:QuickBuy(result)
    if not result or not result.itemKey then return end
    local keyInfo = C_AuctionHouse.GetItemKeyInfo(result.itemKey)
    if not keyInfo then return end

    if keyInfo.isCommodity then
        -- Commodity: open confirm dialog for qty 1
        ns.AHUI:ShowConfirmDialog(result.itemKey.itemID, 1)
    else
        -- Item: search then buyout cheapest via StaticPopup
        selectedResult = result
        selectedItemKey = result.itemKey
        local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
        C_AuctionHouse.SendSearchQuery(result.itemKey, sorts, true)
        -- Flag for auto-buyout when results arrive
        self._pendingQuickBuyout = true
    end
end

--------------------------------------------------------------------
-- Buy commodity
--------------------------------------------------------------------
function AHBrowse:BuySelected()
    if not selectedResult or not selectedItemKey then return end
    local keyInfo = C_AuctionHouse.GetItemKeyInfo(selectedItemKey)
    if not keyInfo or not keyInfo.isCommodity then return end

    local qty = tonumber(detailOverlay.qtyBox:GetText()) or 1
    if qty < 1 then qty = 1 end
    ns.AHUI:ShowConfirmDialog(selectedItemKey.itemID, qty)
end

--------------------------------------------------------------------
-- Buyout item (non-commodity)
--------------------------------------------------------------------
function AHBrowse:BuyoutSelected()
    if not selectedResult or not selectedItemKey then return end
    local keyInfo = C_AuctionHouse.GetItemKeyInfo(selectedItemKey)
    if not keyInfo or keyInfo.isCommodity then return end

    local numResults = C_AuctionHouse.GetNumItemSearchResults(selectedItemKey)
    if not numResults or numResults == 0 then
        self:SetStatus("No auctions found.")
        return
    end

    local cheapest = C_AuctionHouse.GetItemSearchResultInfo(selectedItemKey, 1)
    if not cheapest then return end

    local buyout = cheapest.buyoutAmount
    if not buyout or buyout == 0 then
        self:SetStatus("No buyout price.")
        return
    end

    StaticPopupDialogs["KAZCRAFT_ITEM_BUYOUT"] = {
        text = "Buy this item for %s?",
        button1 = "Buy",
        button2 = "Cancel",
        OnAccept = function(self)
            C_AuctionHouse.PlaceBid(self.data.auctionID, self.data.buyout)
        end,
        timeout = 0,
        whileDead = false,
        hideOnEscape = true,
        hasItemFrame = false,
    }

    local popup = StaticPopup_Show("KAZCRAFT_ITEM_BUYOUT", ns.FormatGold(buyout))
    if popup then
        popup.data = { auctionID = cheapest.auctionID, buyout = buyout }
    end
end

--------------------------------------------------------------------
-- Item search results (non-commodity detail)
--------------------------------------------------------------------
function AHBrowse:OnItemSearchResults()
    if not selectedItemKey then return end

    -- Quick buyout from right-click
    if self._pendingQuickBuyout then
        self._pendingQuickBuyout = nil
        local numResults = C_AuctionHouse.GetNumItemSearchResults(selectedItemKey)
        if numResults and numResults > 0 then
            local cheapest = C_AuctionHouse.GetItemSearchResultInfo(selectedItemKey, 1)
            if cheapest and cheapest.buyoutAmount and cheapest.buyoutAmount > 0 then
                StaticPopupDialogs["KAZCRAFT_ITEM_BUYOUT"] = {
                    text = "Buy this item for %s?",
                    button1 = "Buy",
                    button2 = "Cancel",
                    OnAccept = function(self)
                        C_AuctionHouse.PlaceBid(self.data.auctionID, self.data.buyout)
                    end,
                    timeout = 0,
                    whileDead = false,
                    hideOnEscape = true,
                }
                local popup = StaticPopup_Show("KAZCRAFT_ITEM_BUYOUT", ns.FormatGold(cheapest.buyoutAmount))
                if popup then
                    popup.data = { auctionID = cheapest.auctionID, buyout = cheapest.buyoutAmount }
                end
            end
        end
        return
    end

    -- Normal detail overlay update
    if not detailOverlay or not detailOverlay:IsShown() then return end
    local keyInfo = C_AuctionHouse.GetItemKeyInfo(selectedItemKey)
    if not keyInfo or keyInfo.isCommodity then return end

    local numResults = C_AuctionHouse.GetNumItemSearchResults(selectedItemKey)
    if numResults and numResults > 0 then
        local cheapest = C_AuctionHouse.GetItemSearchResultInfo(selectedItemKey, 1)
        if cheapest and cheapest.buyoutAmount and cheapest.buyoutAmount > 0 then
            detailOverlay.priceText:SetText(ns.FormatGold(cheapest.buyoutAmount))
        end
    end
end

--------------------------------------------------------------------
-- Commodity search results (detail pricing)
--------------------------------------------------------------------
function AHBrowse:OnCommoditySearchResults(itemID)
    if not selectedItemKey then return end
    if not detailOverlay or not detailOverlay:IsShown() then return end
    if selectedItemKey.itemID ~= itemID then return end

    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
    if numResults and numResults > 0 then
        local cheapest = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
        if cheapest and cheapest.unitPrice then
            selectedResult.minPrice = cheapest.unitPrice
            detailOverlay.priceText:SetText(ns.FormatGold(cheapest.unitPrice))
            self:UpdateTotalPrice()
        end
    end
end
