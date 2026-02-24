local addonName, ns = ...

local ProfFrame = {}
ns.ProfFrame = ProfFrame

local FRAME_WIDTH = 960
local FRAME_HEIGHT = 620
local MIN_WIDTH, MIN_HEIGHT = 750, 500
local MAX_WIDTH, MAX_HEIGHT = 1200, 800
local TOP_BAR_HEIGHT = 32
local TAB_BAR_HEIGHT = 28
local FOOTER_HEIGHT = 32

-- State
local mainFrame
local tabBar
local contentFrame
local topBar = {}
local footer = {}
local profOpen = false
local activeTab = nil
local switchingToBlizzard = false

-- Tab definitions
local TAB_DEFS = {
    { key = "recipes", label = "Recipes", module = function() return ns.ProfRecipes end },
    { key = "specs",   label = "Specializations", module = function() return nil end },
    { key = "orders",  label = "Crafting Orders", module = function() return nil end },
}

--------------------------------------------------------------------
-- Blizzard ProfessionsFrame suppression
-- Can't Hide() — OnHide calls CloseTradeSkill(). Can't SetScale —
-- corrupts CraftSim/tab sizing on restore. Solution: move offscreen
-- + SetAlpha(0). Frame stays "shown", APIs keep working, no visual.
--------------------------------------------------------------------
local blizzPointSaved = nil

local function SuppressBlizzardProf()
    if not ProfessionsFrame then return end
    -- Save current anchor before moving offscreen
    if not blizzPointSaved then
        local point, relativeTo, relPoint, x, y = ProfessionsFrame:GetPoint(1)
        if point then
            blizzPointSaved = { point, relPoint, x, y }
        end
    end
    ProfessionsFrame:ClearAllPoints()
    ProfessionsFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMRIGHT", 2000, -2000)
    ProfessionsFrame:SetAlpha(0)
end

local function RestoreBlizzardProf()
    if not ProfessionsFrame then return end
    ProfessionsFrame:SetAlpha(1)
    ProfessionsFrame:ClearAllPoints()
    if blizzPointSaved then
        ProfessionsFrame:SetPoint(blizzPointSaved[1], UIParent, blizzPointSaved[2],
            blizzPointSaved[3], blizzPointSaved[4])
    else
        ProfessionsFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
    end
    blizzPointSaved = nil
end

--------------------------------------------------------------------
-- Top bar — profession icon, name, skill bar, KP, WoW UI, close
--------------------------------------------------------------------
local function UpdateTopBar()
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    if not profInfo then return end

    -- Icon
    if profInfo.parentProfessionID then
        local parentInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID(profInfo.parentProfessionID)
        if parentInfo and parentInfo.professionID then
            topBar.icon:SetTexture(C_TradeSkillUI.GetTradeSkillTexture(parentInfo.professionID))
        end
    end

    -- Name (professionName already includes expansion, e.g. "Khaz Algar Leatherworking")
    topBar.nameText:SetText(profInfo.professionName or "Unknown")

    -- Skill bar
    local skillLevel = profInfo.skillLevel or 0
    local maxSkillLevel = profInfo.maxSkillLevel or 1
    local skillModifier = profInfo.skillModifier or 0
    topBar.skillText:SetText(skillLevel .. "/" .. maxSkillLevel ..
        (skillModifier > 0 and (" |cff4dff4d(+" .. skillModifier .. ")|r") or ""))

    local pct = maxSkillLevel > 0 and (skillLevel / maxSkillLevel) or 0
    topBar.skillBar:SetWidth(math.max(1, pct * 120))

    -- Expansion dropdown text
    local expansionName = profInfo.expansionName or ""
    if expansionName ~= "" and topBar.expBtnText then
        topBar.expBtnText:SetText(expansionName)
        topBar.expBtn:SetWidth(topBar.expBtnText:GetStringWidth() + topBar.expBtnArrow:GetStringWidth() + 8)
    end

    -- Knowledge points
    local skillLineID = profInfo.professionID
    if skillLineID and C_ProfSpecs and C_ProfSpecs.GetCurrencyInfoForSkillLine then
        local ok, kpInfo = pcall(C_ProfSpecs.GetCurrencyInfoForSkillLine, skillLineID)
        if ok and kpInfo and kpInfo.numAvailable then
            topBar.kpText:SetText("KP: " .. kpInfo.numAvailable)
            topBar.kpText:Show()
        else
            topBar.kpText:Hide()
        end
    else
        topBar.kpText:Hide()
    end
end

