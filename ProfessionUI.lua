local addonName, ns = ...

local ProfUI = {}
ns.ProfessionUI = ProfUI

local PANEL_WIDTH = 300
local QUEUE_ROW_HEIGHT = 28
local MAT_ROW_HEIGHT = 24
local MAX_QUEUE_ROWS = 10
local MAX_MAT_ROWS = 12

-- State
local mainFrame
local queueContent, matContent
local headerText
local craftBtn, clearBtn
local queueRows = {}
local matRows = {}
local selectedRecipeID = nil
local selectedRecipeName = nil

-- Quantity input


local function CreateQueueRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(QUEUE_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * QUEUE_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * QUEUE_ROW_HEIGHT)
    row:Hide()

    -- Stripe
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0)

    -- Divider
    row.divider = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", 4, 0)
    row.divider:SetPoint("BOTTOMRIGHT", -4, 0)
    row.divider:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ns.ICON_SIZE, ns.ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

    -- Name
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 11, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -90, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    row.nameText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Quantity text
    row.qtyText = row:CreateFontString(nil, "OVERLAY")
    row.qtyText:SetFont(ns.FONT, 11, "")
    row.qtyText:SetPoint("RIGHT", row, "RIGHT", -56, 0)
    row.qtyText:SetWidth(30)
    row.qtyText:SetJustifyH("CENTER")
    row.qtyText:SetTextColor(unpack(ns.COLORS.brightText))

    -- [-] button
    row.minusBtn = CreateFrame("Button", nil, row)
    row.minusBtn:SetSize(18, 18)
    row.minusBtn:SetPoint("RIGHT", row, "RIGHT", -38, 0)
    row.minusBtn.t = row.minusBtn:CreateFontString(nil, "OVERLAY")
    row.minusBtn.t:SetFont(ns.FONT, 12, "")
    row.minusBtn.t:SetPoint("CENTER")
    row.minusBtn.t:SetText("-")
    row.minusBtn.t:SetTextColor(unpack(ns.COLORS.btnDefault))
    row.minusBtn:SetScript("OnEnter", function(self) self.t:SetTextColor(unpack(ns.COLORS.btnHover)) end)
    row.minusBtn:SetScript("OnLeave", function(self) self.t:SetTextColor(unpack(ns.COLORS.btnDefault)) end)

    -- [+] button
    row.plusBtn = CreateFrame("Button", nil, row)
    row.plusBtn:SetSize(18, 18)
    row.plusBtn:SetPoint("RIGHT", row, "RIGHT", -20, 0)
    row.plusBtn.t = row.plusBtn:CreateFontString(nil, "OVERLAY")
    row.plusBtn.t:SetFont(ns.FONT, 12, "")
    row.plusBtn.t:SetPoint("CENTER")
    row.plusBtn.t:SetText("+")
    row.plusBtn.t:SetTextColor(unpack(ns.COLORS.btnDefault))
    row.plusBtn:SetScript("OnEnter", function(self) self.t:SetTextColor(unpack(ns.COLORS.btnHover)) end)
    row.plusBtn:SetScript("OnLeave", function(self) self.t:SetTextColor(unpack(ns.COLORS.btnDefault)) end)

    -- [x] button
    row.removeBtn = CreateFrame("Button", nil, row)
    row.removeBtn:SetSize(18, 18)
    row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.removeBtn.t = row.removeBtn:CreateFontString(nil, "OVERLAY")
    row.removeBtn.t:SetFont(ns.FONT, 12, "")
    row.removeBtn.t:SetPoint("CENTER")
    row.removeBtn.t:SetText("x")
    row.removeBtn.t:SetTextColor(unpack(ns.COLORS.closeDefault))
    row.removeBtn:SetScript("OnEnter", function(self) self.t:SetTextColor(unpack(ns.COLORS.closeHover)) end)
    row.removeBtn:SetScript("OnLeave", function(self) self.t:SetTextColor(unpack(ns.COLORS.closeDefault)) end)

    return row
end

