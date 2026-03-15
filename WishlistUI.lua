local addonName, ns = ...

--------------------------------------------------------------------
-- KazWishlist UI: scrollable list of profession gear + consumables
--------------------------------------------------------------------

local WishlistUI = {}
ns.WishlistUI = WishlistUI

local KazGUI = LibStub("KazGUILib-1.0")

local FRAME_WIDTH = 500
local FRAME_HEIGHT = 500
local ROW_HEIGHT = 26
local ICON_SIZE = 22
local SECTION_HEIGHT = 22
local HEADER_OFFSET = 40  -- title bar + subtitle

local mainFrame
local scrollFrame
local rows = {}
local sectionHeaders = {}
local displayData = {}

--------------------------------------------------------------------
-- Row creation
--------------------------------------------------------------------
local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:Hide()

    -- Stripe
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0.03)

    -- Icon
    row.iconBtn = CreateFrame("Button", nil, row)
    row.iconBtn:SetSize(ICON_SIZE, ICON_SIZE)
    row.iconBtn:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.icon = row.iconBtn:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.iconBtn:SetScript("OnEnter", function(self)
        if self.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        elseif self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            ns.SetTooltipItem(GameTooltip, self.itemID)
            GameTooltip:Show()
        elseif self.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.tooltipText, 1, 1, 1)
            if self.tooltipSub then
                GameTooltip:AddLine(self.tooltipSub, 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end
    end)
    row.iconBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- Character name (colored)
    row.charText = KazGUI:CreateText(row, KazGUI.Constants.FONT_SIZE_NORMAL, "textNormal")
    row.charText:SetPoint("LEFT", row.iconBtn, "RIGHT", 5, 0)
    row.charText:SetWidth(90)
    row.charText:SetJustifyH("LEFT")
    row.charText:SetWordWrap(false)

    -- Description
    row.descText = KazGUI:CreateText(row, KazGUI.Constants.FONT_SIZE_NORMAL, "textNormal")
    row.descText:SetPoint("LEFT", row.charText, "RIGHT", 5, 0)
    row.descText:SetPoint("RIGHT", row, "RIGHT", -120, 0)
    row.descText:SetJustifyH("LEFT")
    row.descText:SetWordWrap(false)

    -- Status text (right side)
    row.statusText = KazGUI:CreateText(row, KazGUI.Constants.FONT_SIZE_NORMAL, "textNormal")
    row.statusText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.statusText:SetJustifyH("RIGHT")
    row.statusText:SetWidth(110)

    -- Remove button (consumables only)
    row.removeBtn = CreateFrame("Button", nil, row)
    row.removeBtn:SetSize(14, 14)
    row.removeBtn:SetPoint("RIGHT", row.statusText, "LEFT", -4, 0)
    row.removeBtn:SetNormalTexture("Interface\\BUTTONS\\UI-GroupLoot-Pass-Up")
    row.removeBtn:SetHighlightTexture("Interface\\BUTTONS\\UI-GroupLoot-Pass-Highlight")
    row.removeBtn:SetScript("OnClick", function(self)
        if self.itemID then
            ns.Wishlist:RemoveConsumable(self.itemID)
            WishlistUI:Refresh()
        end
    end)
    row.removeBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove from wishlist")
        GameTooltip:Show()
    end)
    row.removeBtn:SetScript("OnLeave", GameTooltip_Hide)
    row.removeBtn:Hide()

    return row
end

local function CreateSectionHeader(parent)
    local header = CreateFrame("Frame", nil, parent)
    header:SetHeight(SECTION_HEIGHT)
    header:Hide()

    header.bg = header:CreateTexture(nil, "BACKGROUND")
    header.bg:SetAllPoints()
    header.bg:SetColorTexture(1, 1, 1, 0.06)

    header.text = KazGUI:CreateText(header, KazGUI.Constants.FONT_SIZE_NORMAL, "accent")
    header.text:SetPoint("LEFT", 8, 0)
    header.text:SetJustifyH("LEFT")

    header.countText = KazGUI:CreateText(header, KazGUI.Constants.FONT_SIZE_SMALL, "textMuted")
    header.countText:SetPoint("RIGHT", -8, 0)
    header.countText:SetJustifyH("RIGHT")

    return header