local function CreateTopBar(parent)
    -- Icon
    topBar.icon = parent:CreateTexture(nil, "ARTWORK")
    topBar.icon:SetSize(22, 22)
    topBar.icon:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -5)

    -- Profession name
    topBar.nameText = parent:CreateFontString(nil, "OVERLAY")
    topBar.nameText:SetFont(ns.FONT, 13, "")
    topBar.nameText:SetPoint("LEFT", topBar.icon, "RIGHT", 6, 0)
    topBar.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Skill level text
    topBar.skillText = parent:CreateFontString(nil, "OVERLAY")
    topBar.skillText:SetFont(ns.FONT, 11, "")
    topBar.skillText:SetPoint("LEFT", topBar.nameText, "RIGHT", 14, 0)
    topBar.skillText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Skill bar background
    topBar.skillBarBg = parent:CreateTexture(nil, "ARTWORK", nil, 0)
    topBar.skillBarBg:SetSize(120, 4)
    topBar.skillBarBg:SetPoint("LEFT", topBar.skillText, "RIGHT", 8, 0)
    topBar.skillBarBg:SetColorTexture(30/255, 30/255, 30/255, 0.8)

    -- Skill bar fill
    topBar.skillBar = parent:CreateTexture(nil, "ARTWORK", nil, 1)
    topBar.skillBar:SetHeight(4)
    topBar.skillBar:SetPoint("LEFT", topBar.skillBarBg, "LEFT", 0, 0)
    topBar.skillBar:SetColorTexture(unpack(ns.COLORS.accent))
    topBar.skillBar:SetWidth(1)

    -- Expansion dropdown button (clickable text)
    topBar.expBtn = CreateFrame("Button", nil, parent)
    topBar.expBtn:SetHeight(20)
    topBar.expBtn:SetPoint("LEFT", topBar.skillBarBg, "RIGHT", 12, 0)

    topBar.expBtnText = topBar.expBtn:CreateFontString(nil, "OVERLAY")
    topBar.expBtnText:SetFont(ns.FONT, 11, "")
    topBar.expBtnText:SetPoint("LEFT", topBar.expBtn, "LEFT", 0, 0)
    topBar.expBtnText:SetTextColor(unpack(ns.COLORS.tabInactive))

    topBar.expBtnArrow = topBar.expBtn:CreateFontString(nil, "OVERLAY")
    topBar.expBtnArrow:SetFont(ns.FONT, 9, "")
    topBar.expBtnArrow:SetPoint("LEFT", topBar.expBtnText, "RIGHT", 4, 0)
    topBar.expBtnArrow:SetText("v")
    topBar.expBtnArrow:SetTextColor(unpack(ns.COLORS.mutedText))

    topBar.expBtn:SetScript("OnEnter", function()
        topBar.expBtnText:SetTextColor(unpack(ns.COLORS.tabHover))
        topBar.expBtnArrow:SetTextColor(unpack(ns.COLORS.tabHover))
    end)
    topBar.expBtn:SetScript("OnLeave", function()
        topBar.expBtnText:SetTextColor(unpack(ns.COLORS.tabInactive))
        topBar.expBtnArrow:SetTextColor(unpack(ns.COLORS.mutedText))
    end)
    topBar.expBtn:SetScript("OnClick", function(self)
        ProfFrame:ToggleExpansionMenu(self)
    end)

    -- KP text
    topBar.kpText = parent:CreateFontString(nil, "OVERLAY")
    topBar.kpText:SetFont(ns.FONT, 11, "")
    topBar.kpText:SetPoint("LEFT", topBar.expBtn, "RIGHT", 12, 0)
    topBar.kpText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Separator under top bar
    local sep = parent:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", parent, "TOPLEFT", 1, -TOP_BAR_HEIGHT)
    sep:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -1, -TOP_BAR_HEIGHT)
    sep:SetColorTexture(unpack(ns.COLORS.rowDivider))
end

