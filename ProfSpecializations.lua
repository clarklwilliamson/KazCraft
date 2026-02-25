local addonName, ns = ...

local ProfSpecs = {}
ns.ProfSpecs = ProfSpecs

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------
local NODE_SIZE = 48
local NODE_ICON_SIZE = 36
local LINE_THICKNESS = 2
local BOX_PAD = 8            -- padding inside each tree box
local BOX_TITLE_H = 28      -- title bar height inside box
local BOX_GAP = 4            -- gap between tree boxes
local POINTS_BAR_HEIGHT = 24
local DETAIL_WIDTH = 280     -- right-side detail panel

-- Node border colors by state
local NODE_COLORS = {
    locked     = { 0.35, 0.35, 0.35, 1 },
    selectable = { 200/255, 170/255, 100/255, 1 },  -- can unlock (locked but purchasable)
    available  = { 200/255, 170/255, 100/255, 1 },   -- can spend points
    progress   = { 0.6, 0.75, 0.55, 1 },             -- progressing, no points to spend
    maxed      = { 0.3, 0.85, 0.3, 1 },
}

local NODE_BG_COLORS = {
    locked     = { 0.06, 0.06, 0.06, 0.9 },
    selectable = { 0.10, 0.09, 0.06, 0.95 },
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
local pointsText
local canvasFrame       -- main area
local treeArea          -- left side: tree boxes go here
local detailPanel       -- right side: hover info

-- Detail panel sub-elements
local detailName, detailRank, detailDesc, detailSep
local detailBonusHeader
local detailBonusLines = {}
local detailStatus

-- Data state
local skillLineID = nil
local configID = nil
local specTabIDs = {}

-- Pools
local nodeFrames = {}       -- pathID → frame
local treeBoxes = {}        -- list of box frames (reused)
local treeBoxLines = {}     -- boxIdx → {line textures}

--------------------------------------------------------------------
-- Hand-tuned box layout (from KazSpecLayout /ksl dump)
-- rootPathID → { x, y } box position relative to tree area origin
-- If present, boxes use these positions instead of left-to-right flow.
--------------------------------------------------------------------
local SAVED_BOX_LAYOUT = {
    -- Engineering (3 trees, single row)
    [100765] = { x = 0, y = 0 },
    [100791] = { x = 365, y = 0 },
    [100843] = { x = 530, y = 0 },
    -- Enchanting (4 trees, 2x2 grid — top row: 99890+100008, bottom row: 100040+99940)
    [99890] = { x = 3, y = 0 },
    [100008] = { x = 321, y = 0 },
    [100040] = { x = 0, y = 175 },
    [99940] = { x = 325, y = 175 },
}

--------------------------------------------------------------------
-- Hand-tuned node positions (from KazSpecLayout /ksl dump)
-- pathID → { x, y } relative to tree root (0,0)
--------------------------------------------------------------------
local SAVED_POSITIONS = {
    -- Engineering: Engineered Equipment (root 100765)
    [100765] = { x = 0, y = 0 },
    [100764] = { x = -77, y = 92 },
    [100763] = { x = -150, y = 182 },
    [100762] = { x = -77, y = 181 },
    [100761] = { x = 77, y = 92 },
    [100760] = { x = 78, y = 179 },
    [100759] = { x = 157, y = 178 },
    -- Engineering: Devices (root 100791)
    [100791] = { x = 0, y = 0 },
    [100790] = { x = -77, y = 92 },
    [100789] = { x = 77, y = 92 },
    -- Engineering: Inventing (root 100843)
    [100843] = { x = 0, y = 0 },
    [100842] = { x = -104, y = 60 },
    [100841] = { x = -1, y = 98 },
    [100840] = { x = -100, y = 153 },
    [100839] = { x = -31, y = 205 },
    [100838] = { x = 31, y = 205 },
    [100837] = { x = 106, y = 143 },
    [100836] = { x = 104, y = 60 },

    -- Enchanting: Supplementary Shattering (root 100040)
    [100040] = { x = 0, y = 0 },
    [100039] = { x = -96, y = 76 },
    [100038] = { x = 2, y = 76 },
    [100037] = { x = 104, y = 72 },
    -- Enchanting: Designated Disenchanter (root 99890)
    [99890] = { x = 0, y = 0 },
    [99889] = { x = -83, y = 87 },
    [99888] = { x = -3, y = 88 },
    [99887] = { x = 90, y = 87 },
    -- Enchanting: Everlasting Enchantments (root 100008)
    [100008] = { x = 0, y = 0 },
    [100007] = { x = -88, y = 103 },
    [100006] = { x = -188, y = 29 },
    [100005] = { x = -182, y = 105 },
    [100004] = { x = -176, y = 196 },
    [100003] = { x = -2, y = 103 },
    [100002] = { x = -45, y = 198 },
    [100001] = { x = 45, y = 198 },
    [100000] = { x = 91, y = 101 },
    [99999] = { x = 168, y = 195 },
    [99998] = { x = 182, y = 50 },
    -- Enchanting: Ephemerals, Enrichments, and Equipment (root 99940)
    [99940] = { x = 0, y = 0 },
    [99939] = { x = -103, y = 3 },
    [99938] = { x = -2, y = 110 },
    [99937] = { x = -99, y = 114 },
    [99936] = { x = -96, y = 196 },
    [99935] = { x = 103, y = 3 },
    [99934] = { x = 102, y = 108 },
    [99933] = { x = 197, y = 0 },
}

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------
-- Track which trees are tab-locked (set per render cycle)
local lockedTreeRoots = {}  -- rootPathID → true

local function GetNodeState(pathID, treeLocked)
    if not configID or not pathID then return "locked" end
    if treeLocked then return "locked" end

    local pathState = C_ProfSpecs.GetStateForPath(pathID, configID)

    if pathState == Enum.ProfessionsSpecPathState.Completed then
        return "maxed"
    elseif pathState == Enum.ProfessionsSpecPathState.Progressing then
        -- Progressing: check if we can actually spend a point right now
        local spendEntryID = C_ProfSpecs.GetSpendEntryForPath(pathID)
        if spendEntryID and C_Traits.CanPurchaseRank(configID, pathID, spendEntryID) then
            return "available"  -- can spend points
        end
        return "progress"  -- progressing but can't spend right now
    end

    -- Path is Locked: check if we can unlock it
    local unlockEntryID = C_ProfSpecs.GetUnlockEntryForPath(pathID)
    if unlockEntryID and C_Traits.CanPurchaseRank(configID, pathID, unlockEntryID) then
        return "selectable"  -- locked but ready to unlock
    end

    return "locked"
end

local function GetNodeDisplayInfo(nodeInfo)
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
-- Radial fallback layout
--------------------------------------------------------------------
local PRIMARY_ROTATION = { [1] = 0, [2] = 80, [3] = 60, [4] = 50, [5] = 45 }
local SECONDARY_ROTATION = { [1] = 0, [2] = 60, [3] = 50, [4] = 40, [5] = 35 }

local function GetRotationSpread(layer, numChildren)
    local tbl = (layer == 1) and PRIMARY_ROTATION or SECONDARY_ROTATION
    return tbl[math.min(numChildren, 5)] or 45
end

local function BuildTreeLayout(rootPathID)
    local childrenOf = {}
    local allNodes = {}
    local function Traverse(pathID)
        table.insert(allNodes, pathID)
        local kids = C_ProfSpecs.GetChildrenForPath(pathID) or {}
        childrenOf[pathID] = kids
        for _, kid in ipairs(kids) do Traverse(kid) end
    end
    Traverse(rootPathID)

    if #allNodes == 0 then return allNodes, childrenOf, {} end

    -- Check saved positions
    if SAVED_POSITIONS[rootPathID] then
        local positions = {}
        local allSaved = true
        for _, pathID in ipairs(allNodes) do
            local sp = SAVED_POSITIONS[pathID]
            if sp then
                positions[pathID] = { x = sp.x, y = sp.y }
            else
                allSaved = false
                break
            end
        end
        if allSaved then return allNodes, childrenOf, positions end
    end

    -- Radial fallback
    local positions = {}
    positions[rootPathID] = { x = 0, y = 0 }

    local function PosKids(parentID, px, py, pRot, dist, layer)
        local kids = childrenOf[parentID] or {}
        local n = #kids
        if n == 0 then return end
        local spread = GetRotationSpread(layer, n)
        local pivot = (n / 2) + 0.5
        for i, childID in ipairs(kids) do
            local offset = i - pivot
            local cRot = pRot + (offset * spread)
            local rad = cRot / 180 * math.pi
            positions[childID] = {
                x = px + math.sin(rad) * dist,
                y = py + math.cos(rad) * dist,
                rot = cRot,
            }
        end
    end

    PosKids(rootPathID, 0, 0, 0, 120, 1)
    for _, pid in ipairs(childrenOf[rootPathID] or {}) do
        local p = positions[pid]
        if p then PosKids(pid, p.x, p.y, p.rot, 90, 2) end
    end
    local function Deeper(parentID)
        for _, cid in ipairs(childrenOf[parentID] or {}) do
            local p = positions[cid]
            if p and #(childrenOf[cid] or {}) > 0 then
                PosKids(cid, p.x, p.y, p.rot, 76, 2)
                Deeper(cid)
            end
        end
    end
    for _, pid in ipairs(childrenOf[rootPathID] or {}) do Deeper(pid) end

    return allNodes, childrenOf, positions
end

local function GetBounds(positions)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, pos in pairs(positions) do
        if pos.x < minX then minX = pos.x end
        if pos.y < minY then minY = pos.y end
        if pos.x > maxX then maxX = pos.x end
        if pos.y > maxY then maxY = pos.y end
    end
    return minX, minY, maxX, maxY
end

--------------------------------------------------------------------
-- Detail panel (right side)
--------------------------------------------------------------------
local function CreateDetailPanel(parent)
    local dp = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    dp:SetWidth(DETAIL_WIDTH)
    dp:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    dp:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    dp:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    dp:SetBackdropColor(12/255, 12/255, 12/255, 0.95)
    dp:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    local pad = 12
    local yOff = -pad

    -- Node name
    detailName = dp:CreateFontString(nil, "OVERLAY")
    detailName:SetFont(ns.FONT, 14, "")
    detailName:SetPoint("TOPLEFT", dp, "TOPLEFT", pad, yOff)
    detailName:SetPoint("TOPRIGHT", dp, "TOPRIGHT", -pad, yOff)
    detailName:SetTextColor(unpack(ns.COLORS.accent))
    detailName:SetJustifyH("LEFT")
    detailName:SetWordWrap(true)

    -- Rank
    detailRank = dp:CreateFontString(nil, "OVERLAY")
    detailRank:SetFont(ns.FONT, 12, "")
    detailRank:SetPoint("TOPLEFT", detailName, "BOTTOMLEFT", 0, -4)
    detailRank:SetTextColor(0.9, 0.9, 0.9)

    -- Separator
    detailSep = dp:CreateTexture(nil, "ARTWORK")
    detailSep:SetHeight(1)
    detailSep:SetPoint("TOPLEFT", detailRank, "BOTTOMLEFT", 0, -6)
    detailSep:SetPoint("RIGHT", dp, "RIGHT", -pad, 0)
    detailSep:SetColorTexture(unpack(ns.COLORS.panelBorder))

    -- Description
    detailDesc = dp:CreateFontString(nil, "OVERLAY")
    detailDesc:SetFont(ns.FONT, 11, "")
    detailDesc:SetPoint("TOPLEFT", detailSep, "BOTTOMLEFT", 0, -6)
    detailDesc:SetPoint("RIGHT", dp, "RIGHT", -pad, 0)
    detailDesc:SetTextColor(0.75, 0.75, 0.75)
    detailDesc:SetJustifyH("LEFT")
    detailDesc:SetWordWrap(true)

    -- Bonus header
    detailBonusHeader = dp:CreateFontString(nil, "OVERLAY")
    detailBonusHeader:SetFont(ns.FONT, 12, "")
    detailBonusHeader:SetPoint("TOPLEFT", detailDesc, "BOTTOMLEFT", 0, -10)
    detailBonusHeader:SetTextColor(unpack(ns.COLORS.accent))
    detailBonusHeader:SetText("Bonuses:")

    -- Status line (bottom)
    detailStatus = dp:CreateFontString(nil, "OVERLAY")
    detailStatus:SetFont(ns.FONT, 11, "")
    detailStatus:SetPoint("BOTTOMLEFT", dp, "BOTTOMLEFT", pad, pad)
    detailStatus:SetPoint("BOTTOMRIGHT", dp, "BOTTOMRIGHT", -pad, pad)
    detailStatus:SetJustifyH("LEFT")
    detailStatus:SetWordWrap(true)

    return dp
end

local function ClearDetailPanel()
    if not detailPanel then return end
    detailName:SetText("Hover a node")
    detailName:SetTextColor(0.5, 0.5, 0.5)
    detailRank:SetText("")
    detailSep:Hide()
    detailDesc:SetText("")
    detailBonusHeader:Hide()
    for _, bl in ipairs(detailBonusLines) do bl:Hide() end
    detailStatus:SetText("")
end

local function PopulateDetailPanel(pathID)
    if not detailPanel or not configID then return end
    local ni = C_Traits.GetNodeInfo(configID, pathID)
    if not ni then return end

    local icon, name, desc = GetNodeDisplayInfo(ni)
    local state = GetNodeState(pathID)

    -- Name
    detailName:SetText(name or "Specialization")
    detailName:SetTextColor(unpack(ns.COLORS.accent))

    -- Rank (subtract 1: unlock entry is free and doesn't count)
    local cur = math.max((ni.activeRank or 0) - 1, 0)
    local mx = math.max((ni.maxRanks or 0) - 1, 0)
    if mx > 0 then
        local rankColor = (cur >= mx) and "|cff4dff4d" or "|cffffffff"
        detailRank:SetText("Rank: " .. rankColor .. cur .. "/" .. mx .. "|r")
    else
        detailRank:SetText("")
    end

    -- Separator
    detailSep:Show()

    -- Description
    local pathDesc = C_ProfSpecs.GetDescriptionForPath(pathID)
    detailDesc:SetText((pathDesc and pathDesc ~= "") and pathDesc or (desc or ""))

    -- Perks
    local perks = C_ProfSpecs.GetPerksForPath(pathID)
    if perks and #perks > 0 then
        detailBonusHeader:Show()
        detailBonusHeader:ClearAllPoints()
        detailBonusHeader:SetPoint("TOPLEFT", detailDesc, "BOTTOMLEFT", 0, -10)

        local prevLine = detailBonusHeader
        for i, perkInfo in ipairs(perks) do
            local bl = detailBonusLines[i]
            if not bl then
                bl = detailPanel:CreateFontString(nil, "OVERLAY")
                bl:SetFont(ns.FONT, 11, "")
                bl:SetPoint("RIGHT", detailPanel, "RIGHT", -12, 0)
                bl:SetJustifyH("LEFT")
                bl:SetWordWrap(true)
                detailBonusLines[i] = bl
            end
            bl:ClearAllPoints()
            bl:SetPoint("TOPLEFT", prevLine, "BOTTOMLEFT", (prevLine == detailBonusHeader) and 4 or 0, -3)
            bl:SetPoint("RIGHT", detailPanel, "RIGHT", -12, 0)

            local perkState = C_ProfSpecs.GetStateForPerk(perkInfo.perkID, configID)
            local unlockRank = C_ProfSpecs.GetUnlockRankForPerk(perkInfo.perkID)
            local perkDesc = C_ProfSpecs.GetDescriptionForPerk(perkInfo.perkID)

            if perkDesc and perkDesc ~= "" then
                local prefix = ""
                if perkState == Enum.ProfessionsSpecPerkState.Earned then
                    prefix = "|cff4dff4d*|r "
                    bl:SetTextColor(0.3, 0.9, 0.3)
                else
                    if unlockRank then
                        prefix = "|cff666666[" .. unlockRank .. "]|r "
                    end
                    bl:SetTextColor(0.55, 0.55, 0.55)
                end
                bl:SetText(prefix .. perkDesc)
                bl:Show()
            else
                bl:Hide()
            end

            prevLine = bl
        end
        -- Hide extra bonus lines
        for j = #perks + 1, #detailBonusLines do
            detailBonusLines[j]:Hide()
        end
    else
        detailBonusHeader:Hide()
        for _, bl in ipairs(detailBonusLines) do bl:Hide() end
    end

    -- Status
    if state == "locked" then
        local sourceText = C_ProfSpecs.GetSourceTextForPath(pathID, configID)
        if sourceText and sourceText ~= "" then
            detailStatus:SetText("|cffff4d4d" .. sourceText .. "|r")
        else
            detailStatus:SetText("|cff888888Locked|r")
        end
    elseif state == "selectable" then
        detailStatus:SetText("|cffC8AA64Click to unlock|r")
    elseif state == "available" then
        detailStatus:SetText("|cff4dff4dClick to spend a point|r")
    elseif state == "maxed" then
        detailStatus:SetText("|cff4dff4dCompleted|r")
    elseif state == "progress" then
        local cur = math.max((ni.activeRank or 0) - 1, 0)
        local mx = math.max((ni.maxRanks or 0) - 1, 0)
        detailStatus:SetText("|cffC8AA64In progress (" .. cur .. "/" .. mx .. ")|r")
    else
        detailStatus:SetText("")
    end
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

    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.glow:SetSize(NODE_SIZE + 8, NODE_SIZE + 8)
    f.glow:SetPoint("CENTER")
    f.glow:SetColorTexture(200/255, 170/255, 100/255, 0.15)
    f.glow:Hide()

    f.nodeID = nodeID

    -- Hover → detail panel
    f:SetScript("OnEnter", function(self)
        if self.nodeID and configID then
            PopulateDetailPanel(self.nodeID)
        end
        self:SetBackdropBorderColor(unpack(ns.COLORS.accent))
    end)

    f:SetScript("OnLeave", function(self)
        ClearDetailPanel()
        local state = GetNodeState(self.nodeID, self.treeLocked)
        local colors = NODE_COLORS[state] or NODE_COLORS.locked
        self:SetBackdropBorderColor(unpack(colors))
    end)

    -- Click to stage spend or unlock (NOT committed until Apply)
    f:SetScript("OnClick", function(self)
        if not self.nodeID or not configID then return end
        if InCombatLockdown() then return end

        local pathState = C_ProfSpecs.GetStateForPath(self.nodeID, configID)

        if pathState == Enum.ProfessionsSpecPathState.Locked then
            local unlockEntryID = C_ProfSpecs.GetUnlockEntryForPath(self.nodeID)
            if unlockEntryID and C_Traits.CanPurchaseRank(configID, self.nodeID, unlockEntryID) then
                C_Traits.PurchaseRank(configID, self.nodeID, unlockEntryID)
            end
        elseif pathState == Enum.ProfessionsSpecPathState.Progressing then
            local spendEntryID = C_ProfSpecs.GetSpendEntryForPath(self.nodeID)
            if spendEntryID and C_Traits.CanPurchaseRank(configID, self.nodeID, spendEntryID) then
                C_Traits.PurchaseRank(configID, self.nodeID, spendEntryID)
            end
        end

        -- Update apply button state
        if ns.ProfSpecs.UpdateApplyButton then
            ns.ProfSpecs.UpdateApplyButton()
        end
    end)

    return f
end

local function UpdateNodeFrame(f, nodeID, treeLocked)
    if not configID then return end
    local ni = C_Traits.GetNodeInfo(configID, nodeID)
    if not ni then f:Hide(); return end

    f.nodeID = nodeID
    f.treeLocked = treeLocked or false

    local icon, name, desc = GetNodeDisplayInfo(ni)
    f.icon:SetTexture(icon or 134400)

    -- Subtract 1: unlock entry is free, doesn't count as a spent point
    local current = math.max((ni.activeRank or 0) - 1, 0)
    local max = math.max((ni.maxRanks or 0) - 1, 0)
    f.rankText:SetText(max > 0 and (current .. "/" .. max) or "")

    local state = GetNodeState(nodeID, treeLocked)
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
    elseif state == "selectable" then
        -- Locked but ready to unlock — bright with glow
        f.icon:SetDesaturated(false)
        f.icon:SetAlpha(0.85)
        f.lockIcon:Hide()
        f.glow:Show()
        f.rankText:SetTextColor(unpack(ns.COLORS.accent))
    elseif state == "available" then
        -- Progressing and can spend — bronze glow
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
    else
        -- progress: in progress but can't spend right now
        f.icon:SetDesaturated(false)
        f.icon:SetAlpha(1)
        f.lockIcon:Hide()
        f.glow:Hide()
        f.rankText:SetTextColor(unpack(ns.COLORS.brightText))
    end

    f:Show()
end

--------------------------------------------------------------------
-- Tree box creation
--------------------------------------------------------------------
local function GetOrCreateTreeBox(index)
    if treeBoxes[index] then return treeBoxes[index] end

    local box = CreateFrame("Frame", nil, treeArea, "BackdropTemplate")
    box:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    box:SetBackdropColor(14/255, 14/255, 14/255, 0.92)
    box:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    box.title = box:CreateFontString(nil, "OVERLAY")
    box.title:SetFont(ns.FONT, 12, "OUTLINE")
    box.title:SetPoint("TOP", box, "TOP", 0, -5)
    box.title:SetTextColor(unpack(ns.COLORS.accent))

    -- Content frame for nodes (inside box, below title)
    box.content = CreateFrame("Frame", nil, box)
    box.content:SetPoint("TOPLEFT", box, "TOPLEFT", BOX_PAD, -(BOX_TITLE_H))
    box.content:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -BOX_PAD, BOX_PAD)

    treeBoxes[index] = box
    treeBoxLines[index] = {}
    return box
end

--------------------------------------------------------------------
-- Render all trees
--------------------------------------------------------------------
local function RenderAllTrees()
    if not configID then return end

    -- Hide everything
    for _, f in pairs(nodeFrames) do f:Hide() end
    for i, box in ipairs(treeBoxes) do
        box:Hide()
        for _, line in ipairs(treeBoxLines[i] or {}) do
            line:Hide()
            line:ClearAllPoints()
        end
        wipe(treeBoxLines[i] or {})
    end

    specTabIDs = C_ProfSpecs.GetSpecTabIDsForSkillLine(skillLineID) or {}
    if #specTabIDs == 0 then return end

    -- Build trees
    local trees = {}
    for i, tabID in ipairs(specTabIDs) do
        local rootPathID = C_ProfSpecs.GetRootPathForTab(tabID)
        if rootPathID then
            local allNodes, childrenOf, positions = BuildTreeLayout(rootPathID)
            local tabInfo = C_ProfSpecs.GetTabInfo(tabID)
            local minX, minY, maxX, maxY = GetBounds(positions)
            table.insert(trees, {
                tabID = tabID,
                rootPathID = rootPathID,
                allNodes = allNodes,
                childrenOf = childrenOf,
                positions = positions,
                name = (tabInfo and tabInfo.name) or ("Spec " .. i),
                minX = minX, maxX = maxX,
                minY = minY, maxY = maxY,
            })
        end
    end
    if #trees == 0 then return end

    -- Compute box sizes first, then arrange
    local boxSizes = {}  -- idx → { w, h }
    for idx, t in ipairs(trees) do
        local contentW = (t.maxX - t.minX) + NODE_SIZE
        local contentH = (t.maxY - t.minY) + NODE_SIZE
        local boxW = math.max(contentW + BOX_PAD * 2, 100)
        local boxH = math.max(contentH + BOX_PAD + BOX_TITLE_H, 80)
        boxSizes[idx] = { w = boxW, h = boxH }
    end

    -- Determine box arrangement: saved layout (for ordering) or left-to-right
    -- Saved layout Y values are used to cluster into rows, X for column order
    -- Then auto-pack tightly using actual box sizes
    local hasSavedBoxLayout = SAVED_BOX_LAYOUT[trees[1].rootPathID] ~= nil
    local boxPositions = {}  -- idx → { x, y }

    if hasSavedBoxLayout then
        -- Build sorted list with saved positions for row/col clustering
        local sorted = {}
        for idx, t in ipairs(trees) do
            local sb = SAVED_BOX_LAYOUT[t.rootPathID] or { x = 0, y = 0 }
            table.insert(sorted, { idx = idx, sx = sb.x, sy = sb.y })
        end
        -- Sort by Y then X to determine row/col order
        table.sort(sorted, function(a, b)
            if math.abs(a.sy - b.sy) > 80 then return a.sy < b.sy end
            return a.sx < b.sx
        end)
        -- Cluster into rows (boxes within 80px Y of each other = same row)
        local rows = {}
        local curRow = { sorted[1] }
        local curRowY = sorted[1].sy
        for i = 2, #sorted do
            if math.abs(sorted[i].sy - curRowY) <= 80 then
                table.insert(curRow, sorted[i])
            else
                table.insert(rows, curRow)
                curRow = { sorted[i] }
                curRowY = sorted[i].sy
            end
        end
        table.insert(rows, curRow)

        -- Auto-pack: each row starts after tallest box in previous row + gap
        local rowY = 0
        for _, row in ipairs(rows) do
            -- Sort columns within row by saved X
            table.sort(row, function(a, b) return a.sx < b.sx end)
            local colX = 0
            local rowMaxH = 0
            for _, entry in ipairs(row) do
                local sz = boxSizes[entry.idx]
                boxPositions[entry.idx] = { x = colX, y = rowY }
                colX = colX + sz.w + BOX_GAP
                if sz.h > rowMaxH then rowMaxH = sz.h end
            end
            rowY = rowY + rowMaxH + BOX_GAP
        end
    else
        -- Simple left-to-right flow
        local cursorX = 0
        for idx in ipairs(trees) do
            boxPositions[idx] = { x = cursorX, y = 0 }
            cursorX = cursorX + boxSizes[idx].w + BOX_GAP
        end
    end

    -- Create/update tree boxes with computed positions
    for idx, t in ipairs(trees) do
        local box = GetOrCreateTreeBox(idx)
        local tabState = C_ProfSpecs.GetStateForTab(t.tabID, configID)
        local isLocked = (tabState == Enum.ProfessionsSpecTabState.Locked)

        local sz = boxSizes[idx]
        box:SetSize(sz.w, sz.h)
        box:ClearAllPoints()

        local bp = boxPositions[idx]
        box:SetPoint("TOPLEFT", treeArea, "TOPLEFT", bp.x, -bp.y)

        box.title:SetText(t.name)

        if isLocked then
            box.title:SetTextColor(0.4, 0.4, 0.4)
            box:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        else
            box.title:SetTextColor(unpack(ns.COLORS.accent))
            box:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
        end

        -- Node position inside box content:
        -- node CENTER at (pos.x - minX + NODE_SIZE/2, pos.y - minY + NODE_SIZE/2) from TOPLEFT of content
        local function NodePos(pos)
            return (pos.x - t.minX) + NODE_SIZE / 2,
                   (pos.y - t.minY) + NODE_SIZE / 2
        end

        -- Create/update nodes first (need frame refs for line anchoring)
        for _, pathID in ipairs(t.allNodes) do
            local pos = t.positions[pathID]
            if pos then
                local px, py = NodePos(pos)
                local f = nodeFrames[pathID]
                if not f then
                    f = CreateNodeFrame(box.content, pathID)
                    nodeFrames[pathID] = f
                else
                    f:SetParent(box.content)
                end
                f:ClearAllPoints()
                f:SetPoint("CENTER", box.content, "TOPLEFT", px, -py)
                f:SetFrameLevel(box.content:GetFrameLevel() + 3)
                UpdateNodeFrame(f, pathID, isLocked)
            end
        end

        -- Draw lines anchored to node frames (same approach as KSL)
        local lines = treeBoxLines[idx]
        for _, pathID in ipairs(t.allNodes) do
            local parentFrame = nodeFrames[pathID]
            if parentFrame and parentFrame:IsShown() then
                for _, childID in ipairs(t.childrenOf[pathID] or {}) do
                    local childFrame = nodeFrames[childID]
                    if childFrame and childFrame:IsShown() then
                        local line = box.content:CreateLine(nil, "ARTWORK")
                        line:SetThickness(LINE_THICKNESS)
                        line:SetStartPoint("CENTER", parentFrame)
                        line:SetEndPoint("CENTER", childFrame)

                        local cs = GetNodeState(childID, isLocked)
                        local ps = GetNodeState(pathID, isLocked)
                        if ps ~= "locked" and cs ~= "locked" then
                            line:SetColorTexture(200/255, 170/255, 100/255, 0.8)
                        elseif ps ~= "locked" or cs ~= "locked" then
                            line:SetColorTexture(200/255, 170/255, 100/255, 0.4)
                        else
                            line:SetColorTexture(0.3, 0.3, 0.3, 0.4)
                        end
                        line:Show()
                        table.insert(lines, line)
                    end
                end
            end
        end

        box:Show()
    end

    -- Hide extra boxes
    for i = #trees + 1, #treeBoxes do
        treeBoxes[i]:Hide()
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

    -- Points bar at the top
    pointsText = parent:CreateFontString(nil, "OVERLAY")
    pointsText:SetFont(ns.FONT, 13, "")
    pointsText:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -4)
    pointsText:SetTextColor(unpack(ns.COLORS.brightText))

    -- Main canvas area
    canvasFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    canvasFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(POINTS_BAR_HEIGHT + 4))
    canvasFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    canvasFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    canvasFrame:SetBackdropColor(8/255, 8/255, 8/255, 0.6)
    canvasFrame:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
    canvasFrame:SetClipsChildren(true)

    -- Bottom bar for Apply/Reset buttons
    local BOTTOM_BAR_H = 32
    local bottomBar = CreateFrame("Frame", nil, canvasFrame)
    bottomBar:SetHeight(BOTTOM_BAR_H)
    bottomBar:SetPoint("BOTTOMLEFT", canvasFrame, "BOTTOMLEFT", 8, 4)
    bottomBar:SetPoint("BOTTOMRIGHT", canvasFrame, "BOTTOMRIGHT", -(DETAIL_WIDTH + 8), 4)

    -- Apply Changes button (always visible, lights up when staged changes)
    local applyBtn = CreateFrame("Button", nil, bottomBar, "BackdropTemplate")
    applyBtn:SetSize(140, 26)
    applyBtn:SetPoint("RIGHT", bottomBar, "RIGHT", 0, 0)
    applyBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    applyBtn.text = applyBtn:CreateFontString(nil, "OVERLAY")
    applyBtn.text:SetFont(ns.FONT, 12, "OUTLINE")
    applyBtn.text:SetPoint("CENTER")
    applyBtn.text:SetText("Apply Changes")
    applyBtn:SetScript("OnClick", function()
        if not configID then return end
        if InCombatLockdown() then return end
        if not C_Traits.ConfigHasStagedChanges(configID) then return end
        C_Traits.CommitConfig(configID)
    end)

    -- Undo button (always visible, lights up when staged changes)
    local undoBtn = CreateFrame("Button", nil, bottomBar, "BackdropTemplate")
    undoBtn:SetSize(80, 26)
    undoBtn:SetPoint("RIGHT", applyBtn, "LEFT", -6, 0)
    undoBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    undoBtn.text = undoBtn:CreateFontString(nil, "OVERLAY")
    undoBtn.text:SetFont(ns.FONT, 12, "OUTLINE")
    undoBtn.text:SetPoint("CENTER")
    undoBtn.text:SetText("Undo")
    undoBtn:SetScript("OnClick", function()
        if not configID then return end
        if not C_Traits.ConfigHasStagedChanges(configID) then return end
        C_Traits.RollbackConfig(configID)
        ProfSpecs:Refresh()
    end)

    -- Dim/lit state helpers
    local function SetButtonDim(btn)
        btn:SetBackdropColor(0.08, 0.08, 0.08, 0.8)
        btn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        btn.text:SetTextColor(0.35, 0.35, 0.35)
        btn:SetScript("OnEnter", nil)
        btn:SetScript("OnLeave", nil)
    end

    local function SetApplyLit()
        applyBtn:SetBackdropColor(0.08, 0.14, 0.06, 1)
        applyBtn:SetBackdropBorderColor(0.3, 0.85, 0.3, 1)
        applyBtn.text:SetTextColor(0.3, 0.9, 0.3)
        applyBtn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(0.4, 1, 0.4, 1)
            self.text:SetTextColor(0.4, 1, 0.4)
        end)
        applyBtn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.3, 0.85, 0.3, 1)
            self.text:SetTextColor(0.3, 0.9, 0.3)
        end)
    end

    local function SetUndoLit()
        undoBtn:SetBackdropColor(0.14, 0.08, 0.06, 1)
        undoBtn:SetBackdropBorderColor(0.7, 0.4, 0.3, 1)
        undoBtn.text:SetTextColor(0.85, 0.5, 0.4)
        undoBtn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(0.9, 0.5, 0.4, 1)
            self.text:SetTextColor(1, 0.6, 0.5)
        end)
        undoBtn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.7, 0.4, 0.3, 1)
            self.text:SetTextColor(0.85, 0.5, 0.4)
        end)
    end

    -- Update button states based on staged changes
    function ProfSpecs.UpdateApplyButton()
        if not configID then
            SetButtonDim(applyBtn)
            SetButtonDim(undoBtn)
            return
        end
        local hasChanges = C_Traits.ConfigHasStagedChanges(configID)
        if hasChanges then
            SetApplyLit()
            SetUndoLit()
        else
            SetButtonDim(applyBtn)
            SetButtonDim(undoBtn)
        end
    end

    -- Left: tree area (boxes go here)
    treeArea = CreateFrame("Frame", nil, canvasFrame)
    treeArea:SetPoint("TOPLEFT", canvasFrame, "TOPLEFT", 8, -8)
    treeArea:SetPoint("BOTTOMRIGHT", canvasFrame, "BOTTOMRIGHT", -(DETAIL_WIDTH + 8), BOTTOM_BAR_H + 8)

    -- Right: detail panel
    detailPanel = CreateDetailPanel(canvasFrame)
    ClearDetailPanel()

    -- Events
    local ef = CreateFrame("Frame")
    ef:RegisterEvent("TRAIT_NODE_CHANGED")
    ef:RegisterEvent("TRAIT_CONFIG_UPDATED")
    ef:RegisterEvent("SKILL_LINE_SPECS_RANKS_CHANGED")
    ef:RegisterEvent("SKILL_LINE_SPECS_UNLOCKED")
    ef:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    ef:SetScript("OnEvent", function(self, event, ...)
        if not ProfSpecs:IsShown() then return end
        if event == "TRAIT_NODE_CHANGED" then
            -- Full refresh: spending a point can unlock neighboring nodes
            ProfSpecs:Refresh()
        elseif event == "CURRENCY_DISPLAY_UPDATE" then
            UpdatePointsDisplay()
        else
            ProfSpecs:Refresh()
        end
    end)
end

function ProfSpecs:Show()
    if not initialized then return end

    local profInfo = C_TradeSkillUI.GetChildProfessionInfo()
    skillLineID = profInfo and profInfo.professionID or nil

    if not skillLineID or not C_ProfSpecs.SkillLineHasSpecialization(skillLineID) then
        canvasFrame:Hide()
        pointsText:SetText("No specializations available for this profession.")
        pointsText:Show()
        return
    end

    configID = C_ProfSpecs.GetConfigIDForSkillLine(skillLineID)
    C_Traits.StageConfig(configID)

    canvasFrame:Show()
    pointsText:Show()
    UpdatePointsDisplay()
    ClearDetailPanel()
    RenderAllTrees()
    ProfSpecs.UpdateApplyButton()
end

function ProfSpecs:Hide()
    if not initialized then return end
    if canvasFrame then canvasFrame:Hide() end
    if pointsText then pointsText:Hide() end
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
    UpdatePointsDisplay()
    RenderAllTrees()
    ProfSpecs.UpdateApplyButton()
end
