local addonName, ns = ...

local ProfSpecs = {}
ns.ProfSpecs = ProfSpecs

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------
local NODE_SIZE = 54
local NODE_ICON_SIZE = 40
local LINE_THICKNESS = 2
local CANVAS_PADDING = 60
local TREE_TAB_HEIGHT = 28
local POINTS_BAR_HEIGHT = 28

-- Node border colors by state
local NODE_COLORS = {
    locked     = { 0.35, 0.35, 0.35, 1 },
    available  = { 200/255, 170/255, 100/255, 1 },   -- accent bronze
    progress   = { 0.6, 0.75, 0.55, 1 },             -- soft green
    maxed      = { 0.3, 0.85, 0.3, 1 },              -- bright green
}

local NODE_BG_COLORS = {
    locked     = { 0.06, 0.06, 0.06, 0.9 },
    available  = { 0.10, 0.09, 0.06, 0.95 },
    progress   = { 0.08, 0.10, 0.06, 0.95 },
    maxed      = { 0.06, 0.10, 0.06, 0.95 },
}

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------
local initialized = false
local parentFrame

-- UI refs
local treeTabBar
local treeTabs = {}
local pointsText
local canvasFrame
local canvasContent    -- the inner frame nodes/lines attach to

-- Data state
local skillLineID = nil
local configID = nil
local specTabIDs = {}
local activeTabID = nil

-- Node/line pools
local nodeFrames = {}   -- nodeID → frame
local lineTextures = {} -- table of line texture refs

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------
local function GetNodeState(pathID)
    if not configID or not pathID then return "locked" end
    local pathState = C_ProfSpecs.GetStateForPath(pathID, configID)
    if pathState == Enum.ProfessionsSpecPathState.Completed then
        return "maxed"
    elseif pathState == Enum.ProfessionsSpecPathState.Progressing then
        return "progress"
    end
    -- Locked — but check if root can be unlocked
    local nodeInfo = C_Traits.GetNodeInfo(configID, pathID)
    if nodeInfo and nodeInfo.canPurchaseRank then
        return "available"
    end
    return "locked"
end

local function GetNodeDisplayInfo(nodeInfo)
    -- Walk entryIDs → definitionID → icon/name
    if not nodeInfo or not nodeInfo.entryIDs then return nil, nil, nil end
    for _, entryID in ipairs(nodeInfo.entryIDs) do
        local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
        if entryInfo and entryInfo.definitionID then
            local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
            if defInfo then
                local icon = defInfo.overrideIcon
                local name = defInfo.overrideName
                local desc = defInfo.overrideDescription
                if not icon and defInfo.spellID then
                    local spellInfo = C_Spell.GetSpellInfo(defInfo.spellID)
                    if spellInfo then
                        icon = icon or spellInfo.iconID
                        name = name or spellInfo.name
                    end
                end
                return icon, name, desc
            end
        end
    end
    return nil, nil, nil
end

--------------------------------------------------------------------
-- Connection lines
--------------------------------------------------------------------
local function ClearLines()
    for _, tex in ipairs(lineTextures) do
        tex:Hide()
        tex:ClearAllPoints()
    end
    wipe(lineTextures)
end

local function DrawLine(parent, x1, y1, x2, y2, color)
    local line = parent:CreateLine(nil, "BACKGROUND")
    line:SetThickness(LINE_THICKNESS)
    line:SetStartPoint("CENTER", parent, "TOPLEFT", x1, -y1)
    line:SetEndPoint("CENTER", parent, "TOPLEFT", x2, -y2)
    line:SetColorTexture(color[1], color[2], color[3], color[4] or 0.6)
    line:Show()
    table.insert(lineTextures, line)
    return line
end

