local addonName, ns = ...

local ProfFrame = {}
ns.ProfFrame = ProfFrame

local FRAME_WIDTH = 960
local FRAME_HEIGHT = 620
local MIN_WIDTH, MIN_HEIGHT = 750, 500
local MAX_WIDTH, MAX_HEIGHT = 1400, 1000
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
local switchingToKazCraft = false

-- Tab definitions
local TAB_DEFS = {
    { key = "recipes", label = "Recipes", module = function() return ns.ProfRecipes end },
    { key = "specs",   label = "Specializations", module = function() return ns.ProfSpecs end },
    { key = "orders",  label = "Crafting Orders", module = function() return ns.ProfOrders end },
}

--------------------------------------------------------------------
-- Blizzard ProfessionsFrame suppression
-- UIParent:UnregisterEvent("TRADE_SKILL_SHOW") is done in Core.lua
-- ADDON_LOADED so Blizzard never auto-shows ProfessionsFrame.
-- When switching to Blizzard UI, manually call UIParent_OnEvent().
--------------------------------------------------------------------
local function RestoreBlizzardProf()
    -- Manually trigger Blizzard's handler to load + show ProfessionsFrame
    if ProfessionsFrame_LoadUI then ProfessionsFrame_LoadUI() end
    UIParent_OnEvent(UIParent, "TRADE_SKILL_SHOW")
end

--------------------------------------------------------------------
-- Top bar — profession icon, name, skill bar, KP, WoW UI, close
--------------------------------------------------------------------
local function UpdateTopBar()
    if not topBar.nameText then return end
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    if not profInfo or not profInfo.professionName or profInfo.professionName == "" then return end

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

    -- Concentration
    topBar.concText:ClearAllPoints()
    if topBar.kpText:IsShown() then
        topBar.concText:SetPoint("LEFT", topBar.kpText, "RIGHT", 12, 0)
    else
        topBar.concText:SetPoint("LEFT", topBar.expBtn, "RIGHT", 12, 0)
    end
    if skillLineID and C_TradeSkillUI.GetConcentrationCurrencyID then
        local concCurrID = C_TradeSkillUI.GetConcentrationCurrencyID(skillLineID)
        if concCurrID and concCurrID ~= 0 then
            local currInfo = C_CurrencyInfo.GetCurrencyInfo(concCurrID)
            if currInfo then
                topBar.concText:SetText("Conc: " .. currInfo.quantity .. "/" .. currInfo.maxQuantity)
                topBar.concText:Show()
            else
                topBar.concText:Hide()
            end
        else
            topBar.concText:Hide()
        end
    else
        topBar.concText:Hide()
    end
end

local function CreateTopBar(parent)
    -- Icon
    topBar.icon = parent:CreateTexture(nil, "ARTWORK")
    topBar.icon:SetSize(22, 22)
    topBar.icon:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -5)

    -- Profession name
    topBar.nameText = parent:CreateFontString(nil, "OVERLAY")
    topBar.nameText:SetFont(ns.FONT, 14, "")
    topBar.nameText:SetPoint("LEFT", topBar.icon, "RIGHT", 6, 0)
    topBar.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Skill level text
    topBar.skillText = parent:CreateFontString(nil, "OVERLAY")
    topBar.skillText:SetFont(ns.FONT, 14, "")
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
    topBar.expBtnText:SetFont(ns.FONT, 14, "")
    topBar.expBtnText:SetPoint("LEFT", topBar.expBtn, "LEFT", 0, 0)
    topBar.expBtnText:SetTextColor(unpack(ns.COLORS.tabInactive))

    topBar.expBtnArrow = topBar.expBtn:CreateFontString(nil, "OVERLAY")
    topBar.expBtnArrow:SetFont(ns.FONT, 12, "")
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
    topBar.kpText:SetFont(ns.FONT, 14, "")
    topBar.kpText:SetPoint("LEFT", topBar.expBtn, "RIGHT", 12, 0)
    topBar.kpText:SetTextColor(unpack(ns.COLORS.goldText))

    -- Concentration text
    topBar.concText = parent:CreateFontString(nil, "OVERLAY")
    topBar.concText:SetFont(ns.FONT, 14, "")
    topBar.concText:SetPoint("LEFT", topBar.kpText, "RIGHT", 12, 0)
    topBar.concText:SetTextColor(0.9, 0.7, 0.2)

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
    ns.ApplyBgOnly(f, "footerBg")

    -- Materials cost
    footer.costText = f:CreateFontString(nil, "OVERLAY")
    footer.costText:SetFont(ns.FONT, 14, "")
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
        local applyConc = ns.ProfRecipes and ns.ProfRecipes.GetConcentrationChecked and ns.ProfRecipes.GetConcentrationChecked() or false
        C_TradeSkillUI.CraftRecipe(entry.recipeID, 1, {}, nil, nil, applyConc)
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
-- Crafting table proximity — color orders tab red/white
--------------------------------------------------------------------
local nearCraftingTable = false
local proximityTimer = 0
local PROXIMITY_INTERVAL = 0.75

