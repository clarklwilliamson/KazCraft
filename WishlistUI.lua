local addonName, ns = ...

--------------------------------------------------------------------
-- KazWishlist UI: scrollable list of profession gear + consumables
--------------------------------------------------------------------

local WishlistUI = {}
ns.WishlistUI = WishlistUI

local KazGUI = LibStub("KazGUILib-1.0")

local FRAME_WIDTH = 420
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
        if self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            ns.SetTooltipItem(GameTooltip, self.itemID)
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
    row.descText:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.descText:SetJustifyH("LEFT")
    row.descText:SetWordWrap(false)

    -- Status text (right side)
    row.statusText = KazGUI:CreateText(row, KazGUI.Constants.FONT_SIZE_NORMAL, "textNormal")
    row.statusText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.statusText:SetJustifyH("RIGHT")
    row.statusText:SetWidth(70)

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

    -- Section 1: Profession Gear
    local gearNeeds = ns.Wishlist:ScanProfessionGear()
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

        displayData[#displayData + 1] = {
            type = "header",
            text = "Profession Gear",
            count = #gearNeeds .. " empty",
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

            -- Profession icon
            row.iconBtn.itemID = nil
            row.icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
            row.iconBtn:Show()

            local color = entry.classColor or "|cffffffff"
            row.charText:SetText(color .. entry.charName .. "|r")
            row.descText:SetText(entry.profession .. " " .. entry.slotName)
            row.statusText:SetText("|cffff6666Empty|r")
            row.removeBtn:Hide()
            row.removeBtn.itemID = nil
            row.bg:SetColorTexture(1, 0.4, 0.4, 0.04)
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
    })

    -- Subtitle
    mainFrame.subtitle = KazGUI:CreateText(mainFrame, KazGUI.Constants.FONT_SIZE_SMALL, "textDim")
    mainFrame.subtitle:SetPoint("TOPLEFT", mainFrame.titleBar, "BOTTOMLEFT", 10, -4)
    mainFrame.subtitle:SetPoint("TOPRIGHT", mainFrame.titleBar, "BOTTOMRIGHT", -10, -4)
    mainFrame.subtitle:SetJustifyH("LEFT")

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

    return mainFrame
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