end

local rowPool = {}
local headerPool = {}

local function GetRow()
    local row = tremove(rowPool)
    if not row then
        row = CreateRow(scrollFrame.content)
    end
    return row
end

local function GetHeader()
    local header = tremove(headerPool)
    if not header then
        header = CreateSectionHeader(scrollFrame.content)
    end
    return header
end

local function ReleaseAll()
    for _, row in ipairs(rows) do
        row:Hide()
        row:ClearAllPoints()
        rowPool[#rowPool + 1] = row
    end
    wipe(rows)
    for _, header in ipairs(sectionHeaders) do
        header:Hide()
        header:ClearAllPoints()
        headerPool[#headerPool + 1] = header
    end
    wipe(sectionHeaders)
end

--------------------------------------------------------------------
-- Build display data
--------------------------------------------------------------------
local function BuildDisplayData()
    wipe(displayData)

    -- Section 1: Profession Gear (ALL characters, ALL professions — enriched with crafter info)
    local gearNeeds = ns.Wishlist:ScanProfessionGear()
    ns.Wishlist:EnrichNeedsWithCrafters(gearNeeds)

    if #gearNeeds > 0 then
        -- Group by character
        local byChar = {}
        local charOrder = {}
        for _, need in ipairs(gearNeeds) do
            if not byChar[need.charName] then
                byChar[need.charName] = {}
                charOrder[#charOrder + 1] = need.charName
            end
            byChar[need.charName][#byChar[need.charName] + 1] = need
        end
        table.sort(charOrder)

        local emptyCount = 0
        local outdatedCount = 0
        local upgradeCount = 0
        local craftableCount = 0
        for _, need in ipairs(gearNeeds) do
            if need.currentQuality == 0 then
                emptyCount = emptyCount + 1
            elseif need.outdated then
                outdatedCount = outdatedCount + 1
            else
                upgradeCount = upgradeCount + 1
            end
            if need.craftable then craftableCount = craftableCount + 1 end
        end
        local countParts = {}
        if emptyCount > 0 then countParts[#countParts + 1] = emptyCount .. " empty" end
        if outdatedCount > 0 then countParts[#countParts + 1] = outdatedCount .. " outdated" end
        if upgradeCount > 0 then countParts[#countParts + 1] = upgradeCount .. " upgrade" end
        if craftableCount > 0 then countParts[#countParts + 1] = craftableCount .. " craftable" end

        local targetQ = ns.Wishlist:GetTargetQuality()
        displayData[#displayData + 1] = {
            type = "header",
            text = "Profession Gear → " .. ns.Wishlist:GetQualityColor(targetQ) .. ns.Wishlist:GetQualityName(targetQ) .. "|r",
            count = table.concat(countParts, ", "),
        }
        for _, charName in ipairs(charOrder) do
            for _, need in ipairs(byChar[charName]) do
                displayData[#displayData + 1] = {
                    type = "gear",
                    charName = charName,
                    classColor = need.classColor,
                    profession = need.profession,
                    slotName = need.slotName,
                    slotID = need.slotID,
                    currentQuality = need.currentQuality or 0,
                    currentItemName = need.currentItemName,
                    currentItemLink = need.currentItemLink,
                    outdated = need.outdated,
                    craftable = need.craftable,
                    crafterText = need.crafterText,
                    bestCrafter = need.bestCrafter,
                }
            end
        end
    end

    -- Section 2: Consumables
    local consumables = ns.Wishlist:ScanConsumables()
    if #consumables > 0 then
        local needCount = 0
        for _, c in ipairs(consumables) do
            if c.need > 0 then needCount = needCount + 1 end
        end

        displayData[#displayData + 1] = {
            type = "header",
            text = "Consumables",
            count = needCount > 0 and (needCount .. " needed") or "all stocked",
        }
        for _, c in ipairs(consumables) do
            displayData[#displayData + 1] = {
                type = "consumable",
                itemID = c.itemID,
                itemName = c.itemName,
                icon = c.icon,
                target = c.target,
                have = c.have,
                need = c.need,
            }
        end
    end

    return displayData
end

--------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------
function WishlistUI:Refresh()
    if not mainFrame or not mainFrame:IsShown() then return end

    ReleaseAll()
    BuildDisplayData()

    -- Update content width to match scroll frame (handles resize)
    scrollFrame.content:SetWidth(scrollFrame:GetWidth())

    local yOffset = 0
    for _, entry in ipairs(displayData) do
        if entry.type == "header" then
            local header = GetHeader()
            header:SetParent(scrollFrame.content)
            header:SetPoint("TOPLEFT", scrollFrame.content, "TOPLEFT", 0, -yOffset)
            header:SetPoint("RIGHT", scrollFrame.content, "RIGHT", 0, 0)
            header.text:SetText(entry.text)
            header.countText:SetText(entry.count or "")
            header:Show()
            sectionHeaders[#sectionHeaders + 1] = header
            yOffset = yOffset + SECTION_HEIGHT

        elseif entry.type == "gear" then
            local row = GetRow()
            row:SetParent(scrollFrame.content)
            row:SetPoint("TOPLEFT", scrollFrame.content, "TOPLEFT", 0, -yOffset)
            row:SetPoint("RIGHT", scrollFrame.content, "RIGHT", 0, 0)

            -- Icon: show equipped item icon if available, else generic gear
            row.iconBtn.itemID = nil
            row.iconBtn.itemLink = entry.currentItemLink or nil
            row.iconBtn.tooltipText = entry.profession .. " " .. entry.slotName
            row.iconBtn.tooltipSub = entry.currentItemName and ("Equipped: " .. entry.currentItemName) or "Empty slot"
            if entry.currentItemLink then
                local icon = C_Item.GetItemIconByID(entry.currentItemLink)
                row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_Gear_01")
            else
                row.icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
            end
            row.iconBtn:Show()

            local color = entry.classColor or "|cffffffff"
            row.charText:SetText(color .. entry.charName .. "|r")

            -- Description: profession slot + current item
            local cq = entry.currentQuality or 0
            local descParts = { entry.profession .. " " .. entry.slotName }
            if cq > 0 and entry.currentItemName then
                local qColor = ns.Wishlist:GetQualityColor(cq)
                descParts[#descParts + 1] = " [" .. qColor .. entry.currentItemName .. "|r]"
            end
            row.descText:SetText(table.concat(descParts))

            -- Status: quality state + crafter
            local crafterSuffix = ""
            if entry.craftable and entry.bestCrafter then
                crafterSuffix = " → " .. (entry.bestCrafter:match("^(.-)%-") or entry.bestCrafter)
            end

            if cq == 0 then
                row.statusText:SetText("|cffff6666Empty|r" .. crafterSuffix)
            elseif entry.outdated then
                row.statusText:SetText("|cffff9900TWW|r" .. crafterSuffix)
            else
                local qColor = ns.Wishlist:GetQualityColor(cq)
                local qName = ns.Wishlist:GetQualityName(cq)
                row.statusText:SetText(qColor .. qName .. "|r" .. crafterSuffix)
            end

            -- Tooltip with full crafter list on hover
            row:SetScript("OnEnter", function(self)
                if entry.crafterText then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(entry.profession .. " " .. entry.slotName, 1, 1, 1)
                    if entry.currentItemName then
                        local cqLocal = entry.currentQuality or 0
                        local qcLocal = ns.Wishlist:GetQualityColor(cqLocal)
                        GameTooltip:AddLine("Equipped: " .. (entry.currentItemName or "None"), 0.8, 0.8, 0.8)
                    else
                        GameTooltip:AddLine("Equipped: None", 0.5, 0.5, 0.5)
                    end
                    GameTooltip:AddLine("Crafters: " .. entry.crafterText, 0.7, 0.85, 1.0)
                    GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", GameTooltip_Hide)

            row.removeBtn:Hide()
            row.removeBtn.itemID = nil
            row.bg:SetColorTexture(entry.craftable and 0.3 or 1, entry.craftable and 0.6 or 0.4, entry.craftable and 0.3 or 0.4, 0.04)
            row:Show()
            rows[#rows + 1] = row
            yOffset = yOffset + ROW_HEIGHT

        elseif entry.type == "consumable" then
            local row = GetRow()
            row:SetParent(scrollFrame.content)
            row:SetPoint("TOPLEFT", scrollFrame.content, "TOPLEFT", 0, -yOffset)
            row:SetPoint("RIGHT", scrollFrame.content, "RIGHT", 0, 0)

            row.iconBtn:Show()
            row.iconBtn.itemID = entry.itemID
            row.icon:SetTexture(entry.icon)

            row.charText:SetText("")
            row.descText:SetPoint("LEFT", row.iconBtn, "RIGHT", 5, 0)
            row.descText:SetText(entry.itemName)

            if entry.need > 0 then
                row.statusText:SetText(string.format("|cffff6666%d|r / %d", entry.have, entry.target))
                row.bg:SetColorTexture(1, 0.4, 0.4, 0.04)
            else
                row.statusText:SetText(string.format("|cff00ff00%d|r / %d", entry.have, entry.target))
                row.bg:SetColorTexture(0.4, 1, 0.4, 0.04)
            end

            row.removeBtn:Show()
            row.removeBtn.itemID = entry.itemID
            row:Show()
            rows[#rows + 1] = row
            yOffset = yOffset + ROW_HEIGHT
        end
    end

    scrollFrame.content:SetHeight(math.max(yOffset, 1))

    -- Update subtitle
    local gearNeeds = 0
    local consumableNeeds = 0
    for _, entry in ipairs(displayData) do
        if entry.type == "gear" then gearNeeds = gearNeeds + 1 end
        if entry.type == "consumable" and entry.need > 0 then consumableNeeds = consumableNeeds + 1 end
    end
    local parts = {}
    if gearNeeds > 0 then parts[#parts + 1] = gearNeeds .. " gear" end
    if consumableNeeds > 0 then parts[#parts + 1] = consumableNeeds .. " consumables" end
    if #parts > 0 then
        mainFrame.subtitle:SetText(table.concat(parts, ", ") .. " needed")
    else
        mainFrame.subtitle:SetText("Everything stocked!")
    end
end

--------------------------------------------------------------------
-- Create the main frame
--------------------------------------------------------------------
local function CreateMainFrame()
    mainFrame = KazGUI:CreateFrame("KazWishlistFrame", FRAME_WIDTH, FRAME_HEIGHT, {
        title = "KazWishlist",
        strata = "HIGH",
        escClose = true,
        resizable = true,
        minSize = { 400, 300 },
        onResize = function()
            WishlistUI:Refresh()
            -- Save size
            local w, h = mainFrame:GetSize()
            KazCraftDB.wishSize = { w, h }
        end,
    })

    -- Subtitle
    mainFrame.subtitle = KazGUI:CreateText(mainFrame, KazGUI.Constants.FONT_SIZE_SMALL, "textDim")
    mainFrame.subtitle:SetPoint("TOPLEFT", mainFrame.titleBar, "BOTTOMLEFT", 10, -4)
    mainFrame.subtitle:SetJustifyH("LEFT")

    -- Quality toggle buttons (right side of subtitle row)
    local QUALITY_OPTS = {
        { quality = 2, label = "Green",  color = {0.12, 1.0, 0.0} },
        { quality = 3, label = "Blue",   color = {0.0, 0.44, 0.87} },
        { quality = 4, label = "Epic",   color = {0.64, 0.21, 0.93} },
    }

    mainFrame.qualityBtns = {}
    local prevBtn
    for i, opt in ipairs(QUALITY_OPTS) do
        local btn = CreateFrame("Button", nil, mainFrame)
        btn:SetSize(44, 16)
        btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.label:SetAllPoints()
        btn.label:SetText(opt.label)

        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()

        btn.quality = opt.quality
        btn.optColor = opt.color

        btn:SetScript("OnClick", function(self)
            ns.Wishlist:SetTargetQuality(self.quality)
            WishlistUI:UpdateQualityButtons()
            WishlistUI:Refresh()
        end)

        if i == 1 then
            btn:SetPoint("RIGHT", mainFrame.titleBar, "BOTTOMRIGHT", -10, -12)
        else
            btn:SetPoint("RIGHT", prevBtn, "LEFT", -4, 0)
        end

        mainFrame.qualityBtns[i] = btn
        prevBtn = btn
    end

    -- Scroll frame
    scrollFrame = KazGUI:CreateClassicScrollFrame(mainFrame, HEADER_OFFSET, 28)

    -- Queue button
    mainFrame.queueBtn = KazGUI:CreateButton(mainFrame, "Queue Craftable", 120, nil, function()
        local count = ns.Wishlist:QueueCraftable()
        if count > 0 then
            WishlistUI:Refresh()
        end
    end)
    mainFrame.queueBtn:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 6)

    -- Footer / drop hint
    mainFrame.footer = KazGUI:CreateText(mainFrame, KazGUI.Constants.FONT_SIZE_SMALL, "textDim")
    mainFrame.footer:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 10, 10)
    mainFrame.footer:SetPoint("BOTTOMRIGHT", mainFrame.queueBtn, "BOTTOMLEFT", -8, 0)
    mainFrame.footer:SetJustifyH("LEFT")
    mainFrame.footer:SetText("Drop item to add")

    -- Accept item drops on the whole frame
    mainFrame:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            local cursorType, itemID = GetCursorInfo()
            if cursorType == "item" and itemID then
                ns.Wishlist:AddConsumable(itemID, 1)
                ClearCursor()
                WishlistUI:Refresh()
            end
        end
    end)
    mainFrame:SetScript("OnReceiveDrag", function()
        local cursorType, itemID = GetCursorInfo()
        if cursorType == "item" and itemID then
            ns.Wishlist:AddConsumable(itemID, 1)
            ClearCursor()
            WishlistUI:Refresh()
        end
    end)

    mainFrame:SetScript("OnShow", function()
        WishlistUI:UpdateQualityButtons()
        WishlistUI:Refresh()
    end)

    -- Save/restore position
    mainFrame._savePosition = function()
        local point, _, relPoint, x, y = mainFrame:GetPoint()
        KazCraftDB.wishPosition = { point, relPoint, x, y }
    end

    if KazCraftDB and KazCraftDB.wishPosition then
        local pos = KazCraftDB.wishPosition
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end

    -- Restore saved size
    if KazCraftDB and KazCraftDB.wishSize then
        local sz = KazCraftDB.wishSize
        mainFrame:SetSize(sz[1], sz[2])
    end

    return mainFrame
end

--------------------------------------------------------------------
-- Quality button highlight
--------------------------------------------------------------------
function WishlistUI:UpdateQualityButtons()
    if not mainFrame or not mainFrame.qualityBtns then return end
    local targetQ = ns.Wishlist:GetTargetQuality()
    for _, btn in ipairs(mainFrame.qualityBtns) do
        if btn.quality == targetQ then
            btn.bg:SetColorTexture(btn.optColor[1], btn.optColor[2], btn.optColor[3], 0.25)
            btn.label:SetTextColor(btn.optColor[1], btn.optColor[2], btn.optColor[3])
        else
            btn.bg:SetColorTexture(1, 1, 1, 0.04)
            btn.label:SetTextColor(0.5, 0.5, 0.5)
        end
    end
end

--------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------
function WishlistUI:Toggle()
    if not mainFrame then
        CreateMainFrame()
    end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
    end
end

function WishlistUI:IsShown()
    return mainFrame and mainFrame:IsShown()
end