local function CreateMatRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(MAT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * MAT_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * MAT_ROW_HEIGHT)
    row:Hide()

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0)

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

    -- Name
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(ns.FONT, 10, "")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -100, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    -- Have/Need
    row.countText = row:CreateFontString(nil, "OVERLAY")
    row.countText:SetFont(ns.FONT, 10, "")
    row.countText:SetPoint("RIGHT", row, "RIGHT", -50, 0)
    row.countText:SetWidth(48)
    row.countText:SetJustifyH("RIGHT")

    -- Price
    row.priceText = row:CreateFontString(nil, "OVERLAY")
    row.priceText:SetFont(ns.FONT, 10, "")
    row.priceText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.priceText:SetWidth(48)
    row.priceText:SetJustifyH("RIGHT")
    row.priceText:SetTextColor(unpack(ns.COLORS.mutedText))

    return row
end

local function CreateMainFrame()
    mainFrame = ns.CreateFlatFrame("KazCraftProfFrame", PANEL_WIDTH, 600)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetFrameLevel(100)
    mainFrame:Hide()

    -- Close button
    ns.CreateCloseButton(mainFrame)

    -- Header
    headerText = mainFrame:CreateFontString(nil, "OVERLAY")
    headerText:SetFont(ns.FONT, 12, "")
    headerText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -8)
    headerText:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -28, -8)
    headerText:SetTextColor(unpack(ns.COLORS.brightText))
    headerText:SetJustifyH("LEFT")

    -- Separator under header
    local sep = mainFrame:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -28)
    sep:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -6, -28)
    sep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    -- "Queue" label
    local queueLabel = mainFrame:CreateFontString(nil, "OVERLAY")
    queueLabel:SetFont(ns.FONT, 10, "")
    queueLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -34)
    queueLabel:SetText("QUEUE")
    queueLabel:SetTextColor(unpack(ns.COLORS.headerText))

    -- Add button row
    local addRow = CreateFrame("Frame", nil, mainFrame)
    addRow:SetHeight(26)
    addRow:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -48)
    addRow:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -6, -48)

    -- Quantity editbox
    -- Add Selected removed — use main +Queue button (Optimize → Apply → +Queue)

    -- Clear button
    clearBtn = ns.CreateButton(addRow, "Clear", 50, 22)
    clearBtn:SetPoint("LEFT", addRow, "LEFT", 2, 0)
    clearBtn:SetScript("OnClick", function()
        ns.Data:ClearQueue()
        ProfUI:RefreshAll()
    end)

    -- Queue scroll area
    local queueScroll = CreateFrame("ScrollFrame", nil, mainFrame, "UIPanelScrollFrameTemplate")
    queueScroll:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -78)
    queueScroll:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -22, -78)
    queueScroll:SetHeight(MAX_QUEUE_ROWS * QUEUE_ROW_HEIGHT)

    queueContent = CreateFrame("Frame", nil, queueScroll)
    queueContent:SetWidth(PANEL_WIDTH - 28)
    queueContent:SetHeight(1)
    queueScroll:SetScrollChild(queueContent)

    -- Create queue row pool
    for i = 1, MAX_QUEUE_ROWS do
        queueRows[i] = CreateQueueRow(queueContent, i)
    end

    -- Materials separator
    local matSepY = -78 - (MAX_QUEUE_ROWS * QUEUE_ROW_HEIGHT) - 4
    local matSep = mainFrame:CreateTexture(nil, "ARTWORK")
    matSep:SetHeight(1)
    matSep:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, matSepY)
    matSep:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -6, matSepY)
    matSep:SetColorTexture(unpack(ns.COLORS.rowDivider))

    local matLabel = mainFrame:CreateFontString(nil, "OVERLAY")
    matLabel:SetFont(ns.FONT, 10, "")
    matLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, matSepY - 4)
    matLabel:SetText("MATERIALS")
    matLabel:SetTextColor(unpack(ns.COLORS.headerText))

    -- Materials scroll area
    local matScrollY = matSepY - 18
    local matScroll = CreateFrame("ScrollFrame", nil, mainFrame, "UIPanelScrollFrameTemplate")
    matScroll:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, matScrollY)
    matScroll:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -22, matScrollY)
    matScroll:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 36)

    matContent = CreateFrame("Frame", nil, matScroll)
    matContent:SetWidth(PANEL_WIDTH - 28)
    matContent:SetHeight(1)
    matScroll:SetScrollChild(matContent)

    for i = 1, MAX_MAT_ROWS do
        matRows[i] = CreateMatRow(matContent, i)
    end

    -- Footer
    local footer = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    footer:SetHeight(32)
    footer:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 1, 1)
    footer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -1, 1)
    footer:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
    })
    footer:SetBackdropColor(unpack(ns.COLORS.footerBg))

    -- Total cost
    mainFrame.totalText = footer:CreateFontString(nil, "OVERLAY")
    mainFrame.totalText:SetFont(ns.FONT, 11, "")
    mainFrame.totalText:SetPoint("LEFT", footer, "LEFT", 8, 0)
    mainFrame.totalText:SetTextColor(unpack(ns.COLORS.mutedText))

    -- Craft Queue button — batches full qty for first entry per click
    craftBtn = ns.CreateButton(footer, "Craft Queue", 90, 22)
    craftBtn:SetPoint("RIGHT", footer, "RIGHT", -6, 0)
    craftBtn:SetScript("OnClick", function()
        local queue = ns.Data:GetCharacterQueue()
        if #queue == 0 then
            print("|cff00ccffKazCraft|r: Queue is empty.")
            return
        end
        -- Skip uncached
        while #queue > 0 do
            local entry = queue[1]
            local cached = KazCraftDB.recipeCache[entry.recipeID]
            if cached then break end
            print("|cff00ccffKazCraft|r: Recipe " .. entry.recipeID .. " not cached, skipping.")
            ns.Data:RemoveFromQueue(1)
            queue = ns.Data:GetCharacterQueue()
        end
        if #queue == 0 then
            print("|cff00ccffKazCraft|r: Queue is empty.")
            ProfUI:RefreshAll()
            return
        end

        local entry = queue[1]
        local cached = KazCraftDB.recipeCache[entry.recipeID]
        local qty = entry.quantity
        ns.lastCraftedRecipeID = entry.recipeID
        local applyConc = ns.ProfRecipes and ns.ProfRecipes.GetConcentrationChecked and ns.ProfRecipes.GetConcentrationChecked() or false

        print("|cff00ccffKazCraft|r: Crafting " .. qty .. "x " .. (cached.recipeName or "?") .. "...")
        C_TradeSkillUI.CraftRecipe(entry.recipeID, qty, {}, nil, nil, applyConc)
    end)

    -- Save/restore position
    function mainFrame:SavePosition()
        local point, _, relPoint, x, y = self:GetPoint()
        KazCraftDB.profPosition = { point, relPoint, x, y }
    end

    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SavePosition()
    end)
