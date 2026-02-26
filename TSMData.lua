--------------------------------------------------------------------
-- TSMData.lua — Standalone TSM price data reader
-- Reads pricing data from TradeSkillMaster_AppHelper (desktop app)
-- without requiring the full TradeSkillMaster addon (134 MB)
--
-- AppHelper's AppData.lua is written by the TSM desktop app with
-- AH scan data. We intercept that data via TSM_APPHELPER_LOAD_DATA
-- and parse it ourselves. If full TSM IS loaded, we delegate to
-- TSM_API instead.
--------------------------------------------------------------------

local _, ns = ...

local TSMData = {}
ns.TSMData = TSMData

--------------------------------------------------------------------
-- Tag categories (which data goes where)
--------------------------------------------------------------------
local REALM_TAGS = {
    AUCTIONDB_NON_COMMODITY_DATA = true,
    AUCTIONDB_NON_COMMODITY_SCAN_STAT = true,
}
local REGION_TAGS = {
    AUCTIONDB_REGION_STAT = true,
    AUCTIONDB_REGION_HISTORICAL = true,
    AUCTIONDB_REGION_SALE = true,
}
local COMMODITY_TAGS = {
    AUCTIONDB_COMMODITY_DATA = true,
    AUCTIONDB_COMMODITY_SCAN_STAT = true,
}

--------------------------------------------------------------------
-- Raw data storage (filled by our global hook)
--------------------------------------------------------------------
local rawStore = {}      -- ["tag|realmOrRegion"] = raw Lua string
local parsedStore = {}   -- same key → parsed table (or false)
local dataAvailable = false

--------------------------------------------------------------------
-- Define TSM_APPHELPER_LOAD_DATA global BEFORE AppHelper loads
-- KazCraft (K) loads before TradeSkillMaster_AppHelper (T)
-- If full TSM is also loaded, TSM (T) overwrites this global
-- before AppHelper (T_A) runs — we detect TSM_API and delegate
--------------------------------------------------------------------
if not TSM_APPHELPER_LOAD_DATA then
    function TSM_APPHELPER_LOAD_DATA(tag, realmOrRegion, data)
        if type(tag) ~= "string" or type(data) ~= "string" then return end
        if REALM_TAGS[tag] or REGION_TAGS[tag] or COMMODITY_TAGS[tag] then
            rawStore[tag .. "|" .. realmOrRegion] = data
            dataAvailable = true
        end
    end
end

--------------------------------------------------------------------
-- Data parsing — mirrors TSM's AuctionDB/Core.lua logic
--------------------------------------------------------------------

-- Parse raw data string into { fieldLookup = {key→idx}, itemLookup = {itemString→data} }
local function ParseRawData(rawStr)
    -- rawStr = "return {downloadTime=...,fields={...},data={{...},...}}"
    local metaEnd, dataStart = rawStr:find(",data={")
    if not metaEnd then return nil end

    -- Metadata: everything before ",data={" + closing brace
    local metaStr = rawStr:sub(1, metaEnd - 1) .. "}"
    local fn = loadstring(metaStr)
    if not fn then return nil end
    local ok, metadata = pcall(fn)
    if not ok or not metadata or not metadata.fields then return nil end

    -- Item data: between "data={" opening and final "}}"
    local itemDataStr = rawStr:sub(dataStart + 1, -3)

    local result = { fieldLookup = {}, itemLookup = {} }
    -- fields[1] is always "itemString" — skip it, index remaining from 1
    for i = 2, #metadata.fields do
        result.fieldLookup[metadata.fields[i]] = i - 1
    end

    -- Parse entries: {itemString,val1,val2,...}
    for itemStr, otherData in itemDataStr:gmatch('{\"?([^,"]+)\"?,([^}]+)}') do
        if tonumber(itemStr) then
            itemStr = "i:" .. itemStr
        end
        result.itemLookup[itemStr] = otherData
    end

    return result
end

-- Unpack base-32 encoded comma-separated values for one item
-- TSM encodes prices as base-32 strings (Lua's tonumber(str, 32))
-- Values > 6 chars are split: last 6 chars + remainder × 2^30
local function UnpackItem(tbl, itemString)
    local data = tbl.itemLookup[itemString]
    if type(data) ~= "string" then return data end  -- already unpacked

    local parts = { strsplit(",", data) }
    for i = 1, #parts do
        local v = parts[i]
        if #v > 6 then
            parts[i] = tonumber(v:sub(-6), 32) + tonumber(v:sub(1, -7), 32) * (2 ^ 30)
        else
            parts[i] = tonumber(v, 32)
        end
    end
    tbl.itemLookup[itemString] = parts  -- cache unpacked
    return parts
end

--------------------------------------------------------------------
-- TSM price key → raw AuctionDB field name
--------------------------------------------------------------------
local KEY_MAP = {
    DBMinBuyout       = "minBuyout",
    DBMarket          = "marketValue",
    DBRecent          = "marketValueRecent",
    DBHistorical      = "historical",
    DBRegionMarketAvg = "regionMarketValue",
    DBRegionHistorical = "regionHistorical",
    DBRegionSaleAvg   = "regionSale",
}

--------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------

-- GetPrice(itemID, priceKey) → copper value or nil
-- priceKey: "DBMinBuyout", "DBMarket", "DBHistorical", etc.
function TSMData:GetPrice(itemID, priceKey)
    -- If full TSM is loaded, delegate to its API
    if TSM_API and TSM_API.GetCustomPriceValue then
        local ok, val = pcall(TSM_API.GetCustomPriceValue, priceKey, "i:" .. itemID)
        return ok and val or nil
    end

    if not dataAvailable then return nil end

    local fieldKey = KEY_MAP[priceKey]
    if not fieldKey then return nil end

    local itemString = "i:" .. itemID

    -- Search all stored data tables for this item + field
    for storeKey, rawStr in pairs(rawStore) do
        -- Lazy parse on first access
        if parsedStore[storeKey] == nil then
            parsedStore[storeKey] = ParseRawData(rawStr) or false
        end
        local tbl = parsedStore[storeKey]
        if tbl then
            local fieldIdx = tbl.fieldLookup[fieldKey]
            if fieldIdx and tbl.itemLookup[itemString] then
                local data = UnpackItem(tbl, itemString)
                if data and data[fieldIdx] and data[fieldIdx] > 0 then
                    return data[fieldIdx]
                end
            end
        end
    end
    return nil
end

-- Check if price data is available (either TSM_API or our parsed data)
function TSMData:IsAvailable()
    return dataAvailable or (TSM_API ~= nil)
end