--------------------------------------------------------------------
-- Footer — materials cost, Craft Next
--------------------------------------------------------------------
local function CreateFooter(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetHeight(FOOTER_HEIGHT)
    f:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 1, 1)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -1, 1)
    f:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    f:SetBackdropColor(unpack(ns.COLORS.footerBg))

    -- Materials cost
    footer.costText = f:CreateFontString(nil, "OVERLAY")
    footer.costText:SetFont(ns.FONT, 11, "")
    footer.costText:SetPoint("LEFT", f, "LEFT", 8, 0)
    footer.costText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Craft Next button
    footer.craftBtn = ns.CreateButton(f, "Craft Next", 90, 24)
    footer.craftBtn:SetPoint("RIGHT", f, "RIGHT", -26, 0)
    footer.craftBtn:SetScript("OnClick", function()
        local queue = ns.Data:GetCharacterQueue()
        if #queue == 0 then
            print("|cffc8aa64KazCraft:|r Queue is empty.")
            return
        end
        local entry = queue[1]
        local cached = KazCraftDB.recipeCache[entry.recipeID]
        if not cached then
            print("|cffc8aa64KazCraft:|r Recipe not cached. Open the profession again.")
            return
        end
        ns.lastCraftedRecipeID = entry.recipeID
        C_TradeSkillUI.CraftRecipe(entry.recipeID, 1)
    end)

    -- Resize grip
    local resizeGrip = CreateFrame("Button", nil, parent)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetFrameLevel(parent:GetFrameLevel() + 10)
    resizeGrip:EnableMouse(true)

    local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTex:SetSize(16, 16)
    gripTex:SetPoint("CENTER")
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gripTex:SetVertexColor(120/255, 110/255, 90/255)
    resizeGrip.gripTex = gripTex

    resizeGrip:SetScript("OnEnter", function(self)
        self.gripTex:SetVertexColor(200/255, 180/255, 140/255)
    end)
    resizeGrip:SetScript("OnLeave", function(self)
        self.gripTex:SetVertexColor(120/255, 110/255, 90/255)
    end)
    resizeGrip:SetScript("OnMouseDown", function()
        parent:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        parent:StopMovingOrSizing()
        local w, h = parent:GetSize()
        KazCraftDB.profSize = { math.floor(w + 0.5), math.floor(h + 0.5) }
        -- Notify active tab of resize
        if ns.ProfRecipes and ns.ProfRecipes.OnResize then
            ns.ProfRecipes:OnResize()
        end
    end)

    return f
end

--------------------------------------------------------------------
-- Main frame
--------------------------------------------------------------------
local function CreateMainFrame()
    mainFrame = ns.CreateFlatFrame("KazCraftProfFrame2", FRAME_WIDTH, FRAME_HEIGHT)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetFrameLevel(100)
    mainFrame:Hide()

    -- Resizable
    mainFrame:SetResizable(true)
    mainFrame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)

    -- Restore saved size
    if KazCraftDB.profSize then
        mainFrame:SetSize(KazCraftDB.profSize[1], KazCraftDB.profSize[2])
    end

    -- Close button
    local closeBtn = ns.CreateCloseButton(mainFrame)
    closeBtn:SetScript("OnClick", function()
        ProfFrame:Hide()
    end)

    -- WoW UI button
    local wowBtn = ns.CreateButton(mainFrame, "WoW UI", 54, 20)
    wowBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, 0)
    wowBtn:SetScript("OnClick", function()
        ProfFrame:SwitchToBlizzard()
    end)

    -- ESC key support
    table.insert(UISpecialFrames, "KazCraftProfFrame2")
    mainFrame:SetScript("OnHide", function()
        if switchingToBlizzard then
            switchingToBlizzard = false
            return
        end
        -- Close the profession entirely
        if profOpen then
            profOpen = false
            -- CloseTradeSkill triggers Blizzard OnHide which hides ProfessionsFrame
            -- (still offscreen). Then clear our saved state so next open is clean.
            C_TradeSkillUI.CloseTradeSkill()
            blizzPointSaved = nil
        end
    end)

    -- Top bar
    CreateTopBar(mainFrame)

    -- Tab bar
    local tabDefs = {}
    for _, def in ipairs(TAB_DEFS) do
        table.insert(tabDefs, { key = def.key, label = def.label })
    end

    tabBar = ns.CreateTabBar(mainFrame, tabDefs, function(key)
        ProfFrame:SelectTab(key)
    end)
    tabBar:ClearAllPoints()
    tabBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -(TOP_BAR_HEIGHT + 2))
    tabBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -(TOP_BAR_HEIGHT + 2))

    -- Content area
    contentFrame = CreateFrame("Frame", nil, mainFrame)
    contentFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 1, -(TOP_BAR_HEIGHT + TAB_BAR_HEIGHT + 4))
    contentFrame:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -1, -(TOP_BAR_HEIGHT + TAB_BAR_HEIGHT + 4))
    contentFrame:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, FOOTER_HEIGHT + 1)

    -- Footer
    CreateFooter(mainFrame)

    -- Save/restore position
    function mainFrame:SavePosition()
        local point, _, relPoint, x, y = self:GetPoint()
        KazCraftDB.profPosition = { point, relPoint, x, y }
    end

    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SavePosition()
    end)

    -- Restore position
    local pos = KazCraftDB.profPosition
    if pos and pos[1] then
        mainFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