end

-- Refresh queue rows
function ProfUI:RefreshQueue()
    local queue = ns.Data:GetCharacterQueue()
    local count = #queue

    queueContent:SetHeight(math.max(1, count * QUEUE_ROW_HEIGHT))

    for i = 1, math.max(count, #queueRows) do
        local row = queueRows[i]
        if not row and i <= count then
            row = CreateQueueRow(queueContent, i)
            queueRows[i] = row
        end
        if row then
            if i <= count then
                local entry = queue[i]
                local cached = KazCraftDB.recipeCache[entry.recipeID]

                row.icon:SetTexture(cached and cached.icon or 134400)
                row.nameText:SetText(cached and cached.recipeName or ("Recipe " .. entry.recipeID))
                row.qtyText:SetText("x" .. entry.quantity)

                -- Wire buttons
                local idx = i
                row.minusBtn:SetScript("OnClick", function()
                    ns.Data:AdjustQuantity(idx, -1)
                    ProfUI:RefreshAll()
                end)
                row.plusBtn:SetScript("OnClick", function()
                    ns.Data:AdjustQuantity(idx, 1)
                    ProfUI:RefreshAll()
                end)
                row.removeBtn:SetScript("OnClick", function()
                    ns.Data:RemoveFromQueue(idx)
                    ProfUI:RefreshAll()
                end)

                row:Show()
            else
                row:Hide()
            end
        end
    end
end

-- Refresh material rows
function ProfUI:RefreshMaterials()
    local mats = ns.Data:GetMaterialList(ns.charKey)
    local count = #mats

    matContent:SetHeight(math.max(1, count * MAT_ROW_HEIGHT))

    for i = 1, math.max(count, #matRows) do
        local row = matRows[i]
        if not row and i <= count then
            row = CreateMatRow(matContent, i)
            matRows[i] = row
        end
        if row then
            if i <= count then
                local mat = mats[i]
                row.icon:SetTexture(mat.icon)
                row.nameText:SetText(mat.itemName)

                local haveColor = mat.have >= mat.need and ns.COLORS.greenText or ns.COLORS.redText
                if mat.soulbound then
                    row.nameText:SetTextColor(unpack(ns.COLORS.mutedText))
                    row.icon:SetDesaturated(true)
                else
                    row.nameText:SetTextColor(unpack(haveColor))
                    row.icon:SetDesaturated(false)
                end
                row.countText:SetText(mat.have .. "/" .. mat.need)
                row.countText:SetTextColor(unpack(haveColor))

                if mat.price > 0 then
                    row.priceText:SetText(ns.FormatGold(mat.price))
                else
                    row.priceText:SetText("—")
                end

                row:Show()
            else
                row:Hide()
            end
        end
    end

    -- Update total
    if mainFrame and mainFrame.totalText then
        local total = ns.Data:GetTotalCost(ns.charKey)
        if total > 0 then
            mainFrame.totalText:SetText("Cost: " .. ns.FormatGold(total))
        else
            mainFrame.totalText:SetText("")
        end
    end
end

function ProfUI:RefreshAll()
    self:RefreshQueue()
    self:RefreshMaterials()
end

function ProfUI:Show()
    if not mainFrame then
        CreateMainFrame()
    end

    -- Update header
    local charName = ns.charKey and ns.charKey:match("^(.-)%-") or "?"
    headerText:SetText("Queue — " .. (ns.currentProfName or "?"))

    -- Dock to KC's ProfFrame
    mainFrame:ClearAllPoints()
    local kcFrame = _G["KazCraftProfFrame2"]
    if kcFrame and kcFrame:IsShown() then
        mainFrame:SetPoint("TOPLEFT", kcFrame, "TOPRIGHT", 2, 0)
        mainFrame:SetHeight(kcFrame:GetHeight())
    else
        local pos = KazCraftDB.profPosition
        if pos and pos[1] then
            mainFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            mainFrame:SetPoint("CENTER")
        end
        mainFrame:SetHeight(600)
    end

    self:RefreshAll()
    mainFrame:Show()
end

function ProfUI:Hide()
    if mainFrame then
        mainFrame:Hide()
    end
end

function ProfUI:IsShown()
    return mainFrame and mainFrame:IsShown()
end

function ProfUI:SetSelectedRecipe(recipeID)
    selectedRecipeID = recipeID
    if recipeID and not KazCraftDB.recipeCache[recipeID] then
        ns.Data:CacheSchematic(recipeID, ns.currentProfName)
    end
end

-- Hook recipe selection from Blizzard's profession list
EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", function(_, recipeInfo)
    if not recipeInfo then return end
    selectedRecipeID = recipeInfo.recipeID
    selectedRecipeName = recipeInfo.name

    -- Pre-cache schematic
    if selectedRecipeID and not KazCraftDB.recipeCache[selectedRecipeID] then
        ns.Data:CacheSchematic(selectedRecipeID, ns.currentProfName)
    end
end, "KazCraft")
