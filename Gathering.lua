local addonName, ns = ...

local Gathering = {}
ns.Gathering = Gathering

local KazGUI = LibStub("KazGUILib-1.0")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local FRAME_WIDTH = 350
local FRAME_HEIGHT = 400
local ROW_HEIGHT = 24
local ICON_SIZE = 20
local BAR_HEIGHT = 4
local HEADER_OFFSET = 60  -- title bar + subtitle + checkbox area

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local mainFrame
local scrollFrame
local rows = {}
local showCompleted = false
local materialData = {}

--------------------------------------------------------------------------------
-- Row pool
--------------------------------------------------------------------------------
local function CreateMaterialRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
    row:Hide()

    -- Stripe
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0)

    -- Icon (button for tooltip)
    row.iconBtn = CreateFrame("Button", nil, row)
    row.iconBtn:SetSize(ICON_SIZE, ICON_SIZE)
    row.iconBtn:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.icon = row.iconBtn:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.iconBtn:SetScript("OnEnter", function(self)
        if self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end
    end)
    row.iconBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- Item name
    row.nameText = KazGUI:CreateText(row, KazGUI.Constants.FONT_SIZE_NORMAL, "textNormal")
    row.nameText:SetPoint("LEFT", row.iconBtn, "RIGHT", 5, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -100, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    -- Count text (have/need)
    row.countText = KazGUI:CreateText(row, KazGUI.Constants.FONT_SIZE_NORMAL, "textNormal")
    row.countText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.countText:SetJustifyH("RIGHT")
    row.countText:SetWidth(90)

    -- Progress bar background
    row.barBg = row:CreateTexture(nil, "ARTWORK", nil, 0)
    row.barBg:SetHeight(BAR_HEIGHT)
    row.barBg:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 1)
    row.barBg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 1)
    row.barBg:SetColorTexture(1, 1, 1, 0.06)

    -- Progress bar fill
    row.barFill = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.barFill:SetHeight(BAR_HEIGHT)
    row.barFill:SetPoint("BOTTOMLEFT", row.barBg, "BOTTOMLEFT")
    row.barFill:SetTexture("Interface\\BUTTONS\\WHITE8X8")

    return row
end