--------------------------------------------------------------------
-- Tab selection
--------------------------------------------------------------------
function ProfFrame:SelectTab(key)
    activeTab = key

    -- Hide all tab modules
    for _, def in ipairs(TAB_DEFS) do
        local mod = def.module()
        if mod and mod.Hide then
            mod:Hide()
        end
    end

    -- Hide placeholder before showing new tab
    self:HidePlaceholder()

    -- Show selected tab
    for _, def in ipairs(TAB_DEFS) do
        if def.key == key then
            local mod = def.module()
            if mod then
                if mod.Init then
                    mod:Init(contentFrame)
                end
                if mod.Show then
                    mod:Show()
                end
            elseif key == "specs" or key == "orders" then
                -- Placeholder — show message
                self:ShowPlaceholder(key)
            end
            break
        end
    end
end

-- Placeholder for unimplemented tabs
local placeholderText
function ProfFrame:ShowPlaceholder(key)
    if not placeholderText then
        placeholderText = contentFrame:CreateFontString(nil, "OVERLAY")
        placeholderText:SetFont(ns.FONT, 14, "")
        placeholderText:SetPoint("CENTER", contentFrame, "CENTER", 0, 0)
        placeholderText:SetTextColor(unpack(ns.COLORS.mutedText))
    end
    local labels = { specs = "Specializations", orders = "Crafting Orders" }
    placeholderText:SetText((labels[key] or key) .. " — coming soon")
    placeholderText:Show()
end

function ProfFrame:HidePlaceholder()
    if placeholderText then
        placeholderText:Hide()
    end
end

function ProfFrame:GetContentFrame()
    return contentFrame
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function ProfFrame:Show()
    profOpen = true
    if not mainFrame then
        CreateMainFrame()
    end

    SuppressBlizzardProf()
    UpdateTopBar()

    -- Hide placeholder
    self:HidePlaceholder()

    -- Select Recipes tab
    if tabBar then
        tabBar:Select("recipes")
    end
    self:SelectTab("recipes")

    mainFrame:Show()
end

function ProfFrame:Hide()
    profOpen = false
    if expansionMenu then expansionMenu:Hide() end
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    end
end

function ProfFrame:IsShown()
    return mainFrame and mainFrame:IsShown()
end

function ProfFrame:IsOpen()
    return profOpen
end

--------------------------------------------------------------------
-- Refresh (called on data changes)
--------------------------------------------------------------------
function ProfFrame:Refresh()
    if not self:IsShown() then return end
    UpdateTopBar()
    -- Refresh active tab
    for _, def in ipairs(TAB_DEFS) do
        if def.key == activeTab then
            local mod = def.module()
            if mod and mod.Refresh and mod:IsShown() then
                mod:Refresh()
            end
            break
        end
    end
end

function ProfFrame:RefreshRecipeList()
    if not self:IsShown() then return end
    if activeTab == "recipes" and ns.ProfRecipes then
        ns.ProfRecipes:RefreshRecipeList()
    end
end