--------------------------------------------------------------------
-- Node widget
--------------------------------------------------------------------
local function CreateNodeFrame(parent, nodeID)
    local f = CreateFrame("Button", nil, parent, "BackdropTemplate")
    f:SetSize(NODE_SIZE, NODE_SIZE)
    f:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    f:RegisterForClicks("LeftButtonUp")

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(NODE_ICON_SIZE, NODE_ICON_SIZE)
    f.icon:SetPoint("CENTER", f, "CENTER", 0, 4)

    f.rankText = f:CreateFontString(nil, "OVERLAY")
    f.rankText:SetFont(ns.FONT, 11, "OUTLINE")
    f.rankText:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
    f.rankText:SetJustifyH("CENTER")

    f.lockIcon = f:CreateTexture(nil, "OVERLAY")
    f.lockIcon:SetSize(14, 14)
    f.lockIcon:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    f.lockIcon:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")
    f.lockIcon:Hide()

    -- Glow for available nodes
    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.glow:SetSize(NODE_SIZE + 8, NODE_SIZE + 8)
    f.glow:SetPoint("CENTER")
    f.glow:SetColorTexture(200/255, 170/255, 100/255, 0.15)
    f.glow:Hide()

    f.nodeID = nodeID

    -- Tooltip
    f:SetScript("OnEnter", function(self)
        if not self.nodeID or not configID then return end
        local ni = C_Traits.GetNodeInfo(configID, self.nodeID)
        if not ni then return end
        local icon, name, desc = GetNodeDisplayInfo(ni)

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(name or "Specialization", 1, 0.82, 0)

        -- Rank
        local current = ni.activeRank or 0
        local max = ni.maxRanks or 0
        if max > 0 then
            GameTooltip:AddLine("Rank: " .. current .. "/" .. max, 1, 1, 1)
        end

        -- Path description
        local pathDesc = C_ProfSpecs.GetDescriptionForPath(self.nodeID)
        if pathDesc and pathDesc ~= "" then
            GameTooltip:AddLine(pathDesc, 0.85, 0.85, 0.85, true)
        end

        -- Perk bonuses
        local perks = C_ProfSpecs.GetPerksForPath(self.nodeID)
        if perks and #perks > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Bonuses:", 1, 0.82, 0)
            for _, perkInfo in ipairs(perks) do
                local perkState = C_ProfSpecs.GetStateForPerk(perkInfo.perkID, configID)
                local unlockRank = C_ProfSpecs.GetUnlockRankForPerk(perkInfo.perkID)
                local perkDesc = C_ProfSpecs.GetDescriptionForPerk(perkInfo.perkID)
                if perkDesc and perkDesc ~= "" then
                    local prefix = ""
                    if perkState == Enum.ProfessionsSpecPerkState.Earned then
                        prefix = "|cff4dff4d*|r "
                    elseif unlockRank then
                        prefix = "|cff888888[Rank " .. unlockRank .. "]|r "
                    end
                    local r, g, b = 0.7, 0.7, 0.7
                    if perkState == Enum.ProfessionsSpecPerkState.Earned then
                        r, g, b = 0.3, 0.9, 0.3
                    end
                    GameTooltip:AddLine(prefix .. perkDesc, r, g, b, true)
                end
            end
        end

        -- Status info
        local state = GetNodeState(self.nodeID)
        if state == "locked" then
            local sourceText = C_ProfSpecs.GetSourceTextForPath(self.nodeID, configID)
            if sourceText and sourceText ~= "" then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(sourceText, 1, 0.3, 0.3, true)
            end
        elseif state == "available" and ni.canPurchaseRank then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click to spend a point", 0.3, 0.9, 0.3)
        end

        GameTooltip:Show()

        -- Highlight border
        self:SetBackdropBorderColor(unpack(ns.COLORS.accent))
    end)

    f:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        -- Restore border color
        local state = GetNodeState(self.nodeID)
        local colors = NODE_COLORS[state] or NODE_COLORS.locked
        self:SetBackdropBorderColor(unpack(colors))
    end)

    -- Click to spend
    f:SetScript("OnClick", function(self)
        if not self.nodeID or not configID then return end
        local ni = C_Traits.GetNodeInfo(configID, self.nodeID)
        if not ni then return end

        if ni.canPurchaseRank then
            C_Traits.PurchaseRank(configID, self.nodeID)
            C_Traits.CommitConfig(configID)
            -- Refresh happens via TRAIT_NODE_CHANGED event
        end
    end)

    return f