local function GetRow(index)
    if not rows[index] then
        rows[index] = CreateMaterialRow(scrollFrame.content, index)
    end
    return rows[index]
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------
local function RefreshGatheringList()
    if not mainFrame or not mainFrame:IsShown() then return end

    materialData = ns.Data:GetMaterialList()

    -- Rebuild item→recipe index fresh (account-wide recipeCache may have grown)
    ns.Data:BuildItemToRecipeIndex()

    -- Classify each mat as crafted or raw (single pass)
    local rawMats = {}  -- all raw materials
    local filtered = {} -- raw mats respecting showCompleted toggle
    for _, mat in ipairs(materialData) do
        local isCrafted = ns.itemToRecipe and ns.itemToRecipe[mat.itemID]
        -- Secondary check: item subclass "Parts" (1) under Trade Goods (7) = always crafted
        if not isCrafted then
            local _, _, _, _, _, _, _, _, _, _, _, classID, subclassID = C_Item.GetItemInfo(mat.itemID)
            if classID == 7 and subclassID == 1 then
                isCrafted = true
            end
        end
        -- Also skip BoP items — can't farm those on an alt
        if not isCrafted and not mat.soulbound then
            table.insert(rawMats, mat)
            if showCompleted or mat.short > 0 then
                table.insert(filtered, mat)
            end
        end
    end

    -- Stats for subtitle
    local totalItems = #rawMats
    local remaining = 0
    for _, mat in ipairs(rawMats) do
        if mat.short > 0 then remaining = remaining + 1 end
    end
    local chars = ns.Data:GetQueuedCharacters()

    if totalItems == 0 then
        mainFrame.subtitle:SetText("|cff" .. "968a6e" .. "No crafts queued.|r")
    elseif remaining == 0 then
        mainFrame.subtitle:SetText("|cff66cc66All materials gathered!|r")
    else
        mainFrame.subtitle:SetText(string.format("|cff%s%d item%s needed across %d character%s|r",
            "968a6e",
            remaining, remaining == 1 and "" or "s",
            #chars, #chars == 1 and "" or "s"))
    end

    -- Footer
    mainFrame.footer:SetText(string.format("%d / %d remaining", remaining, totalItems))

    -- Populate rows
    for i = 1, #filtered do
        local row = GetRow(i)
        local mat = filtered[i]

        row.icon:SetTexture(mat.icon)
        row.iconBtn.itemID = mat.itemID
        row.nameText:SetText(mat.itemName)

        local pct = mat.need > 0 and (mat.have / mat.need) or 1
        pct = math.min(1, pct)

        if mat.short <= 0 then
            -- Completed — dim it
            row.countText:SetText(string.format("|cff66cc66%d/%d|r", mat.have, mat.need))
            row.nameText:SetTextColor(0.4, 0.4, 0.4, 1)
            row.barFill:SetColorTexture(0.3, 0.7, 0.3, 0.6)
        elseif mat.have > 0 then
            -- Partial
            row.countText:SetText(string.format("|cffffcc00%d|r / %d", mat.have, mat.need))
            row.nameText:SetTextColor(unpack(KazGUI.Colors.textNormal))
            row.barFill:SetColorTexture(0.9, 0.75, 0.2, 0.8)
        else
            -- None gathered
            row.countText:SetText(string.format("|cffff6666%d|r / %d", mat.have, mat.need))
            row.nameText:SetTextColor(unpack(KazGUI.Colors.textNormal))
            row.barFill:SetColorTexture(0.7, 0.25, 0.25, 0.8)
        end

        -- Bar width
        row.barFill:SetWidth(math.max(1, row.barBg:GetWidth() * pct))

        -- Re-anchor for dynamic stripe
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollFrame.content, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", scrollFrame.content, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
        row:Show()
    end

    -- Hide excess rows
    for i = #filtered + 1, #rows do
        rows[i]:Hide()
    end

    -- Update scroll content height
    scrollFrame.content:SetHeight(math.max(1, #filtered * ROW_HEIGHT))
end

--------------------------------------------------------------------------------
-- Frame creation
--------------------------------------------------------------------------------
local function CreateGatheringFrame()
    mainFrame = KazGUI:CreateFrame("KazCraftGatheringFrame", FRAME_WIDTH, FRAME_HEIGHT, {
        title = "Gathering List",
        strata = "HIGH",
        escClose = true,
    })

    -- Subtitle
    mainFrame.subtitle = KazGUI:CreateText(mainFrame, KazGUI.Constants.FONT_SIZE_SMALL, "textDim")
    mainFrame.subtitle:SetPoint("TOPLEFT", mainFrame.titleBar, "BOTTOMLEFT", 10, -4)
    mainFrame.subtitle:SetPoint("TOPRIGHT", mainFrame.titleBar, "BOTTOMRIGHT", -10, -4)
    mainFrame.subtitle:SetJustifyH("LEFT")

    -- Show completed checkbox
    local checkbox = KazGUI:CreateCheckbox(mainFrame, "Show completed", false, function(checked)
        showCompleted = checked
        RefreshGatheringList()
    end)
    checkbox:SetPoint("TOPLEFT", mainFrame.subtitle, "BOTTOMLEFT", 0, -4)

    -- Scroll frame
    scrollFrame = KazGUI:CreateClassicScrollFrame(mainFrame, HEADER_OFFSET, 22)

    -- Footer
    mainFrame.footer = KazGUI:CreateText(mainFrame, KazGUI.Constants.FONT_SIZE_SMALL, "textDim")
    mainFrame.footer:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 10, 6)
    mainFrame.footer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 6)
    mainFrame.footer:SetJustifyH("RIGHT")

    -- Events — register BAG_UPDATE_DELAYED only while shown
    mainFrame.eventFrame = CreateFrame("Frame")
    mainFrame.eventFrame:SetScript("OnEvent", function(_, event)
        if event == "BAG_UPDATE_DELAYED" or event == "GET_ITEM_INFO_RECEIVED" then
            RefreshGatheringList()
        end
    end)

    mainFrame:SetScript("OnShow", function()
        mainFrame.eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
        mainFrame.eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
        RefreshGatheringList()
    end)

    mainFrame:SetScript("OnHide", function()
        mainFrame.eventFrame:UnregisterAllEvents()
    end)

    return mainFrame
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------
function Gathering:Toggle()
    if not mainFrame then
        CreateGatheringFrame()
    end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
    end
end

function Gathering:Show()
    if not mainFrame then
        CreateGatheringFrame()
    end
    mainFrame:Show()
end

function Gathering:Hide()
    if mainFrame then
        mainFrame:Hide()
    end
end

function Gathering:IsShown()
    return mainFrame and mainFrame:IsShown()
end