function ProfFrame:UpdateFooter()
    if not footer.costText then return end
    local queue = ns.Data:GetCharacterQueue()
    if #queue > 0 then
        local total = ns.Data:GetTotalCost(ns.charKey)
        if total > 0 then
            footer.costText:SetText("Materials: " .. ns.FormatGold(total))
        else
            footer.costText:SetText("Queue: " .. #queue .. " recipe(s)")
        end
    else
        footer.costText:SetText("")
    end
end

--------------------------------------------------------------------
-- Expansion tier dropdown
--------------------------------------------------------------------
local expansionMenu

function ProfFrame:ToggleExpansionMenu(anchorBtn)
    if expansionMenu and expansionMenu:IsShown() then
        expansionMenu:Hide()
        return
    end

    local childInfos = C_TradeSkillUI.GetChildProfessionInfos()
    if not childInfos or #childInfos == 0 then return end

    local currentInfo = C_TradeSkillUI.GetChildProfessionInfo()
    local currentID = currentInfo and currentInfo.professionID

    if not expansionMenu then
        expansionMenu = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
        expansionMenu:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        expansionMenu:SetBackdropColor(20/255, 20/255, 20/255, 0.98)
        expansionMenu:SetBackdropBorderColor(unpack(ns.COLORS.accent))
        expansionMenu:SetFrameStrata("DIALOG")
        expansionMenu:SetFrameLevel(300)
        expansionMenu:EnableMouse(true)
    end

    -- Clear old children
    for _, child in pairs({expansionMenu:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end

    local ROW_H = 22
    local menuWidth = 220
    local y = -4

    for _, info in ipairs(childInfos) do
        local row = CreateFrame("Button", nil, expansionMenu)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", expansionMenu, "TOPLEFT", 4, y)
        row:SetPoint("TOPRIGHT", expansionMenu, "TOPRIGHT", -4, y)

        -- Selection indicator
        local isSelected = (info.professionID == currentID)

        local indicator = row:CreateFontString(nil, "OVERLAY")
        indicator:SetFont(ns.FONT, 11, "")
        indicator:SetPoint("LEFT", row, "LEFT", 2, 0)
        indicator:SetText(isSelected and "|cffffd700o|r" or "  ")

        local nameStr = row:CreateFontString(nil, "OVERLAY")
        nameStr:SetFont(ns.FONT, 11, "")
        nameStr:SetPoint("LEFT", indicator, "RIGHT", 4, 0)
        nameStr:SetText(info.expansionName or "?")
        nameStr:SetTextColor(unpack(isSelected and ns.COLORS.brightText or ns.COLORS.mutedText))

        local skillStr = row:CreateFontString(nil, "OVERLAY")
        skillStr:SetFont(ns.FONT, 11, "")
        skillStr:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        skillStr:SetText((info.skillLevel or 0) .. "/" .. (info.maxSkillLevel or 0))
        skillStr:SetTextColor(unpack(ns.COLORS.mutedText))

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0)

        row:SetScript("OnEnter", function(self)
            self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        end)
        row:SetScript("OnLeave", function(self)
            self.bg:SetColorTexture(1, 1, 1, 0)
        end)
        row:SetScript("OnClick", function()
            expansionMenu:Hide()
            C_TradeSkillUI.SetProfessionChildSkillLineID(info.professionID)
            -- TRADE_SKILL_DATA_SOURCE_CHANGED will fire and update everything
        end)

        y = y - ROW_H
    end

    expansionMenu:SetSize(menuWidth, math.abs(y) + 4)
    expansionMenu:ClearAllPoints()
    expansionMenu:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -2)
    expansionMenu:Show()
end

--------------------------------------------------------------------
-- WoW UI toggle
--------------------------------------------------------------------
function ProfFrame:SwitchToBlizzard()
    switchingToBlizzard = true
    if mainFrame then mainFrame:Hide() end
    RestoreBlizzardProf()
    self:EnsureBlizzardSwitchButton()
end

function ProfFrame:EnsureBlizzardSwitchButton()
    if not ProfessionsFrame then return end
    if ProfessionsFrame._kazButton then return end

    local btn = ns.CreateButton(ProfessionsFrame, "KazCraft", 70, 22)
    btn:SetPoint("BOTTOMRIGHT", ProfessionsFrame, "BOTTOMRIGHT", -100, 6)
    btn:SetFrameStrata("DIALOG")
    btn:SetFrameLevel(500)
    btn:SetScript("OnClick", function()
        SuppressBlizzardProf()
        if not mainFrame then CreateMainFrame() end
        UpdateTopBar()
        ProfFrame:HidePlaceholder()
        if tabBar then tabBar:Select(activeTab or "recipes") end
        ProfFrame:SelectTab(activeTab or "recipes")
        mainFrame:Show()
    end)
    ProfessionsFrame._kazButton = btn
end

--------------------------------------------------------------------
-- Event handlers (called from Core.lua)
--------------------------------------------------------------------
function ProfFrame:OnTradeSkillShow()
    self:Show()
end

function ProfFrame:OnTradeSkillClose()
    self:Hide()
end

function ProfFrame:OnTradeSkillListUpdate()
    self:RefreshRecipeList()
end

function ProfFrame:OnTradeSkillDataSourceChanged()
    if not self:IsShown() then return end
    UpdateTopBar()
    self:RefreshRecipeList()
end

function ProfFrame:OnCraftBegin()
    if ns.ProfRecipes then
        ns.ProfRecipes:SetCrafting(true)
    end
end

function ProfFrame:OnCraftComplete()
    if ns.ProfRecipes then
        ns.ProfRecipes:SetCrafting(false)
        ns.ProfRecipes:RefreshDetail()
    end
    self:UpdateFooter()
end

function ProfFrame:OnCraftStopped()
    if ns.ProfRecipes then
        ns.ProfRecipes:SetCrafting(false)
    end
end

function ProfFrame:OnBagUpdate()
    if not self:IsShown() then return end
    if ns.ProfRecipes then
        ns.ProfRecipes:RefreshDetail()
    end
    self:UpdateFooter()
end