end

local function UpdateNodeFrame(f, nodeID)
    if not configID then return end
    local ni = C_Traits.GetNodeInfo(configID, nodeID)
    if not ni then
        f:Hide()
        return
    end

    f.nodeID = nodeID

    -- Icon + name
    local icon, name, desc = GetNodeDisplayInfo(ni)
    f.icon:SetTexture(icon or 134400)

    -- Rank display
    local current = ni.activeRank or 0
    local max = ni.maxRanks or 0
    if max > 0 then
        f.rankText:SetText(current .. "/" .. max)
    else
        f.rankText:SetText("")
    end

    -- State-based visuals
    local state = GetNodeState(nodeID)
    local borderColor = NODE_COLORS[state] or NODE_COLORS.locked
    local bgColor = NODE_BG_COLORS[state] or NODE_BG_COLORS.locked

    f:SetBackdropColor(unpack(bgColor))
    f:SetBackdropBorderColor(unpack(borderColor))

    if state == "locked" then
        f.icon:SetDesaturated(true)
        f.icon:SetAlpha(0.4)
        f.lockIcon:Show()
        f.glow:Hide()
        f.rankText:SetTextColor(0.4, 0.4, 0.4)
    elseif state == "available" then
        f.icon:SetDesaturated(false)
        f.icon:SetAlpha(1)
        f.lockIcon:Hide()
        f.glow:Show()
        f.rankText:SetTextColor(unpack(ns.COLORS.accent))
    elseif state == "maxed" then
        f.icon:SetDesaturated(false)
        f.icon:SetAlpha(1)
        f.lockIcon:Hide()
        f.glow:Hide()
        f.rankText:SetTextColor(0.3, 0.9, 0.3)
    else -- progress
        f.icon:SetDesaturated(false)
        f.icon:SetAlpha(1)
        f.lockIcon:Hide()
        f.glow:Hide()
        f.rankText:SetTextColor(unpack(ns.COLORS.brightText))
    end

    f:Show()
end

--------------------------------------------------------------------
-- Tree rendering
--------------------------------------------------------------------
local function CollectTreeNodes(rootPathID)
    -- BFS from root, collecting all nodes via C_ProfSpecs.GetChildrenForPath
    local nodes = {}
    local visited = {}
    local queue = { rootPathID }
    while #queue > 0 do
        local pathID = table.remove(queue, 1)
        if pathID and not visited[pathID] then
            visited[pathID] = true
            table.insert(nodes, pathID)
            local children = C_ProfSpecs.GetChildrenForPath(pathID)
            if children then
                for _, childID in ipairs(children) do
                    if not visited[childID] then
                        table.insert(queue, childID)
                    end
                end
            end
        end
    end
    return nodes
end