local function UpdateOrdersTabColor()
    if not tabBar or not tabBar.buttons then return end
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    local profession = profInfo and profInfo.profession
    local near = false
    if profession and C_TradeSkillUI.IsNearProfessionSpellFocus then
        local ok, result = pcall(C_TradeSkillUI.IsNearProfessionSpellFocus, profession)
        near = ok and result or false
    end
    nearCraftingTable = near

    for _, btn in ipairs(tabBar.buttons) do
        if btn.key == "orders" then
            if tabBar.activeKey == "orders" then
                if near then
                    btn.label:SetTextColor(unpack(ns.COLORS.accent))
                else
                    btn.label:SetTextColor(0.8, 0.2, 0.2)
                end
            else
                if near then
                    btn.label:SetTextColor(unpack(ns.COLORS.tabInactive))
                else
                    btn.label:SetTextColor(0.6, 0.15, 0.15)
                end
            end
            break
        end
    end
end

local function OnProximityUpdate(self, elapsed)
    proximityTimer = proximityTimer + elapsed
    if proximityTimer < PROXIMITY_INTERVAL then return end
    proximityTimer = 0
    UpdateOrdersTabColor()
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

    -- Profession equipment slots (left of WoW UI button, recipe tab only)
    local EQUIP_SIZE = 20
    local EQUIP_GAP = 3
    local equipSlots = {}  -- list of slot frames

    local function GetProfessionSlotIDs()
        local info = C_TradeSkillUI.GetChildProfessionInfo()
        if not info or not info.profession then
            local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
            if baseInfo and baseInfo.profession then
                info = baseInfo
            else
                return {}
            end
        end
        return C_TradeSkillUI.GetProfessionSlots(info.profession)
    end

    local function CreateEquipSlot(index)
        local f = CreateFrame("Button", nil, mainFrame, "BackdropTemplate")
        f:SetSize(EQUIP_SIZE, EQUIP_SIZE)
        f:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        f:SetBackdropColor(0.06, 0.06, 0.06, 0.9)
        f:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetSize(EQUIP_SIZE - 4, EQUIP_SIZE - 4)
        f.icon:SetPoint("CENTER")

        f.qualityPip = f:CreateTexture(nil, "OVERLAY", nil, 2)
        f.qualityPip:SetSize(12, 12)
        f.qualityPip:SetPoint("TOPLEFT", f, "TOPLEFT", -3, 3)
        f.qualityPip:Hide()

        f.slotID = nil

        f:SetScript("OnEnter", function(self)
            if not self.slotID then return end
            -- Suppress equip compare tooltip
            local oldCompare = GetCVarBool("alwaysCompareItems")
            SetCVar("alwaysCompareItems", 0)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetInventoryItem("player", self.slotID)
            ShoppingTooltip1:Hide()
            ShoppingTooltip2:Hide()
            GameTooltip:Show()
            SetCVar("alwaysCompareItems", oldCompare and 1 or 0)
            self:SetBackdropBorderColor(unpack(ns.COLORS.accent))
        end)
        f:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            ShoppingTooltip1:Hide()
            ShoppingTooltip2:Hide()
            self:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
        end)

        return f
    end

    -- Create 3 slots (max possible), show/hide as needed
    for i = 1, 3 do
        equipSlots[i] = CreateEquipSlot(i)
    end

    function ProfFrame:UpdateEquipmentSlots()
        local slotIDs = GetProfessionSlotIDs()
        for i = 1, 3 do
            local slot = equipSlots[i]
            local invSlot = slotIDs[i]
            if invSlot then
                slot.slotID = invSlot
                local tex = GetInventoryItemTexture("player", invSlot)
                if tex then
                    slot.icon:SetTexture(tex)
                    slot.icon:SetDesaturated(false)
                    slot.icon:SetAlpha(1)
                    -- Quality pip from equipped item
                    local link = GetInventoryItemLink("player", invSlot)
                    local qualityInfo = link and C_TradeSkillUI.GetItemCraftedQualityInfo(link) or nil
                    if qualityInfo and qualityInfo.iconSmall then
                        slot.qualityPip:SetAtlas(qualityInfo.iconSmall, false)
                        slot.qualityPip:Show()
                    else
                        slot.qualityPip:Hide()
                    end
                else
                    slot.icon:SetTexture(134400)  -- question mark
                    slot.icon:SetDesaturated(true)
                    slot.icon:SetAlpha(0.3)
                    slot.qualityPip:Hide()
                end
                slot:ClearAllPoints()
                slot:SetPoint("RIGHT", wowBtn, "LEFT", -(EQUIP_GAP + (i - 1) * (EQUIP_SIZE + EQUIP_GAP)), 0)
                slot:Show()
            else
                slot:Hide()
            end
        end
    end

    function ProfFrame:ShowEquipmentSlots()
        self:UpdateEquipmentSlots()
    end

    function ProfFrame:HideEquipmentSlots()
        for i = 1, 3 do equipSlots[i]:Hide() end
    end

    -- ESC key support
    table.insert(UISpecialFrames, "KazCraftProfFrame2")
    mainFrame:SetScript("OnHide", function()
        if switchingToBlizzard then
            switchingToBlizzard = false
            return
        end
        -- ESC key path: mainFrame:Hide() fires OnHide directly (not via ProfFrame:Hide)
        -- Close the profession if still open
        if profOpen then
            profOpen = false
            userClosedThisFrame = true
            C_Timer.After(0, function() userClosedThisFrame = false end)
            C_TradeSkillUI.CloseTradeSkill()
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

    -- Hook orders tab OnLeave to maintain red color when not near table
    for _, btn in ipairs(tabBar.buttons) do
        if btn.key == "orders" then
            btn:HookScript("OnLeave", function()
                UpdateOrdersTabColor()
            end)
            break
        end
    end

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
            end
            break
        end
    end

    -- Equipment slots: recipe tab only
    if key == "recipes" then
        self:ShowEquipmentSlots()
    else
        self:HideEquipmentSlots()
    end

    -- Re-apply orders tab color (Select() resets all tab colors)
    UpdateOrdersTabColor()
end


function ProfFrame:GetContentFrame()
    return contentFrame
end

function ProfFrame:IsNearCraftingTable()
    return nearCraftingTable
end

--------------------------------------------------------------------
-- Show / Hide
--------------------------------------------------------------------
function ProfFrame:Show()
    profOpen = true
    if not mainFrame then
        CreateMainFrame()
    end

    ns.DebugLog("ProfFrame:Show — prof:", ns.currentProfName)
    UpdateTopBar()

    -- Select Recipes tab (clean slate on profession open)
    if tabBar then
        tabBar:Select("recipes")
    end
    self:SelectTab("recipes")

    -- Start proximity polling for orders tab color
    proximityTimer = 0
    UpdateOrdersTabColor()
    mainFrame:SetScript("OnUpdate", OnProximityUpdate)

    mainFrame:Show()

    -- Show queue panel docked to our right
    if ns.ProfessionUI then
        ns.ProfessionUI:Show()
    end
end

function ProfFrame:Hide()
    if mainFrame then
        mainFrame:SetScript("OnUpdate", nil)
    end
    if expansionMenu then expansionMenu:Hide() end
    if ns.ProfessionUI then
        ns.ProfessionUI:Hide()
    end
    -- Close the trade skill BEFORE setting profOpen = false
    -- (OnHide checks profOpen to decide whether to call CloseTradeSkill)
    if profOpen then
        profOpen = false
        userClosedThisFrame = true
        C_Timer.After(0, function() userClosedThisFrame = false end)
        C_TradeSkillUI.CloseTradeSkill()
    end
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

function ProfFrame:RefreshRecipeList(resetScroll)
    if not self:IsShown() then return end
    if activeTab == "recipes" and ns.ProfRecipes then
        ns.ProfRecipes:RefreshRecipeList(resetScroll)
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
        indicator:SetFont(ns.FONT, 14, "")
        indicator:SetPoint("LEFT", row, "LEFT", 2, 0)
        indicator:SetText(isSelected and "|cffffd700o|r" or "  ")

        local nameStr = row:CreateFontString(nil, "OVERLAY")
        nameStr:SetFont(ns.FONT, 14, "")
        nameStr:SetPoint("LEFT", indicator, "RIGHT", 4, 0)
        nameStr:SetText(info.expansionName or "?")
        nameStr:SetTextColor(unpack(isSelected and ns.COLORS.brightText or ns.COLORS.mutedText))

        local skillStr = row:CreateFontString(nil, "OVERLAY")
        skillStr:SetFont(ns.FONT, 14, "")
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
            ns.DebugLog("Expansion switch →", info.expansionName, "profID:", info.professionID)
            -- Immediate visual feedback — server hasn't responded yet but update what we can
            if topBar.expBtnText then
                topBar.expBtnText:SetText(info.expansionName or "?")
                topBar.expBtn:SetWidth(topBar.expBtnText:GetStringWidth() + topBar.expBtnArrow:GetStringWidth() + 8)
            end
            if topBar.nameText then
                topBar.nameText:SetText((info.expansionName or "") .. " " .. (ns.currentProfName or ""))
            end
            -- Load cached recipe list for instant visual swap (server refresh overwrites on arrival)
            if ns.ProfRecipes then
                ns.ProfRecipes:LoadCachedRecipeList(info.professionID)
            end
            C_TradeSkillUI.SetProfessionChildSkillLineID(info.professionID)
            -- DATA_SOURCE_CHANGED + TRADE_SKILL_LIST_UPDATE fire after server responds with full refresh
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
    profOpen = false
    if mainFrame then mainFrame:Hide() end
    RestoreBlizzardProf()  -- manually triggers UIParent_OnEvent to show Blizzard frame
    self:EnsureBlizzardSwitchButton()
end

function ProfFrame:EnsureBlizzardSwitchButton()
    if not ProfessionsFrame then return end
    if ProfessionsFrame._kazButton then return end

    local btn = ns.CreateButton(ProfessionsFrame, "KazCraft", 70, 22)
    btn:SetPoint("TOPRIGHT", ProfessionsFrame, "TOPRIGHT", -100, -1)
    btn:SetFrameStrata("DIALOG")
    btn:SetFrameLevel(500)
    btn:SetScript("OnClick", function()
        -- Dev mode: don't hide Blizzard frame (CraftSim windows depend on it)
        -- Just show KazCraft on top
        ProfFrame:Show()
    end)
    ProfessionsFrame._kazButton = btn
end

--------------------------------------------------------------------
-- Event handlers (called from Core.lua)
--------------------------------------------------------------------
-- Track whether SHOW just fired this frame (for switch detection in CLOSE)
local showFiredThisFrame = false
-- Guard: when user explicitly closes, ignore TRADE_SKILL_SHOW for the rest of the frame
local userClosedThisFrame = false

function ProfFrame:OnTradeSkillShow(newProfInfo)
    -- If user just clicked close, don't reopen in the same frame
    if userClosedThisFrame then return end

    -- Mark that SHOW fired — CLOSE in the same frame is a switch, not a close
    showFiredThisFrame = true
    C_Timer.After(0, function() showFiredThisFrame = false end)

    ns.currentProfInfo = newProfInfo
    ns.currentProfName = newProfInfo and newProfInfo.professionName or "Unknown"
    self:Show()
end

function ProfFrame:OnTradeSkillClose()
    if switchingToKazCraft then return end
    -- Switching profs fires SHOW (new) then CLOSE (old) in the same frame.
    -- If SHOW already fired, this CLOSE is for the old profession — ignore.
    if showFiredThisFrame then return end
    self:Hide()
end

function ProfFrame:OnTradeSkillListUpdate()
    if not self:IsShown() then return end
    -- LIST_UPDATE fires after server sends the full recipe list (e.g. after expansion switch).
    -- Update top bar here too — GetChildProfessionInfo is now accurate.
    UpdateTopBar()
    self:RefreshRecipeList()
end

function ProfFrame:OnTradeSkillDataSourceChanged()
    if not self:IsShown() then return end
    ns.DebugLog("DATA_SOURCE_CHANGED — activeTab:", activeTab, "prof:", ns.currentProfName)
    UpdateTopBar()
    self:UpdateEquipmentSlots()
    -- Full refresh of active tab — profession or expansion changed
    if activeTab == "recipes" then
        if ns.ProfRecipes then
            ns.ProfRecipes:RefreshRecipeList(true)
            ns.ProfRecipes:RefreshDetail()
        end
    elseif activeTab == "specs" then
        if ns.ProfSpecs then
            ns.ProfSpecs:Show()  -- re-checks HasSpecialization, re-renders tree
        end
    elseif activeTab == "orders" then
        if ns.ProfOrders and ns.ProfOrders.Refresh then
            ns.ProfOrders:Refresh()
        end
    end
    UpdateOrdersTabColor()
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
    UpdateTopBar()
    self:UpdateFooter()
end

function ProfFrame:OnCraftStopped()
    if ns.ProfRecipes then
        local wasCrafting = ns.ProfRecipes:IsCrafting()
        ns.ProfRecipes:SetCrafting(false)
        ns.ProfRecipes:RefreshDetail()
        -- Flash "Craft failed" if we were actually in the middle of crafting
        if wasCrafting then
            ns.ProfRecipes:ShowCraftFailed()
        end
    end
    UpdateTopBar()
    self:UpdateFooter()
end

function ProfFrame:OnBagUpdate()
    if not self:IsShown() then return end
    if ns.ProfRecipes then
        ns.ProfRecipes:RefreshDetail()
    end
    self:UpdateFooter()
end