local function RenderTree()
    if not activeTabID or not configID then return end

    -- Clear existing
    ClearLines()
    for _, f in pairs(nodeFrames) do
        f:Hide()
    end

    -- Get root path for active tab
    local rootPathID = C_ProfSpecs.GetRootPathForTab(activeTabID)
    if not rootPathID then return end

    -- Collect all nodes in tree
    local allNodes = CollectTreeNodes(rootPathID)
    if #allNodes == 0 then return end

    -- Get positions from C_Traits.GetNodeInfo
    local positions = {}
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, pathID in ipairs(allNodes) do
        local ni = C_Traits.GetNodeInfo(configID, pathID)
        if ni and ni.isVisible then
            positions[pathID] = { x = ni.posX, y = ni.posY }
            if ni.posX < minX then minX = ni.posX end
            if ni.posY < minY then minY = ni.posY end
            if ni.posX > maxX then maxX = ni.posX end
            if ni.posY > maxY then maxY = ni.posY end
        end
    end

    -- Calculate scale to fit canvas
    local canvasW = canvasFrame:GetWidth() - (CANVAS_PADDING * 2)
    local canvasH = canvasFrame:GetHeight() - (CANVAS_PADDING * 2)
    local treeW = maxX - minX
    local treeH = maxY - minY

    if treeW <= 0 then treeW = 1 end
    if treeH <= 0 then treeH = 1 end

    local scaleX = canvasW / treeW
    local scaleY = canvasH / treeH
    local scale = math.min(scaleX, scaleY, 1)  -- don't scale up past 1:1

    -- Center offset
    local offsetX = CANVAS_PADDING + (canvasW - treeW * scale) / 2
    local offsetY = CANVAS_PADDING + (canvasH - treeH * scale) / 2

    -- Helper: world pos → canvas pixel pos
    local function ToCanvas(px, py)
        return offsetX + (px - minX) * scale,
               offsetY + (py - minY) * scale
    end

    -- Set canvas content size
    canvasContent:SetSize(canvasFrame:GetWidth(), canvasFrame:GetHeight())

    -- Draw connection lines first (under nodes)
    for _, pathID in ipairs(allNodes) do
        local pos = positions[pathID]
        if not pos then goto continueLine end

        local ni = C_Traits.GetNodeInfo(configID, pathID)
        if not ni or not ni.isVisible then goto continueLine end

        local px, py = ToCanvas(pos.x, pos.y)

        -- Draw edges to children via visibleEdges
        if ni.visibleEdges then
            for _, edge in ipairs(ni.visibleEdges) do
                local childPos = positions[edge.targetNode]
                if childPos then
                    local cx, cy = ToCanvas(childPos.x, childPos.y)
                    local lineColor
                    if edge.isActive then
                        lineColor = { 200/255, 170/255, 100/255, 0.7 }
                    else
                        lineColor = { 0.3, 0.3, 0.3, 0.4 }
                    end
                    DrawLine(canvasContent, px, py, cx, cy, lineColor)
                end
            end
        end

        -- Also draw to ProfSpecs children (some connections aren't in visibleEdges)
        local children = C_ProfSpecs.GetChildrenForPath(pathID)
        if children then
            for _, childID in ipairs(children) do
                local childPos = positions[childID]
                if childPos then
                    -- Check if we already drew this via visibleEdges
                    local alreadyDrawn = false
                    if ni.visibleEdges then
                        for _, edge in ipairs(ni.visibleEdges) do
                            if edge.targetNode == childID then
                                alreadyDrawn = true
                                break
                            end
                        end
                    end
                    if not alreadyDrawn then
                        local cx, cy = ToCanvas(childPos.x, childPos.y)
                        local childState = GetNodeState(childID)
                        local lineColor
                        if childState ~= "locked" then
                            lineColor = { 200/255, 170/255, 100/255, 0.5 }
                        else
                            lineColor = { 0.3, 0.3, 0.3, 0.3 }
                        end
                        DrawLine(canvasContent, px, py, cx, cy, lineColor)
                    end
                end
            end
        end

        ::continueLine::
    end

    -- Draw nodes on top
    for _, pathID in ipairs(allNodes) do
        local pos = positions[pathID]
        if not pos then goto continueNode end

        local ni = C_Traits.GetNodeInfo(configID, pathID)
        if not ni or not ni.isVisible then goto continueNode end

        local px, py = ToCanvas(pos.x, pos.y)

        local f = nodeFrames[pathID]
        if not f then
            f = CreateNodeFrame(canvasContent, pathID)
            nodeFrames[pathID] = f
        end

        f:ClearAllPoints()
        f:SetPoint("CENTER", canvasContent, "TOPLEFT", px, -py)
        UpdateNodeFrame(f, pathID)

        ::continueNode::
    end
end

--------------------------------------------------------------------
-- Tree tab bar
--------------------------------------------------------------------
local function CreateTreeTabs()
    if treeTabBar then
        treeTabBar:Hide()
    end

    treeTabBar = CreateFrame("Frame", nil, parentFrame)
    treeTabBar:SetHeight(TREE_TAB_HEIGHT)
    treeTabBar:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 8, 0)
    treeTabBar:SetPoint("TOPRIGHT", parentFrame, "TOPRIGHT", -8, 0)

    -- Clear old tabs
    for _, btn in ipairs(treeTabs) do
        btn:Hide()
    end
    wipe(treeTabs)

    if not skillLineID then return end

    specTabIDs = C_ProfSpecs.GetSpecTabIDsForSkillLine(skillLineID) or {}

    local xOff = 0
    for i, tabID in ipairs(specTabIDs) do
        local tabInfo = C_ProfSpecs.GetTabInfo(tabID)
        if tabInfo then
            local tabState = C_ProfSpecs.GetStateForTab(tabID, configID)

            local btn = ns.CreateButton(treeTabBar, tabInfo.name or ("Spec " .. i), 0, TREE_TAB_HEIGHT - 4)
            btn:SetPoint("TOPLEFT", treeTabBar, "TOPLEFT", xOff, -2)

            -- Auto-width based on text
            local textW = btn.label:GetStringWidth() + 20
            btn:SetWidth(math.max(textW, 80))

            btn.tabID = tabID
            btn.tabState = tabState

            -- Dim if locked
            if tabState == Enum.ProfessionsSpecTabState.Locked then
                btn.label:SetTextColor(0.4, 0.4, 0.4)
            end

            btn:SetScript("OnClick", function(self)
                if self.tabState == Enum.ProfessionsSpecTabState.Locked then
                    -- Check if unlockable
                    if C_ProfSpecs.CanUnlockTab(self.tabID, configID) then
                        -- First point purchase unlocks the tab
                        local rootPath = C_ProfSpecs.GetRootPathForTab(self.tabID)
                        if rootPath then
                            local ni = C_Traits.GetNodeInfo(configID, rootPath)
                            if ni and ni.canPurchaseRank then
                                C_Traits.PurchaseRank(configID, rootPath)
                                C_Traits.CommitConfig(configID)
                            end
                        end
                    end
                    return
                end
                activeTabID = self.tabID
                ProfSpecs:RefreshTreeTabs()
                RenderTree()
            end)

            table.insert(treeTabs, btn)
            xOff = xOff + btn:GetWidth() + 4
        end
    end
end

function ProfSpecs:RefreshTreeTabs()
    for _, btn in ipairs(treeTabs) do
        local isActive = (btn.tabID == activeTabID)
        local tabState = C_ProfSpecs.GetStateForTab(btn.tabID, configID)
        btn.tabState = tabState

        if isActive then
            btn.label:SetTextColor(unpack(ns.COLORS.tabActive))
        elseif tabState == Enum.ProfessionsSpecTabState.Locked then
            btn.label:SetTextColor(0.4, 0.4, 0.4)
        else
            btn.label:SetTextColor(unpack(ns.COLORS.tabInactive))
        end
    end
end

--------------------------------------------------------------------
-- Points display
--------------------------------------------------------------------
local function UpdatePointsDisplay()
    if not pointsText or not skillLineID then return end
    local currInfo = C_ProfSpecs.GetCurrencyInfoForSkillLine(skillLineID)
    if currInfo then
        local pts = currInfo.numAvailable or 0
        local name = currInfo.currencyName or "Knowledge"
        if pts > 0 then
            pointsText:SetText("Available: |cff4dff4d" .. pts .. "|r " .. name)
        else
            pointsText:SetText("Available: " .. pts .. " " .. name)
        end
    else
        pointsText:SetText("")
    end
end

--------------------------------------------------------------------
-- Init / Show / Hide / Refresh
--------------------------------------------------------------------
function ProfSpecs:Init(parent)
    if initialized then return end
    initialized = true
    parentFrame = parent

    -- Points bar
    pointsText = parent:CreateFontString(nil, "OVERLAY")
    pointsText:SetFont(ns.FONT, 14, "")
    pointsText:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -(TREE_TAB_HEIGHT + 4))
    pointsText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Canvas area
    canvasFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    canvasFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(TREE_TAB_HEIGHT + POINTS_BAR_HEIGHT + 4))
    canvasFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    canvasFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    canvasFrame:SetBackdropColor(8/255, 8/255, 8/255, 0.6)
    canvasFrame:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
    canvasFrame:SetClipsChildren(true)

    -- Inner content frame (nodes/lines attach here)
    canvasContent = CreateFrame("Frame", nil, canvasFrame)
    canvasContent:SetAllPoints()

    -- Event frame for refresh
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("TRAIT_NODE_CHANGED")
    eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    eventFrame:RegisterEvent("SKILL_LINE_SPECS_RANKS_CHANGED")
    eventFrame:RegisterEvent("SKILL_LINE_SPECS_UNLOCKED")
    eventFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if not ProfSpecs:IsShown() then return end
        if event == "TRAIT_NODE_CHANGED" then
            local nodeID = ...
            -- Quick update just this node if it exists
            if nodeFrames[nodeID] then
                UpdateNodeFrame(nodeFrames[nodeID], nodeID)
            end
            UpdatePointsDisplay()
        elseif event == "TRAIT_CONFIG_UPDATED" then
            -- Full refresh
            ProfSpecs:Refresh()
        elseif event == "SKILL_LINE_SPECS_RANKS_CHANGED" then
            ProfSpecs:Refresh()
        elseif event == "SKILL_LINE_SPECS_UNLOCKED" then
            ProfSpecs:Refresh()
        elseif event == "CURRENCY_DISPLAY_UPDATE" then
            UpdatePointsDisplay()
        end
    end)
end

function ProfSpecs:Show()
    if not initialized then return end

    -- Get current profession skillLine
    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    if profInfo and profInfo.professionID then
        skillLineID = profInfo.professionID
    else
        skillLineID = nil
    end

    if not skillLineID or not C_ProfSpecs.SkillLineHasSpecialization(skillLineID) then
        -- No specializations for this profession
        canvasFrame:Hide()
        pointsText:SetText("No specializations available for this profession.")
        pointsText:Show()
        if treeTabBar then treeTabBar:Hide() end
        return
    end

    configID = C_ProfSpecs.GetConfigIDForSkillLine(skillLineID)
    C_Traits.StageConfig(configID)

    -- Build tree tabs
    CreateTreeTabs()
    if treeTabBar then treeTabBar:Show() end

    -- Select first unlocked tab (or first tab)
    activeTabID = nil
    for _, tabID in ipairs(specTabIDs) do
        local tabState = C_ProfSpecs.GetStateForTab(tabID, configID)
        if tabState ~= Enum.ProfessionsSpecTabState.Locked then
            activeTabID = tabID
            break
        end
    end
    if not activeTabID and #specTabIDs > 0 then
        activeTabID = specTabIDs[1]
    end

    self:RefreshTreeTabs()
    canvasFrame:Show()
    pointsText:Show()
    UpdatePointsDisplay()
    RenderTree()
end

function ProfSpecs:Hide()
    if not initialized then return end
    if canvasFrame then canvasFrame:Hide() end
    if pointsText then pointsText:Hide() end
    if treeTabBar then treeTabBar:Hide() end
end

function ProfSpecs:IsShown()
    return initialized and canvasFrame and canvasFrame:IsShown()
end

function ProfSpecs:Refresh()
    if not self:IsShown() then return end
    if skillLineID then
        configID = C_ProfSpecs.GetConfigIDForSkillLine(skillLineID)
        C_Traits.StageConfig(configID)
    end
    CreateTreeTabs()
    self:RefreshTreeTabs()
    UpdatePointsDisplay()
    RenderTree()
end
