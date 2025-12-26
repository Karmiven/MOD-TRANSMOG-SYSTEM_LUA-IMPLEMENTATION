-- [Author : Thiesant] This script is free, if you bought it you got scammed.
-- v0.4
    -- ============================================================================

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║                   MOD-TRANSMOG-SYSTEM — LUA IMPLEMENTATION                   ║
-- ╠══════════════════════════════════════════════════════════════════════════════╣
-- ║ Requirements:                                                                ║
-- ║  • AzerothCore's "Eluna" Framework (mod-ale)                                 ║
-- ║  • AIO addon framework                                                       ║
-- ║  • Characters database tables (import .sql to Acore_characters)              ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║                               TRANSMOG OPTIONS                               ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- Values  : true or false
-- Default : true

-- ──────────────────────────────────── SCRIPT ────────────────────────────────────

-- ENABLE_AIO_BRIDGE
-- Set to false if you need to desactivate full script
-- Client Addon will be unable to querry collected items or use/save transmog
local ENABLE_AIO_BRIDGE = true


-- ────────────────────────────────── LOGIN SCAN ──────────────────────────────────

-- ENABLE_SCAN_ITEMS
-- Workaround for missing hooks: scans full inventory on login (bags, bank, equipement)
local ENABLE_SCAN_ITEMS = true

-- ENABLE_SCAN_QUESTS
-- Sync quest items done prior to script installation
local ENABLE_SCAN_QUESTS = true


-- ────────────────────────── COLLECTION ON PLAYER LOGIN ──────────────────────────

-- COLLECTION_ON_CHARACTER_LOGIN_SCANNED_ITEMS
-- In pair with ENABLE_SCAN_ITEMS : allow to add items on collection from scan results
-- This is used for item from trade, mail, repurchased from vendor, item restoration
local COLLECTION_ON_CHARACTER_LOGIN_SCANNED_ITEMS = true

-- COLLECTION_ON_PREVIOUS_QUESTS
-- In pair with ENABLE_SCAN_QUESTS : allow to add items on collection from scan results
-- This is used to add items to collection from ongoing and turned quests prior to 
-- this script installation, containers rewards are skipped to avoid abuse
local COLLECTION_ON_PREVIOUS_QUESTS = true


-- ─────────────────────────────── COLLECTION RULES ───────────────────────────────
-- The following descriptions are not exhaustive, you should let them on true unless
-- You intend to make strict rules for new transmo aquisition

-- Item equipped on character slot
local COLLECTION_ON_EQUIP                  = true

-- Item from corpse, pickpocket
local COLLECTION_ON_LOOT_ITEM              = true

-- Item rewarded from quest
local COLLECTION_ON_QUEST_REWARD_ITEM      = true

-- Item crafted
local COLLECTION_ON_CREATE_ITEM            = true

-- Item obtained from character creation or master loot
local COLLECTION_ON_STORE_NEW_ITEM         = true

-- Item rewarded from quest and choices rewards
local COLLECTION_ON_COMPLETE_QUEST         = true

-- Item earned from dice roll
local COLLECTION_ON_GROUP_ROLL_REWARD_ITEM = true


-- ────────────────────────────── TRANSMOGRIFICATION ──────────────────────────────

-- OnPlayerLogin : Force to refresh actives transmog
local ENABLE_APPLY_ALL_TRANSMOGS = true

-- If set to false, player won't be able to use transmog appearance though,
-- they are still able to save them in server DB no matter the setting
local ENABLE_TRANSMOG_APPLY_TRANSMOG_VISUAL = true

-- ALLOW_UNCOLLECTED_TRANSMOG
-- Set to true to allow players to apply transmog from items they haven't collected
-- When true, players can use any valid transmog appearance (useful for testing or custom servers)
-- When false (default), players must have the item in their collection to use it
local ALLOW_UNCOLLECTED_TRANSMOG = false


-- ───────────────────────────────── ITEM QUALITY ─────────────────────────────────

-- Allowed item qualities for transmog (by quality ID)
-- 0 = Poor, 1 = Common, 2 = Uncommon, 3 = Rare, 4 = Epic, 5 = Legendary, 6 = Heirloom
local ALLOWED_QUALITIES = {
    [0] = true,
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true,
    [6] = true,
}


-- ──────────────────────────────── ITEM BLACKLIST ────────────────────────────────

-- Items in this list will be excluded from:
-- - Transmog collection (won't be added when looted/equipped)
-- - Search results
-- - Grid display (even if somehow collected)
-- Format: [itemId] = true
local ITEM_BLACKLIST = {
--    [17182] = true, -- Sulfuras, Hand of Ragnaros
}

-- Helper function to check if item is blacklisted
local function IsItemBlacklisted(itemId)
    return ITEM_BLACKLIST[itemId] == true
end


-- ───────────────────────────────── DEBUG TOGGLE ─────────────────────────────────

-- ENABLE_DEBUG_MESSAGES
-- Set to false to disable debug messages in the server console
local ENABLE_DEBUG_MESSAGES = false


-- ──────────────────────────────── CACHE VERSION# ────────────────────────────────

-- CACHE_VERSION
-- Controls the client-side cache version. Clients compare their stored version
-- with this value - if different, they re-download the full item cache.
-- 
-- IMPORTANT: Only increment this number when the transmog item database changes:
--   - New items added to world database
--   - Items added/removed from ITEM_BLACKLIST
--   - ALLOWED_QUALITIES changes
--   - Any change affecting which items appear in the transmog grid
--
-- If not changed, clients keep their cached item list across server restarts,
-- significantly reducing login bandwidth and database load.
local CACHE_VERSION = 1

	
-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║                                    SCRIPT                                    ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- Helper function for debug printing
local function DebugPrint(message)
    if ENABLE_DEBUG_MESSAGES then
        print(message)
    end
end



if ENABLE_AIO_BRIDGE then
    
    local AIO = AIO or require("AIO")
    
    -- ============================================================================
    -- SERVER STARTUP CACHE SYSTEM
    -- ============================================================================
    -- This cache is built ONCE on server startup and shared with all clients.
    -- Clients store this cache locally with a version number.
    -- If server version matches client version, no retransmission needed.
    -- ============================================================================

    -- Global cache storage (populated on server startup)
    local SERVER_ITEM_CACHE = {
        version = 0,              -- Cache version (uses CACHE_VERSION setting)
        isReady = false,          -- Flag indicating cache is built
        bySlot = {},              -- Items indexed by slot: bySlot[slotId] = { {itemId, class, subclass, quality, displayId}, ... }
        enchants = {},            -- All enchant visuals
    }

    -- Client cache versions (tracks what version each client has)
    local ClientCacheVersions = {}  -- [accountId] = {items = version, enchants = version}
    
    -- ============================================================================
    -- Transmog Slot Definitions
    -- ============================================================================
    
    local TRANSMOG_SLOTS = {
        [0]  = true,  -- Head
        [2]  = true,  -- Shoulder
        [3]  = true,  -- Shirt
        [4]  = true,  -- Chest
        [5]  = true,  -- Waist
        [6]  = true,  -- Legs
        [7]  = true,  -- Feet
        [8]  = true,  -- Wrist
        [9]  = true,  -- Hands
        [14] = true,  -- Back
        [15] = true,  -- MainHand
        [16] = true,  -- OffHand
        [17] = true,  -- Ranged
        [18] = true,  -- Tabard
    }
    
    -- ============================================================================
    -- Subclass Mappings (Name to DB ID)
    -- ============================================================================
    
    -- Armor subclass: name -> subclass ID
    local ARMOR_SUBCLASS = {
        ["Miscellaneous"] = 0,
        ["Cloth"]         = 1,
        ["Leather"]       = 2,
        ["Mail"]          = 3,
        ["Plate"]         = 4,
        ["Shield"]        = 6,
    }
    
    -- Weapon subclass: name -> subclass ID
    local WEAPON_SUBCLASS = {
        ["Axe1H"]    = 0,
        ["Axe2H"]    = 1,
        ["Bow"]      = 2,
        ["Gun"]      = 3,
        ["Mace1H"]   = 4,
        ["Mace2H"]   = 5,
        ["Polearm"]  = 6,
        ["Sword1H"]  = 7,
        ["Sword2H"]  = 8,
        ["Staff"]    = 10,
        ["Fist"]     = 13,
        ["Dagger"]   = 15,
        ["Thrown"]   = 16,
        ["Crossbow"] = 18,
        ["Wand"]     = 19,
        ["Fishing"]  = 20,
    }
    
    -- Combined lookup
    local function GetSubclassId(subclassName)
        if ARMOR_SUBCLASS[subclassName] then
            return 4, ARMOR_SUBCLASS[subclassName]  -- class 4 = Armor
        elseif WEAPON_SUBCLASS[subclassName] then
            return 2, WEAPON_SUBCLASS[subclassName] -- class 2 = Weapon
    	end
        -- For other classes (like Miscellaneous), we determine by inventory type
        return nil, nil
    end
    
    -- Slot to inventory types mapping
    local SLOT_INV_TYPES = {
        [0]  = {1},                      -- Head
        [2]  = {3},                      -- Shoulder
        [3]  = {4},                      -- Shirt
        [4]  = {5, 20},                  -- Chest/Robe
        [5]  = {6},                      -- Waist
        [6]  = {7},                      -- Legs
        [7]  = {8},                      -- Feet
        [8]  = {9},                      -- Wrist
        [9]  = {10},                     -- Hands
        [14] = {16},                     -- Back (cloak)
        [18] = {19},                     -- Tabard
        [15] = {13, 17, 21},             -- MainHand
        [16] = {13, 14, 17, 21, 22, 23}, -- OffHand
        [17] = {15, 25, 26},             -- Ranged
    }
    
    -- Inventory type to slot mapping (reverse of above)
    local INV_TYPE_TO_SLOT = {
        [1]  = 0,   -- INVTYPE_HEAD
        [3]  = 2,   -- INVTYPE_SHOULDERS
        [4]  = 3,   -- INVTYPE_BODY (Shirt)
        [5]  = 4,   -- INVTYPE_CHEST
        [20] = 4,   -- INVTYPE_ROBE
        [6]  = 5,   -- INVTYPE_WAIST
        [7]  = 6,   -- INVTYPE_LEGS
        [8]  = 7,   -- INVTYPE_FEET
        [9]  = 8,   -- INVTYPE_WRISTS
        [10] = 9,   -- INVTYPE_HANDS
        [16] = 14,  -- INVTYPE_CLOAK
        [19] = 18,  -- INVTYPE_TABARD
        [13] = 15,  -- INVTYPE_WEAPON
        [17] = 15,  -- INVTYPE_2HWEAPON
        [21] = 15,  -- INVTYPE_WEAPONMAINHAND
        [14] = 16,  -- INVTYPE_SHIELD
        [22] = 16,  -- INVTYPE_WEAPONOFFHAND
        [23] = 16,  -- INVTYPE_HOLDABLE
        [15] = 17,  -- INVTYPE_RANGED
        [25] = 17,  -- INVTYPE_THROWN
        [26] = 17,  -- INVTYPE_RANGEDRIGHT
    }
    
    -- ============================================================================
    -- SERVER CACHE INITIALIZATION (Async)
    -- ============================================================================
    -- Build the full item cache on server startup using async queries
    -- This happens ONCE and the cache is shared with all clients
    -- ============================================================================
    
    -- Forward declaration for BuildServerEnchantCacheAsync
    local BuildServerEnchantCacheAsync
    
    local function BuildServerItemCacheAsync()
        DebugPrint("[mod-transmog-system] Building server item cache (async)...")
        
        -- Use configurable cache version (only changes when admin updates CACHE_VERSION setting)
        SERVER_ITEM_CACHE.version = CACHE_VERSION
        SERVER_ITEM_CACHE.bySlot = {}
        
        -- Initialize all slot tables
        for slotId, _ in pairs(SLOT_INV_TYPES) do
            SERVER_ITEM_CACHE.bySlot[slotId] = {}
        end
        
        -- Build quality filter for allowed qualities
        local qualityList = {}
        for q, allowed in pairs(ALLOWED_QUALITIES) do
            if allowed then
                table.insert(qualityList, q)
            end
        end
        local qualityFilter = table.concat(qualityList, ",")
        
        -- Query ALL transmog-eligible items at once (async) - includes displayid
        local sql = string.format(
            "SELECT entry, class, subclass, InventoryType, Quality, displayid FROM item_template " ..
            "WHERE displayid > 0 AND Quality IN (%s) ORDER BY entry",
            qualityFilter
        )
        
        WorldDBQueryAsync(sql, function(Q)
            if Q then
                local count = 0
                repeat
                    local itemId = Q:GetUInt32(0)
                    local itemClass = Q:GetUInt8(1)
                    local itemSubclass = Q:GetUInt8(2)
                    local invType = Q:GetUInt8(3)
                    local quality = Q:GetUInt8(4)
                    local displayId = Q:GetUInt32(5)
                    
                    -- Map inventory type to slot
                    local slotId = INV_TYPE_TO_SLOT[invType]
                    
                    -- Skip blacklisted items and items without a valid slot
                    if slotId and not IsItemBlacklisted(itemId) then
                        -- Store compact item data: {itemId, class, subclass, quality, displayId}
                        table.insert(SERVER_ITEM_CACHE.bySlot[slotId], {
                            itemId,
                            itemClass,
                            itemSubclass,
                            quality,
                            displayId
                        })
                        count = count + 1
                    end
                until not Q:NextRow()
                
                DebugPrint(string.format("[mod-transmog-system] Cached %d items across all slots", count))
                
                -- Now load enchants (also async)
                BuildServerEnchantCacheAsync()
            else
                print("[mod-transmog-system] ERROR: Failed to build item cache!")
                SERVER_ITEM_CACHE.isReady = false
            end
        end)
    end
    
    -- Define BuildServerEnchantCacheAsync (declared above)
    BuildServerEnchantCacheAsync = function()
        DebugPrint("[mod-transmog-system] Building enchant cache (async)...")
        
        CharDBQueryAsync(
            "SELECT id, item_visual, name_enUS, icon FROM mod_transmog_system_enchantment ORDER BY id",
            function(Q)
                SERVER_ITEM_CACHE.enchants = {}
                if Q then
                    repeat
                        table.insert(SERVER_ITEM_CACHE.enchants, {
                            id = Q:GetUInt32(0),
                            itemVisual = Q:GetUInt32(1),
                            name = Q:GetString(2),
                            icon = Q:GetString(3)
                        })
                    until not Q:NextRow()
                    
                    DebugPrint(string.format("[mod-transmog-system] Cached %d enchant visuals", #SERVER_ITEM_CACHE.enchants))
                end
                
                -- Mark cache as ready
                SERVER_ITEM_CACHE.isReady = true
                DebugPrint(string.format("[mod-transmog-system] Server cache ready! Version: %d", SERVER_ITEM_CACHE.version))
            end
        )
    end
       
    -- Helper function to get item template from world database
    local itemTemplateCache = {}
    
    local function GetItemTemplate(itemId)
        if itemTemplateCache[itemId] then
            return itemTemplateCache[itemId]
        end
        
        local query = WorldDBQuery(string.format(
            "SELECT class, subclass, displayid, InventoryType, Quality FROM item_template WHERE entry = %d",
            itemId
        ))
        
        if not query then
            return nil
        end
        
        local template = {
            class = query:GetUInt8(0),
            subclass = query:GetUInt8(1),
            displayid = query:GetUInt32(2),
            inventoryType = query:GetUInt8(3),
            quality = query:GetUInt8(4),  -- Add this line
        }
        
        itemTemplateCache[itemId] = template
        return template
    end
    
    -- ============================================================================
    -- Database Queries
    -- ============================================================================
    
    local function GetPlayerCollection(accountId)
        local query = CharDBQuery(string.format(
            "SELECT item_id FROM mod_transmog_system_collection WHERE account_id = %d",
            accountId
        ))
        
        local items = {}
        if query then
            repeat
                local itemId = query:GetUInt32(0)
                -- Skip blacklisted items
                if not IsItemBlacklisted(itemId) then
                    table.insert(items, itemId)
                end
            until not query:NextRow()
        end
        return items
    end
    
    -- Async version of GetPlayerCollection
    local function GetPlayerCollectionAsync(accountId, callback)
        CharDBQueryAsync(
            string.format("SELECT item_id FROM mod_transmog_system_collection WHERE account_id = %d", accountId),
            function(Q)
                local items = {}
                if Q then
                    repeat
                        local itemId = Q:GetUInt32(0)
                        if not IsItemBlacklisted(itemId) then
                            table.insert(items, itemId)
                        end
                    until not Q:NextRow()
                end
                callback(items)
            end
        )
    end
    
    local function HasAppearance(accountId, itemId)
        local query = CharDBQuery(string.format(
            "SELECT 1 FROM mod_transmog_system_collection WHERE account_id = %d AND item_id = %d",
            accountId, itemId
        ))
        return query ~= nil
    end
    
    -- Async version of HasAppearance
    local function HasAppearanceAsync(accountId, itemId, callback)
        CharDBQueryAsync(
            string.format("SELECT 1 FROM mod_transmog_system_collection WHERE account_id = %d AND item_id = %d", accountId, itemId),
            function(Q)
                callback(Q ~= nil)
            end
        )
    end

    local function GetCollectionForSlotFiltered(accountId, slotId, subclassName, quality)
        local invTypes = SLOT_INV_TYPES[slotId]
        if not invTypes then return {} end
        
        local invTypeStr = table.concat(invTypes, ",")
        
        -- First get all items for this account
        local collectionQuery = CharDBQuery(string.format(
            "SELECT item_id FROM mod_transmog_system_collection WHERE account_id = %d",
            accountId
        ))
        
        if not collectionQuery then return {} end
        
        -- Build list of item IDs
        local itemIds = {}
        repeat
            table.insert(itemIds, collectionQuery:GetUInt32(0))
        until not collectionQuery:NextRow()
        
        if #itemIds == 0 then return {} end
        
        -- Now filter by item_template using WorldDBQuery
        local itemIdStr = table.concat(itemIds, ",")
        
        local query
        -- Build WHERE clause dynamically
        local whereConditions = {}
        table.insert(whereConditions, string.format("entry IN (%s)", itemIdStr))
        table.insert(whereConditions, string.format("InventoryType IN (%s)", invTypeStr))
        
        -- "All" or nil/empty means no subclass filter
        if subclassName and subclassName ~= "" and subclassName ~= "All" then
            local itemClass, itemSubclass = GetSubclassId(subclassName)
            if itemClass and itemSubclass then
                table.insert(whereConditions, string.format("class = %d", itemClass))
                table.insert(whereConditions, string.format("subclass = %d", itemSubclass))
            end
        end
        
        -- Quality filter
        if quality and quality ~= "" and quality ~= "All" then
            -- Map quality string to quality ID
            local qualityMap = {
                ["Poor"] = 0,
                ["Common"] = 1,
                ["Uncommon"] = 2,
                ["Rare"] = 3,
                ["Epic"] = 4,
                ["Legendary"] = 5,
                ["Heirloom"] = 6,
            }
            local qualityId = qualityMap[quality]
            if qualityId then
                table.insert(whereConditions, string.format("Quality = %d", qualityId))
            end
        end
        
        local whereClause = table.concat(whereConditions, " AND ")
        query = WorldDBQuery(string.format(
            "SELECT entry FROM item_template WHERE %s",
            whereClause
        ))
        
        local items = {}
        if query then
            repeat
                local itemId = query:GetUInt32(0)
                -- Skip blacklisted items
                if not IsItemBlacklisted(itemId) then
                    table.insert(items, itemId)
                end
            until not query:NextRow()
        end
        
        return items
    end

    -- NEW: Get ALL items for slot (both collected and uncollected) with collected status
    -- Returns array of {itemId, collected} sorted by collected first
    -- FIXED: Queries collected items first (all of them), then adds uncollected items
    local function GetAllItemsForSlotFiltered(accountId, slotId, subclassName, quality)
        local invTypes = SLOT_INV_TYPES[slotId]
        if not invTypes then return {} end
        
        local invTypeStr = table.concat(invTypes, ",")
        
        -- Build base WHERE conditions for item_template
        local baseConditions = {}
        table.insert(baseConditions, string.format("InventoryType IN (%s)", invTypeStr))
        table.insert(baseConditions, "displayid > 0")  -- Must have a visual
        
        -- Subclass filter
        if subclassName and subclassName ~= "" and subclassName ~= "All" then
            local itemClass, itemSubclass = GetSubclassId(subclassName)
            if itemClass and itemSubclass then
                table.insert(baseConditions, string.format("class = %d", itemClass))
                table.insert(baseConditions, string.format("subclass = %d", itemSubclass))
            end
        end
        
        -- Quality filter
        if quality and quality ~= "" and quality ~= "All" then
            local qualityMap = {
                ["Poor"] = 0,
                ["Common"] = 1,
                ["Uncommon"] = 2,
                ["Rare"] = 3,
                ["Epic"] = 4,
                ["Legendary"] = 5,
                ["Heirloom"] = 6,
            }
            local qualityId = qualityMap[quality]
            if qualityId then
                table.insert(baseConditions, string.format("Quality = %d", qualityId))
            end
        end
        
        -- Only include allowed qualities
        local qualityList = {}
        for q, allowed in pairs(ALLOWED_QUALITIES) do
            if allowed then
                table.insert(qualityList, q)
            end
        end
        table.insert(baseConditions, string.format("Quality IN (%s)", table.concat(qualityList, ",")))
        
        local baseWhereClause = table.concat(baseConditions, " AND ")
        
        -- STEP 1: Get player's collected item IDs from CharDB
        local collectedIdsList = {}
        local collectedIdsSet = {}
        
        local collectionQuery = CharDBQuery(string.format(
            "SELECT item_id FROM mod_transmog_system_collection WHERE account_id = %d",
            accountId
        ))
        
        if collectionQuery then
            repeat
                local itemId = collectionQuery:GetUInt32(0)
                table.insert(collectedIdsList, itemId)
                collectedIdsSet[itemId] = true
            until not collectionQuery:NextRow()
        end
        
        -- STEP 2: Get collected items that match slot/filters from WorldDB
        local collectedItems = {}
        
        if #collectedIdsList > 0 then
            local collectedIdsStr = table.concat(collectedIdsList, ",")
            local collectedQuery = WorldDBQuery(string.format(
                "SELECT entry FROM item_template WHERE entry IN (%s) AND %s",
                collectedIdsStr, baseWhereClause
            ))
            
            if collectedQuery then
                repeat
                    local itemId = collectedQuery:GetUInt32(0)
                    table.insert(collectedItems, { itemId = itemId, collected = true })
                until not collectedQuery:NextRow()
            end
        end
        
        -- STEP 3: Get uncollected items (no limit)
        local uncollectedItems = {}
        
        local uncollectedQuery = WorldDBQuery(string.format(
            "SELECT entry FROM item_template WHERE %s ORDER BY entry",
            baseWhereClause
        ))
        
        if uncollectedQuery then
            repeat
                local itemId = uncollectedQuery:GetUInt32(0)
                -- Only add if NOT in collected set and NOT blacklisted
                if not collectedIdsSet[itemId] and not IsItemBlacklisted(itemId) then
                    table.insert(uncollectedItems, { itemId = itemId, collected = false })
                end
            until not uncollectedQuery:NextRow()
        end
        
        -- Combine: collected first, then uncollected
        local result = {}
        for _, item in ipairs(collectedItems) do
            -- Filter out blacklisted items from collected as well
            if not IsItemBlacklisted(item.itemId) then
                table.insert(result, item)
            end
        end
        for _, item in ipairs(uncollectedItems) do
            table.insert(result, item)
        end
        
        return result
    end
    
    -- NEW: Get only UNCOLLECTED items for slot
    -- Returns array of {itemId, collected=false}
    local function GetUncollectedItemsForSlotFiltered(accountId, slotId, subclassName, quality)
        local invTypes = SLOT_INV_TYPES[slotId]
        if not invTypes then return {} end
        
        local invTypeStr = table.concat(invTypes, ",")
        
        -- Get player's collection
        local collectionQuery = CharDBQuery(string.format(
            "SELECT item_id FROM mod_transmog_system_collection WHERE account_id = %d",
            accountId
        ))
        
        local collectedIds = {}
        if collectionQuery then
            repeat
                collectedIds[collectionQuery:GetUInt32(0)] = true
            until not collectionQuery:NextRow()
        end
        
        -- Build WHERE clause for item_template
        local whereConditions = {}
        table.insert(whereConditions, string.format("InventoryType IN (%s)", invTypeStr))
        table.insert(whereConditions, "displayid > 0")  -- Must have a visual
        
        -- Subclass filter
        if subclassName and subclassName ~= "" and subclassName ~= "All" then
            local itemClass, itemSubclass = GetSubclassId(subclassName)
            if itemClass and itemSubclass then
                table.insert(whereConditions, string.format("class = %d", itemClass))
                table.insert(whereConditions, string.format("subclass = %d", itemSubclass))
            end
        end
        
        -- Quality filter
        if quality and quality ~= "" and quality ~= "All" then
            local qualityMap = {
                ["Poor"] = 0,
                ["Common"] = 1,
                ["Uncommon"] = 2,
                ["Rare"] = 3,
                ["Epic"] = 4,
                ["Legendary"] = 5,
                ["Heirloom"] = 6,
            }
            local qualityId = qualityMap[quality]
            if qualityId then
                table.insert(whereConditions, string.format("Quality = %d", qualityId))
            end
        end
        
        -- Only include allowed qualities
        local qualityList = {}
        for q, allowed in pairs(ALLOWED_QUALITIES) do
            if allowed then
                table.insert(qualityList, q)
            end
        end
        table.insert(whereConditions, string.format("Quality IN (%s)", table.concat(qualityList, ",")))
        
        local whereClause = table.concat(whereConditions, " AND ")
        local query = WorldDBQuery(string.format(
            "SELECT entry FROM item_template WHERE %s ORDER BY entry",
            whereClause
        ))
        
        local items = {}
        if query then
            repeat
                local itemId = query:GetUInt32(0)
                -- Only add if NOT in collection and NOT blacklisted
                if not collectedIds[itemId] and not IsItemBlacklisted(itemId) then
                    table.insert(items, { itemId = itemId, collected = false })
                end
            until not query:NextRow()
        end
        
        return items
    end

   local function GetActiveTransmogs(guid)
        local query = CharDBQuery(string.format(
            "SELECT slot, item_id FROM mod_transmog_system_active WHERE guid = %d",
            guid
        ))
        
        local transmogs = {}
        if query then
            repeat
                local slot = query:GetUInt8(0)
                local itemId = query:GetUInt32(1)
                transmogs[slot] = itemId
            until not query:NextRow()
        end
        return transmogs
    end
    
    -- Async version of GetActiveTransmogs
    local function GetActiveTransmogsAsync(guid, callback)
        CharDBQueryAsync(
            string.format("SELECT slot, item_id FROM mod_transmog_system_active WHERE guid = %d", guid),
            function(Q)
                local transmogs = {}
                if Q then
                    repeat
                        local slot = Q:GetUInt8(0)
                        local itemId = Q:GetUInt32(1)
                        transmogs[slot] = itemId
                    until not Q:NextRow()
                end
                callback(transmogs)
            end
        )
    end
    
    local function SaveActiveTransmog(guid, slot, itemId)
        CharDBExecute(string.format(
            "REPLACE INTO mod_transmog_system_active (guid, slot, item_id) VALUES (%d, %d, %d)",
            guid, slot, itemId
        ))
    end
    
    local function RemoveActiveTransmog(guid, slot)
        CharDBExecute(string.format(
            "DELETE FROM mod_transmog_system_active WHERE guid = %d AND slot = %d",
            guid, slot
        ))
    end
    
    -- ============================================================================
    -- Visual Application - Using SetUInt32Value for proper visual override
    -- ============================================================================
    
    -- UpdateFields.h
    -- OBJECT_END = 0x0006
    -- UNIT_END = OBJECT_END + 0x008E
    -- PLAYER_VISIBLE_ITEM_1_ENTRYID             = UNIT_END + 0x0087,
    -- PLAYER_VISIBLE_ITEM_1_ENCHANTMENT         = UNIT_END + 0x0088,
    -- PLAYER_VISIBLE_ITEM_2_ENTRYID             = UNIT_END + 0x0089,
    -- PLAYER_VISIBLE_ITEM_2_ENCHANTMENT         = UNIT_END + 0x008A,
    -- PLAYER_VISIBLE_ITEM_3_ENTRYID             = UNIT_END + 0x008B,
    -- PLAYER_VISIBLE_ITEM_3_ENCHANTMENT         = UNIT_END + 0x008C,
    -- PLAYER_VISIBLE_ITEM_4_ENTRYID             = UNIT_END + 0x008D,
    -- PLAYER_VISIBLE_ITEM_4_ENCHANTMENT         = UNIT_END + 0x008E,
    -- PLAYER_VISIBLE_ITEM_5_ENTRYID             = UNIT_END + 0x008F,
    -- PLAYER_VISIBLE_ITEM_5_ENCHANTMENT         = UNIT_END + 0x0090,
    -- PLAYER_VISIBLE_ITEM_6_ENTRYID             = UNIT_END + 0x0091,
    -- PLAYER_VISIBLE_ITEM_6_ENCHANTMENT         = UNIT_END + 0x0092,
    -- PLAYER_VISIBLE_ITEM_7_ENTRYID             = UNIT_END + 0x0093,
    -- PLAYER_VISIBLE_ITEM_7_ENCHANTMENT         = UNIT_END + 0x0094,
    -- PLAYER_VISIBLE_ITEM_8_ENTRYID             = UNIT_END + 0x0095,
    -- PLAYER_VISIBLE_ITEM_8_ENCHANTMENT         = UNIT_END + 0x0096,
    -- PLAYER_VISIBLE_ITEM_9_ENTRYID             = UNIT_END + 0x0097,
    -- PLAYER_VISIBLE_ITEM_9_ENCHANTMENT         = UNIT_END + 0x0098,
    -- PLAYER_VISIBLE_ITEM_10_ENTRYID            = UNIT_END + 0x0099,
    -- PLAYER_VISIBLE_ITEM_10_ENCHANTMENT        = UNIT_END + 0x009A,
    -- PLAYER_VISIBLE_ITEM_11_ENTRYID            = UNIT_END + 0x009B,
    -- PLAYER_VISIBLE_ITEM_11_ENCHANTMENT        = UNIT_END + 0x009C,
    -- PLAYER_VISIBLE_ITEM_12_ENTRYID            = UNIT_END + 0x009D,
    -- PLAYER_VISIBLE_ITEM_12_ENCHANTMENT        = UNIT_END + 0x009E,
    -- PLAYER_VISIBLE_ITEM_13_ENTRYID            = UNIT_END + 0x009F,
    -- PLAYER_VISIBLE_ITEM_13_ENCHANTMENT        = UNIT_END + 0x00A0,
    -- PLAYER_VISIBLE_ITEM_14_ENTRYID            = UNIT_END + 0x00A1,
    -- PLAYER_VISIBLE_ITEM_14_ENCHANTMENT        = UNIT_END + 0x00A2,
    -- PLAYER_VISIBLE_ITEM_15_ENTRYID            = UNIT_END + 0x00A3,
    -- PLAYER_VISIBLE_ITEM_15_ENCHANTMENT        = UNIT_END + 0x00A4,
    -- PLAYER_VISIBLE_ITEM_16_ENTRYID            = UNIT_END + 0x00A5,
    -- PLAYER_VISIBLE_ITEM_16_ENCHANTMENT        = UNIT_END + 0x00A6,
    -- PLAYER_VISIBLE_ITEM_17_ENTRYID            = UNIT_END + 0x00A7,
    -- PLAYER_VISIBLE_ITEM_17_ENCHANTMENT        = UNIT_END + 0x00A8,
    -- PLAYER_VISIBLE_ITEM_18_ENTRYID            = UNIT_END + 0x00A9,
    -- PLAYER_VISIBLE_ITEM_18_ENCHANTMENT        = UNIT_END + 0x00AA,
    -- PLAYER_VISIBLE_ITEM_19_ENTRYID            = UNIT_END + 0x00AB,
    -- PLAYER_VISIBLE_ITEM_19_ENCHANTMENT        = UNIT_END + 0x00AC,
    
    -- Visual field constants for each equipment slot
    local PLAYER_VISIBLE_ITEM_FIELDS = {
        [0]  = 283,  -- Head
        [2]  = 287,  -- Shoulder
        [3]  = 289,  -- Shirt
        [4]  = 291,  -- Chest
        [5]  = 293,  -- Waist
        [6]  = 295,  -- Legs
        [7]  = 297,  -- Feet
        [8]  = 299,  -- Wrist
        [9]  = 301,  -- Hands
        [14] = 311,  -- Back (Cloak)
        [15] = 313,  -- Main Hand
        [16] = 315,  -- Off Hand
        [17] = 317,  -- Ranged
        [18] = 319,  -- Tabard
    }
    
    local PLAYER_VISIBLE_ENCHANTMENT_FIELDS = {
        [0]  = 284,  -- Head
        [2]  = 288,  -- Shoulder
        [3]  = 290,  -- Shirt
        [4]  = 292,  -- Chest
        [5]  = 294,  -- Waist
        [6]  = 296,  -- Legs
        [7]  = 298,  -- Feet
        [8]  = 300,  -- Wrist
        [9]  = 302,  -- Hands
        [14] = 312,  -- Back (Cloak)
        [15] = 314,  -- Main Hand
        [16] = 316,  -- Off Hand
        [17] = 318,  -- Ranged
        [18] = 320,  -- Tabard
    }
    
    -- Slots eligible for enchantment visual transmog (weapons only show enchants)
    local ENCHANT_ELIGIBLE_SLOTS = {
        [15] = true,  -- Main Hand
        [16] = true,  -- Off Hand
        -- Ranged (17) does NOT show enchant visuals in WotLK
    }
    
    -- Get the visual field for an equipment slot
    local function GetVisualField(equipSlot)
        return PLAYER_VISIBLE_ITEM_FIELDS[equipSlot]
    end
    
    -- Get the enchantment visual field for an equipment slot
    local function GetEnchantmentVisualField(equipSlot)
        return PLAYER_VISIBLE_ENCHANTMENT_FIELDS[equipSlot]
    end
    
    -- Check if slot is eligible for enchant transmog
    local function IsEnchantEligibleSlot(slot)
        return ENCHANT_ELIGIBLE_SLOTS[slot] == true
    end
	
    local function ApplyTransmogVisual(player, slot, fakeItemId)
        if not player or not TRANSMOG_SLOTS[slot] then
            DebugPrint("[Transmog Debug] ApplyTransmogVisual failed: invalid player or slot " .. tostring(slot))
            return false
        end
        
        -- Check if player has an item equipped in this slot
        local item = player:GetItemByPos(255, slot)
        if not item then
            DebugPrint("[Transmog Debug] ApplyTransmogVisual failed: no item in slot " .. tostring(slot))
            return false  -- Can only transmog if item is equipped
        end
        
        -- Get item template to verify it exists
        local itemTemplate = GetItemTemplate(fakeItemId)
        if not itemTemplate then
            DebugPrint("[Transmog Debug] ApplyTransmogVisual failed: item template not found for " .. tostring(fakeItemId))
            return false
        end
        
        -- Get the correct visual field for this slot
        local field = GetVisualField(slot)
        if not field then
            DebugPrint("[Transmog Debug] ApplyTransmogVisual failed: no visual field for slot " .. tostring(slot))
            return false
        end
        
        DebugPrint(string.format("[Transmog Debug] Applying visual: slot=%d, field=%d, fakeItemId=%d, displayId=%d", 
            slot, field, fakeItemId, itemTemplate.displayid or 0))
        
        -- Apply the visual using SetUInt32Value with the CORRECT field
        player:SetUInt32Value(field, fakeItemId)
        
        return true
    end
    
    local function RemoveTransmogVisual(player, slot)
        if not player or not TRANSMOG_SLOTS[slot] then
            return false
        end
        
        -- Get equipped item to restore original appearance
        local item = player:GetItemByPos(255, slot)
        if not item then
            return true  -- No item, nothing to restore
        end
        
        -- Get the correct visual field for this slot
        local field = GetVisualField(slot)
        if not field then
            return false
        end
        
        -- Restore original item appearance
        local originalItemId = item:GetEntry()
        player:SetUInt32Value(field, originalItemId)
        
       return true
    end
    
    -- ============================================================================
    -- Enchantment Visual Transmog Functions
    -- ============================================================================
    
    local function ApplyEnchantVisual(player, slot, visualId)
        if not player or not IsEnchantEligibleSlot(slot) then
            DebugPrint("[Transmog Debug] ApplyEnchantVisual failed: invalid player or slot " .. tostring(slot))
            return false
        end
        
        -- Check if player has an item equipped in this slot
        local item = player:GetItemByPos(255, slot)
        if not item then
            DebugPrint("[Transmog Debug] ApplyEnchantVisual failed: no item in slot " .. tostring(slot))
            return false
        end
        
        -- Get the correct enchantment visual field for this slot
        local field = GetEnchantmentVisualField(slot)
        if not field then
            DebugPrint("[Transmog Debug] ApplyEnchantVisual failed: no enchant field for slot " .. tostring(slot))
            return false
        end
        
        DebugPrint(string.format("[Transmog Debug] Applying enchant visual: slot=%d, field=%d, visualId=%d", 
            slot, field, visualId))
        
        -- Apply the enchant visual using SetUInt32Value
        player:SetUInt32Value(field, visualId)
        
        return true
    end
    
    local function RemoveEnchantVisual(player, slot)
        if not player or not IsEnchantEligibleSlot(slot) then
            return false
        end
        
        -- Get equipped item to get its real enchant
        local item = player:GetItemByPos(255, slot)
        if not item then
            return true  -- No item, nothing to restore
        end
        
        -- Get the correct enchantment visual field for this slot
        local field = GetEnchantmentVisualField(slot)
        if not field then
            return false
        end
        
        -- Get the original enchant from the item (if any)
        local originalEnchant = item:GetEnchantmentId(0)  -- PERM_ENCHANTMENT_SLOT = 0
        player:SetUInt32Value(field, originalEnchant or 0)
        
        return true
    end
    
    -- Get active enchant transmogs from database (returns enchant_id, not visual)
    local function GetActiveEnchantTransmogs(guid)
        local transmogs = {}
        local query = CharDBQuery(string.format(
            "SELECT slot, enchant_id FROM mod_transmog_system_active WHERE guid = %d AND enchant_id > 0",
            guid
        ))
        
        if query then
            repeat
                local slot = query:GetUInt32(0)
                local enchantId = query:GetUInt32(1)
                transmogs[slot] = enchantId
            until not query:NextRow()
        end
        
        return transmogs
    end
    
    -- Save enchant transmog to database
    local function SaveEnchantTransmog(guid, slot, enchantId)
        -- Check if there's an existing entry for this slot
        local existingQuery = CharDBQuery(string.format(
            "SELECT item_id FROM mod_transmog_system_active WHERE guid = %d AND slot = %d",
            guid, slot
        ))
        
        if existingQuery then
            -- Update existing entry
            CharDBExecute(string.format(
                "UPDATE mod_transmog_system_active SET enchant_id = %d WHERE guid = %d AND slot = %d",
                enchantId, guid, slot
            ))
        else
            -- Insert new entry (with item_id = 0 since this is enchant-only)
            CharDBExecute(string.format(
                "INSERT INTO mod_transmog_system_active (guid, slot, item_id, enchant_id) VALUES (%d, %d, 0, %d)",
                guid, slot, enchantId
            ))
        end
    end
    
    -- Remove enchant transmog from database
    local function RemoveEnchantTransmogFromDB(guid, slot)
        CharDBExecute(string.format(
            "UPDATE mod_transmog_system_active SET enchant_id = 0 WHERE guid = %d AND slot = %d",
            guid, slot
        ))
    end
    
    -- Get enchant collection from database
    -- Get all available enchant visuals from reference table
    -- Returns array of {id, itemVisual, name, icon}
    local function GetAllEnchantVisuals()
        local enchants = {}
        local query = CharDBQuery(
            "SELECT id, item_visual, name_enUS, icon FROM mod_transmog_system_enchantment ORDER BY id"
        )
        
        if query then
            repeat
                table.insert(enchants, {
                    id = query:GetUInt32(0),
                    itemVisual = query:GetUInt32(1),
                    name = query:GetString(2),
                    icon = query:GetString(3)
                })
            until not query:NextRow()
        end
        
        return enchants
    end
    
    -- Get enchant info by ID
    local function GetEnchantById(enchantId)
        local query = CharDBQuery(string.format(
            "SELECT id, item_visual, name_enUS, icon FROM mod_transmog_system_enchantment WHERE id = %d",
            enchantId
        ))
        
        if query then
            return {
                id = query:GetUInt32(0),
                itemVisual = query:GetUInt32(1),
                name = query:GetString(2),
                icon = query:GetString(3)
            }
        end
        return nil
    end
    
    -- Apply all enchant transmogs for a player on login
    local function ApplyAllEnchantTransmogs(player)
        if not player then return end
        
        local guid = player:GetGUIDLow()
        local enchantTransmogs = GetActiveEnchantTransmogs(guid)
        
        local appliedCount = 0
        for slot, enchantId in pairs(enchantTransmogs) do
            if IsEnchantEligibleSlot(slot) then
                local equippedItem = player:GetItemByPos(255, slot)
                if equippedItem then
                    -- Use enchant ID directly instead of itemVisual
                    if ApplyEnchantVisual(player, slot, enchantId) then
                        appliedCount = appliedCount + 1
                    end
                end
            end
        end
        
        if appliedCount > 0 then
            DebugPrint(string.format("[Transmog] Applied %d enchant transmogs for %s", appliedCount, player:GetName()))
        end
    end
    
    local function ApplyAllTransmogs(player)
        if not player then return end
        
        local guid = player:GetGUIDLow()
        local transmogs = GetActiveTransmogs(guid)
        
        local appliedCount = 0
        for slot, itemId in pairs(transmogs) do
            -- Only apply if player has an item equipped in that slot
            local equippedItem = player:GetItemByPos(255, slot)
            if equippedItem then
			    if ENABLE_TRANSMOG_APPLY_TRANSMOG_VISUAL then
                    if ApplyTransmogVisual(player, slot, itemId) then
                        appliedCount = appliedCount + 1
                    end
				end
            end
        end
        
        -- Single update after applying all transmogs
        if appliedCount > 0 then
            DebugPrint(string.format("[Transmog] Applied %d transmogs for %s", appliedCount, player:GetName()))
        end
    end
    
    -- ============================================================================
    -- Collection Management - Item unlocking with notifications
    -- ============================================================================
    
    -- Notify player of new appearance via AIO (must be defined before AddToCollection)
    local function NotifyNewAppearance(player, itemId)
        if player and itemId then
            AIO.Msg():Add("TRANSMOG", "NewAppearance", { itemId = itemId }):Send(player)
        end
    end
    
    -- Player's notifications cache to avoid multiple notification on same Item from different event triggered
    local SessionNotifiedItems = {}
    
    local function GetSessionCache(player)
        local guid = player:GetGUIDLow()
        if not SessionNotifiedItems[guid] then
            SessionNotifiedItems[guid] = {}
        end
        return SessionNotifiedItems[guid]
    end
    
    local function CanTransmogItem(itemId)
        local template = GetItemTemplate(itemId)
        if not template then return false end
        
        -- Must have a display ID
        if template.displayid == 0 then
            return false
        end
        
        -- Check if quality is allowed
        if not ALLOWED_QUALITIES[template.quality] then
            return false
        end
        
        local itemClass = template.class
        local invType = template.inventoryType
        
        -- Check if inventory type maps to a valid slot
        local slot = INV_TYPE_TO_SLOT[invType]
        if not slot then
            return false
        end
        
        return true
    end
    
    local function AddToCollection(player, itemId, notifyPlayer)
        if not player or not itemId then return false end
        
        -- Check blacklist first
        if IsItemBlacklisted(itemId) then
            return false
        end
        
        if not CanTransmogItem(itemId) then
            return false
        end
        
        local accountId = player:GetAccountId()
        
        -- Check if already in collection
        if HasAppearance(accountId, itemId) then
            return false
        end
        
        -- Add to database (simplified - display_ID are queried from acore_world.item_template)
        CharDBExecute(string.format(
            "INSERT IGNORE INTO mod_transmog_system_collection (account_id, item_id) VALUES (%d, %d)",
            accountId, itemId
        ))
        
        -- Notify player if requested and if not in cache
        if notifyPlayer ~= false then
    	    local cache = GetSessionCache(player)
    		if not cache[itemId] then
    		    cache[itemId] = true
                NotifyNewAppearance(player, itemId)
    		end
        end
        
        return true
    end
    
    -- Export for global access
    _G.TransmogNotifyNewAppearance = NotifyNewAppearance
    _G.TransmogAddToCollection = AddToCollection
    
    -- ============================================================================
    -- Helper function for safe async messaging
    -- ============================================================================
    -- When using async queries, the player object may become invalid by the time
    -- the callback executes. This helper stores player name and retrieves fresh
    -- reference in the callback.
    -- ============================================================================
    
    local function SafeSendToPlayer(playerName, msgBuilder)
        -- Get fresh player reference by name
        local player = GetPlayerByName(playerName)
        if player then
            msgBuilder:Send(player)
        end
        -- If player is nil, they logged off - silently ignore
    end
    
    -- ============================================================================
    -- AIO Handlers - Matching Client Format
    -- ============================================================================
    
    local TRANSMOG_HANDLER = AIO.AddHandlers("TRANSMOG", {})
    
    -- ============================================================================
    -- NEW: Cache-based handlers for improved performance
    -- ============================================================================
    
    -- Request server cache version (client checks if it needs to download cache)
    TRANSMOG_HANDLER.GetCacheVersion = function(player)
        AIO.Msg():Add("TRANSMOG", "CacheVersion", {
            version = SERVER_ITEM_CACHE.version,
            isReady = SERVER_ITEM_CACHE.isReady
        }):Send(player)
    end
    
    -- Request FULL item cache (ALL slots at once)
    -- This is called once on login - client stores in SavedVariables
    TRANSMOG_HANDLER.RequestFullCache = function(player, clientVersion)
        if not SERVER_ITEM_CACHE.isReady then
            AIO.Msg():Add("TRANSMOG", "FullCacheNotReady", {}):Send(player)
            return
        end
        
        -- Check if client already has current version
        if clientVersion and clientVersion == SERVER_ITEM_CACHE.version then
            AIO.Msg():Add("TRANSMOG", "FullCacheUpToDate", { 
                version = SERVER_ITEM_CACHE.version 
            }):Send(player)
            return
        end
        
        DebugPrint(string.format("[Transmog] Sending full cache to %s (client version: %s, server version: %d)", 
            player:GetName(), tostring(clientVersion), SERVER_ITEM_CACHE.version))
        
        -- Count total items across all slots for chunking
        local allItems = {}  -- { {slotId, itemId, class, subclass, quality, displayId}, ... }
        for slotId, items in pairs(SERVER_ITEM_CACHE.bySlot) do
            for _, itemData in ipairs(items) do
                -- itemData is {itemId, class, subclass, quality, displayId}
                table.insert(allItems, {
                    slotId,
                    itemData[1],  -- itemId
                    itemData[2],  -- class
                    itemData[3],  -- subclass
                    itemData[4],  -- quality
                    itemData[5]   -- displayId
                })
            end
        end
        
        -- Send in chunks of 200
        local chunkSize = 200
        local totalChunks = math.ceil(#allItems / chunkSize)
        if totalChunks == 0 then totalChunks = 1 end
        
        for chunk = 1, totalChunks do
            local startIdx = (chunk - 1) * chunkSize + 1
            local endIdx = math.min(chunk * chunkSize, #allItems)
            local chunkItems = {}
            
            for i = startIdx, endIdx do
                table.insert(chunkItems, allItems[i])
            end
            
            AIO.Msg():Add("TRANSMOG", "FullCacheData", {
                version = SERVER_ITEM_CACHE.version,
                chunk = chunk,
                totalChunks = totalChunks,
                items = chunkItems
            }):Send(player)
        end
        
        DebugPrint(string.format("[Transmog] Sent %d items in %d chunks to %s", 
            #allItems, totalChunks, player:GetName()))
    end
    
    -- Request full item cache for a specific slot (only sent if client cache is outdated)
    -- clientVersion: the version the client currently has (0 if none)
    TRANSMOG_HANDLER.RequestSlotCache = function(player, slotId, clientVersion)
        if not SERVER_ITEM_CACHE.isReady then
            AIO.Msg():Add("TRANSMOG", "SlotCacheNotReady", { slotId = slotId }):Send(player)
            return
        end
        
        -- Check if client already has current version
        if clientVersion and clientVersion == SERVER_ITEM_CACHE.version then
            AIO.Msg():Add("TRANSMOG", "SlotCacheUpToDate", { 
                slotId = slotId, 
                version = SERVER_ITEM_CACHE.version 
            }):Send(player)
            return
        end
        
        local items = SERVER_ITEM_CACHE.bySlot[slotId] or {}
        
        -- Send in chunks of 100 (each item is compact: {itemId, class, subclass, quality, displayId})
        local chunkSize = 100
        local totalChunks = math.ceil(#items / chunkSize)
        if totalChunks == 0 then totalChunks = 1 end
        
        for chunk = 1, totalChunks do
            local startIdx = (chunk - 1) * chunkSize + 1
            local endIdx = math.min(chunk * chunkSize, #items)
            local chunkItems = {}
            
            for i = startIdx, endIdx do
                -- Items stored as {itemId, class, subclass, quality, displayId}
                table.insert(chunkItems, items[i])
            end
            
            AIO.Msg():Add("TRANSMOG", "SlotCacheData", {
                slotId = slotId,
                version = SERVER_ITEM_CACHE.version,
                chunk = chunk,
                totalChunks = totalChunks,
                items = chunkItems
            }):Send(player)
        end
    end
    
    -- Request full enchant cache (only sent if client cache is outdated)
    TRANSMOG_HANDLER.RequestEnchantCache = function(player, clientVersion)
        if not SERVER_ITEM_CACHE.isReady then
            AIO.Msg():Add("TRANSMOG", "EnchantCacheNotReady", {}):Send(player)
            return
        end
        
        -- Check if client already has current version
        if clientVersion and clientVersion == SERVER_ITEM_CACHE.version then
            AIO.Msg():Add("TRANSMOG", "EnchantCacheUpToDate", { 
                version = SERVER_ITEM_CACHE.version 
            }):Send(player)
            return
        end
        
        local enchants = SERVER_ITEM_CACHE.enchants
        
        -- Send in chunks of 30
        local chunkSize = 30
        local totalChunks = math.ceil(#enchants / chunkSize)
        if totalChunks == 0 then totalChunks = 1 end
        
        for chunk = 1, totalChunks do
            local startIdx = (chunk - 1) * chunkSize + 1
            local endIdx = math.min(chunk * chunkSize, #enchants)
            local chunkEnchants = {}
            
            for i = startIdx, endIdx do
                table.insert(chunkEnchants, enchants[i])
            end
            
            AIO.Msg():Add("TRANSMOG", "EnchantCacheData", {
                version = SERVER_ITEM_CACHE.version,
                chunk = chunk,
                totalChunks = totalChunks,
                enchants = chunkEnchants
            }):Send(player)
        end
    end
    
    -- Request player's collection status (small payload - just item IDs they own)
    -- This is the only player-specific data that needs to be sent frequently
    TRANSMOG_HANDLER.RequestCollectionStatus = function(player)
        local accountId = player:GetAccountId()
        local playerName = player:GetName()  -- Store name for callback
        
        -- Use async query for collection
        CharDBQueryAsync(
            string.format("SELECT item_id FROM mod_transmog_system_collection WHERE account_id = %d", accountId),
            function(Q)
                local items = {}
                if Q then
                    repeat
                        local itemId = Q:GetUInt32(0)
                        if not IsItemBlacklisted(itemId) then
                            table.insert(items, itemId)
                        end
                    until not Q:NextRow()
                end
                
                -- Send in chunks of 200 (just item IDs, very compact)
                local chunkSize = 200
                local totalChunks = math.ceil(#items / chunkSize)
                if totalChunks == 0 then totalChunks = 1 end
                
                for chunk = 1, totalChunks do
                    local startIdx = (chunk - 1) * chunkSize + 1
                    local endIdx = math.min(chunk * chunkSize, #items)
                    local chunkItems = {}
                    
                    for i = startIdx, endIdx do
                        table.insert(chunkItems, items[i])
                    end
                    
                    SafeSendToPlayer(playerName, AIO.Msg():Add("TRANSMOG", "CollectionStatus", {
                        chunk = chunk,
                        totalChunks = totalChunks,
                        items = chunkItems
                    }))
                end
            end
        )
    end
    
    -- ============================================================================
    -- Legacy Handlers (kept for backwards compatibility)
    -- ============================================================================
    
    -- Request full collection
    TRANSMOG_HANDLER.RequestCollection = function(player)
        local accountId = player:GetAccountId()
        local collection = GetPlayerCollection(accountId)
        
        -- Send in chunks of 100
        local chunkSize = 100
        local totalChunks = math.ceil(#collection / chunkSize)
        if totalChunks == 0 then totalChunks = 1 end
        
        for chunk = 1, totalChunks do
            local startIdx = (chunk - 1) * chunkSize + 1
            local endIdx = math.min(chunk * chunkSize, #collection)
            local items = {}
            
            for i = startIdx, endIdx do
                table.insert(items, collection[i])
            end
            
            AIO.Msg():Add("TRANSMOG", "CollectionData", {
                chunk = chunk,
                totalChunks = totalChunks,
                items = items
            }):Send(player)
        end
    end

    -- Search items - searches ALL items and includes collected status
    TRANSMOG_HANDLER.SearchItems = function(player, slotId, searchType, searchText, locale)
        if not searchType or not searchText then
            DebugPrint("[Transmog Debug] SearchItems received invalid parameters")
            return
        end
        
        -- Validate locale, else fallback to enUS
        local validLocales = {
            "enUS", "enGB", "koKR", "frFR", "deDE", "zhCN", "zhTW", "esES", "esMX", "ruRU"
        }
        local localeValid = false
        for _, validLocale in ipairs(validLocales) do
            if locale == validLocale then
                localeValid = true
                break
            end
        end
        
        if not localeValid then
            locale = "enUS"  -- default to enUS
        end
        
        local accountId = player:GetAccountId()
        
        -- Get player's collected item IDs
        local collectionQuery = CharDBQuery(string.format(
            "SELECT item_id FROM mod_transmog_system_collection WHERE account_id = %d",
            accountId
        ))
        
        local collectedIdsList = {}
        local collectedIdsSet = {}
        if collectionQuery then
            repeat
                local itemId = collectionQuery:GetUInt32(0)
                table.insert(collectedIdsList, itemId)
                collectedIdsSet[itemId] = true
            until not collectionQuery:NextRow()
        end
        
        -- Build quality filter for allowed qualities
        local qualityList = {}
        for q, allowed in pairs(ALLOWED_QUALITIES) do
            if allowed then
                table.insert(qualityList, q)
            end
        end
        local qualityFilter = string.format("Quality IN (%s)", table.concat(qualityList, ","))
        
        -- Build base WHERE conditions
        local baseConditions = {}
        table.insert(baseConditions, "displayid > 0")  -- Must have a visual
        table.insert(baseConditions, qualityFilter)
        
        -- Add search condition based on search type
        local searchPattern = searchText:gsub("%%", "%%%"):gsub("_", "\\_")
        searchPattern = "%" .. searchPattern .. "%"
        
        if searchType == "id" then
            local itemId = tonumber(searchText)
            if itemId then
                table.insert(baseConditions, string.format("entry LIKE '%d%%'", itemId))
            else
                searchType = "name"
            end
        end
        
        if searchType == "displayid" then
            local displayId = tonumber(searchText)
            if displayId then
                table.insert(baseConditions, string.format("displayid = %d", displayId))
            end
        end
        
        local baseWhereClause = table.concat(baseConditions, " AND ")
        
        -- Results storage
        local collectedResults = {}
        local slotResultsCollected = {}
        
        -- STEP 1: Search collected items first (all of them, no limit)
        if #collectedIdsList > 0 then
            local collectedIdsStr = table.concat(collectedIdsList, ",")
            local query
            
            if searchType == "name" then
                query = WorldDBQuery(string.format(
                    "SELECT it.entry, it.InventoryType FROM item_template it " ..
                    "LEFT JOIN item_template_locale itl ON it.entry = itl.ID AND itl.locale = '%s' " ..
                    "WHERE it.entry IN (%s) AND (it.name LIKE '%s' OR itl.Name LIKE '%s') AND %s",
                    locale, collectedIdsStr, searchPattern, searchPattern, baseWhereClause
                ))
            else
                query = WorldDBQuery(string.format(
                    "SELECT entry, InventoryType FROM item_template WHERE entry IN (%s) AND %s",
                    collectedIdsStr, baseWhereClause
                ))
            end
            
            if query then
                repeat
                    local itemId = query:GetUInt32(0)
                    local invType = query:GetUInt32(1)
                    local slot = INV_TYPE_TO_SLOT[invType]
                    
                    -- Skip blacklisted items
                    if not IsItemBlacklisted(itemId) then
                        table.insert(collectedResults, {itemId = itemId, collected = true})
                        if slot then
                            slotResultsCollected[slot] = slotResultsCollected[slot] or {}
                            table.insert(slotResultsCollected[slot], {itemId = itemId, collected = true})
                        end
                    end
                until not query:NextRow()
            end
        end
        
        -- STEP 2: Search uncollected items (no limit)
        local uncollectedResults = {}
        local slotResultsUncollected = {}
        
        local query
        if searchType == "name" then
            query = WorldDBQuery(string.format(
                "SELECT it.entry, it.InventoryType FROM item_template it " ..
                "LEFT JOIN item_template_locale itl ON it.entry = itl.ID AND itl.locale = '%s' " ..
                "WHERE (it.name LIKE '%s' OR itl.Name LIKE '%s') AND %s",
                locale, searchPattern, searchPattern, baseWhereClause
            ))
        else
            query = WorldDBQuery(string.format(
                "SELECT entry, InventoryType FROM item_template WHERE %s",
                baseWhereClause
            ))
        end
        
        if query then
            repeat
                local itemId = query:GetUInt32(0)
                local invType = query:GetUInt32(1)
                
                -- Only add if NOT in collected set and NOT blacklisted
                if not collectedIdsSet[itemId] and not IsItemBlacklisted(itemId) then
                    local slot = INV_TYPE_TO_SLOT[invType]
                    table.insert(uncollectedResults, {itemId = itemId, collected = false})
                    if slot then
                        slotResultsUncollected[slot] = slotResultsUncollected[slot] or {}
                        table.insert(slotResultsUncollected[slot], {itemId = itemId, collected = false})
                    end
                end
            until not query:NextRow()
        end
        
        -- Combine results: collected first, then uncollected
        local allResults = {}
        for _, item in ipairs(collectedResults) do
            table.insert(allResults, item)
        end
        for _, item in ipairs(uncollectedResults) do
            table.insert(allResults, item)
        end
        
        -- Combine slot results
        local slotResults = {}
        for slot, items in pairs(slotResultsCollected) do
            slotResults[slot] = slotResults[slot] or {}
            for _, item in ipairs(items) do
                table.insert(slotResults[slot], item)
            end
        end
        for slot, items in pairs(slotResultsUncollected) do
            slotResults[slot] = slotResults[slot] or {}
            for _, item in ipairs(items) do
                table.insert(slotResults[slot], item)
            end
        end
        
        -- Send results back to client
        AIO.Msg():Add("TRANSMOG", "SearchResults", {
            allResults = allResults,
            slotResults = slotResults
        }):Send(player)
    end
    
    -- Request active transmogs (async version)
    TRANSMOG_HANDLER.RequestActiveTransmogs = function(player)
        local guid = player:GetGUIDLow()
        local playerName = player:GetName()  -- Store name for callback
        
        GetActiveTransmogsAsync(guid, function(transmogs)
            SafeSendToPlayer(playerName, AIO.Msg():Add("TRANSMOG", "ActiveTransmogs", transmogs))
        end)
    end
    
    -- Request items for specific slot with subclass, quality, and collection filter
    -- collectionFilter: "All", "Collected", "Uncollected"
    -- NOTE: This is the LEGACY handler kept for backwards compatibility
    -- New clients should use RequestSlotCache + RequestCollectionStatus for better performance
    TRANSMOG_HANDLER.RequestSlotItems = function(player, slotId, subclass, quality, collectionFilter)
        if slotId == nil then
            DebugPrint("[Transmog Server] RequestSlotItems received nil slotId")
            return
        end
        
        local accountId = player:GetAccountId()
        collectionFilter = collectionFilter or "Collected"  -- Default to Collected
        
        local items = {}
        
        if collectionFilter == "All" then
            -- Get all items for slot (collected and uncollected)
            items = GetAllItemsForSlotFiltered(accountId, slotId, subclass, quality)
        elseif collectionFilter == "Uncollected" then
            -- Get only uncollected items for slot
            items = GetUncollectedItemsForSlotFiltered(accountId, slotId, subclass, quality)
        else
            -- Default: Get only collected items (existing behavior)
            local collectedItems = GetCollectionForSlotFiltered(accountId, slotId, subclass, quality)
            for _, itemId in ipairs(collectedItems) do
                table.insert(items, { itemId = itemId, collected = true })
            end
        end
        
        -- Send in chunks of 50
        local chunkSize = 50
        local totalChunks = math.ceil(#items / chunkSize)
        if totalChunks == 0 then totalChunks = 1 end
        
        for chunk = 1, totalChunks do
            local startIdx = (chunk - 1) * chunkSize + 1
            local endIdx = math.min(chunk * chunkSize, #items)
            local chunkItems = {}
            
            for i = startIdx, endIdx do
                -- Items now include collected status
                if type(items[i]) == "table" then
                    table.insert(chunkItems, items[i])
                else
                    -- Backwards compatibility
                    table.insert(chunkItems, { itemId = items[i], collected = true })
                end
            end
            
            AIO.Msg():Add("TRANSMOG", "SlotItems", {
                slotId = slotId,
                chunk = chunk,
                totalChunks = totalChunks,
                items = chunkItems
            }):Send(player)
        end
    end
    
    -- Apply transmog
    TRANSMOG_HANDLER.ApplyTransmog = function(player, slotId, itemId)
        if not slotId or not itemId then
            AIO.Msg():Add("TRANSMOG", "Error", "INVALID_SLOT_OR_ITEM"):Send(player)
            return
        end
        
        -- Validate slot
        if not TRANSMOG_SLOTS[slotId] then
            AIO.Msg():Add("TRANSMOG", "Error", "INVALID_SLOT"):Send(player)
            return
        end
        
        local accountId = player:GetAccountId()
        local guid = player:GetGUIDLow()
        
        -- Debug: log the check
        DebugPrint(string.format("[Transmog] ApplyTransmog: player=%s, slot=%d, item=%d, ALLOW_UNCOLLECTED=%s", 
            player:GetName(), slotId, itemId, tostring(ALLOW_UNCOLLECTED_TRANSMOG)))
        
        -- Verify player has the appearance (skip if ALLOW_UNCOLLECTED_TRANSMOG is true)
        if not ALLOW_UNCOLLECTED_TRANSMOG and not HasAppearance(accountId, itemId) then
            DebugPrint(string.format("[Transmog] ApplyTransmog BLOCKED: item %d not in collection for account %d", itemId, accountId))
            AIO.Msg():Add("TRANSMOG", "Error", "APPEARANCE_NOT_COLLECTED"):Send(player)
            return
        end
        
        -- Save to database (always - even if no item equipped)
        SaveActiveTransmog(guid, slotId, itemId)
        
        -- Check if player has an item equipped in the slot
        local equippedItem = player:GetItemByPos(255, slotId)
        if equippedItem then
		    if ENABLE_TRANSMOG_APPLY_TRANSMOG_VISUAL then
                -- Apply visual only if item is equipped
                ApplyTransmogVisual(player, slotId, itemId)
			end
        end
        
        -- Always report success since it's saved in mod_transmog_system_active DB even for empty slot
        AIO.Msg():Add("TRANSMOG", "Applied", { slot = slotId, itemId = itemId }):Send(player)
    end
    
    -- Remove transmog
    TRANSMOG_HANDLER.RemoveTransmog = function(player, slotId)
        if not slotId or not TRANSMOG_SLOTS[slotId] then
            AIO.Msg():Add("TRANSMOG", "Error", "INVALID_SLOT"):Send(player)
            return
        end
        
        local guid = player:GetGUIDLow()
        
        -- Remove from database
        RemoveActiveTransmog(guid, slotId)
        
        -- Remove visual (only matters if item equipped)
        RemoveTransmogVisual(player, slotId)
        
        AIO.Msg():Add("TRANSMOG", "Removed", slotId):Send(player)
    end
    
    -- Check if appearance is collected and eligible for transmog (async version)
    TRANSMOG_HANDLER.CheckAppearance = function(player, itemId)
        local accountId = player:GetAccountId()
        local playerName = player:GetName()  -- Store name for callback
        local eligible = CanTransmogItem(itemId)
        
        if not eligible then
            AIO.Msg():Add("TRANSMOG", "AppearanceCheck", {
                itemId = itemId,
                eligible = false,
                collected = false
            }):Send(player)
            return
        end
        
        HasAppearanceAsync(accountId, itemId, function(collected)
            SafeSendToPlayer(playerName, AIO.Msg():Add("TRANSMOG", "AppearanceCheck", {
                itemId = itemId,
                eligible = eligible,
                collected = collected
            }))
        end)
    end
    
    -- Bulk check appearances (async version)
    TRANSMOG_HANDLER.CheckAppearances = function(player, itemIds)
        local accountId = player:GetAccountId()
        local playerName = player:GetName()  -- Store name for callback
        
        -- Get all collected items for this account async
        GetPlayerCollectionAsync(accountId, function(collectionList)
            -- Convert to set for O(1) lookup
            local collectionSet = {}
            for _, itemId in ipairs(collectionList) do
                collectionSet[itemId] = true
            end
            
            local results = {}
            for _, itemId in ipairs(itemIds) do
                results[itemId] = collectionSet[itemId] == true
            end
            
            SafeSendToPlayer(playerName, AIO.Msg():Add("TRANSMOG", "AppearanceCheckBulk", results))
        end)
    end
    
    -- ============================================================================
    -- Enchantment Transmog - AIO Handlers
    -- ============================================================================
    
    -- Request all available enchant visuals (uses server cache if ready)
    TRANSMOG_HANDLER.RequestEnchantCollection = function(player)
        -- Use server cache if available
        if SERVER_ITEM_CACHE.isReady and #SERVER_ITEM_CACHE.enchants > 0 then
            local enchants = SERVER_ITEM_CACHE.enchants
            
            -- Send in chunks
            local chunkSize = 20
            local totalChunks = math.ceil(#enchants / chunkSize)
            if totalChunks == 0 then totalChunks = 1 end
            
            for chunk = 1, totalChunks do
                local startIdx = (chunk - 1) * chunkSize + 1
                local endIdx = math.min(chunk * chunkSize, #enchants)
                local chunkEnchants = {}
                
                for i = startIdx, endIdx do
                    table.insert(chunkEnchants, enchants[i])
                end
                
                AIO.Msg():Add("TRANSMOG", "EnchantCollectionData", {
                    chunk = chunk,
                    totalChunks = totalChunks,
                    enchants = chunkEnchants
                }):Send(player)
            end
            return
        end
        
        -- Fallback to direct query
        local enchants = GetAllEnchantVisuals()
        
        -- Send in chunks
        local chunkSize = 20
        local totalChunks = math.ceil(#enchants / chunkSize)
        if totalChunks == 0 then totalChunks = 1 end
        
        for chunk = 1, totalChunks do
            local startIdx = (chunk - 1) * chunkSize + 1
            local endIdx = math.min(chunk * chunkSize, #enchants)
            local chunkEnchants = {}
            
            for i = startIdx, endIdx do
                table.insert(chunkEnchants, enchants[i])
            end
            
            AIO.Msg():Add("TRANSMOG", "EnchantCollectionData", {
                chunk = chunk,
                totalChunks = totalChunks,
                enchants = chunkEnchants
            }):Send(player)
        end
    end
    
    -- Request active enchant transmogs
    TRANSMOG_HANDLER.RequestActiveEnchantTransmogs = function(player)
        local guid = player:GetGUIDLow()
        local enchantTransmogs = GetActiveEnchantTransmogs(guid)
        
        AIO.Msg():Add("TRANSMOG", "ActiveEnchantTransmogs", enchantTransmogs):Send(player)
    end
    
    -- Apply enchant transmog
    TRANSMOG_HANDLER.ApplyEnchantTransmog = function(player, slotId, enchantId)
        if not slotId or not enchantId then
            AIO.Msg():Add("TRANSMOG", "Error", "INVALID_SLOT_OR_ENCHANT"):Send(player)
            return
        end
        
        -- Validate slot is enchant-eligible
        if not IsEnchantEligibleSlot(slotId) then
            AIO.Msg():Add("TRANSMOG", "Error", "SLOT_NOT_ENCHANT_ELIGIBLE"):Send(player)
            return
        end
        
        -- Validate enchant exists in database
        local enchantInfo = GetEnchantById(enchantId)
        if not enchantInfo then
            AIO.Msg():Add("TRANSMOG", "Error", "INVALID_ENCHANT_ID"):Send(player)
            return
        end
        
        local guid = player:GetGUIDLow()
        
        -- Save to database (stores enchant_id)
        SaveEnchantTransmog(guid, slotId, enchantId)
        
        -- Check if player has an item equipped in the slot
        local equippedItem = player:GetItemByPos(255, slotId)
        if equippedItem then
            -- Apply visual using the enchant ID directly
            ApplyEnchantVisual(player, slotId, enchantId)
        end
        
        -- Report success
        AIO.Msg():Add("TRANSMOG", "EnchantApplied", { slot = slotId, visualId = enchantId }):Send(player)
    end
    
    -- Remove enchant transmog
    TRANSMOG_HANDLER.RemoveEnchantTransmog = function(player, slotId)
        if not slotId or not IsEnchantEligibleSlot(slotId) then
            AIO.Msg():Add("TRANSMOG", "Error", "INVALID_SLOT"):Send(player)
            return
        end
        
        local guid = player:GetGUIDLow()
        
        -- Remove from database
        RemoveEnchantTransmogFromDB(guid, slotId)
        
        -- Remove visual
        RemoveEnchantVisual(player, slotId)
        
        AIO.Msg():Add("TRANSMOG", "EnchantRemoved", slotId):Send(player)
    end
    
    -- ============================================================================
    -- Set Management - Database Functions
    -- ============================================================================
    
    -- Slot name to database column mapping
    local SLOT_TO_COLUMN = {
        [0]  = "slot_head",
        [2]  = "slot_shoulder",
        [3]  = "slot_shirt",
        [4]  = "slot_chest",
        [5]  = "slot_waist",
        [6]  = "slot_legs",
        [7]  = "slot_feet",
        [8]  = "slot_wrist",
        [9]  = "slot_hands",
        [14] = "slot_back",
        [15] = "slot_mainhand",
        [16] = "slot_offhand",
        [17] = "slot_ranged",
        [18] = "slot_tabard",
    }
    
    local COLUMN_TO_SLOT = {}
    for slot, column in pairs(SLOT_TO_COLUMN) do
        COLUMN_TO_SLOT[column] = slot
    end
    
    local function GetPlayerSets(accountId)
        local query = CharDBQuery(string.format(
            "SELECT set_number, set_name, slot_head, slot_shoulder, slot_back, slot_chest, " ..
            "slot_shirt, slot_tabard, slot_wrist, slot_hands, slot_waist, slot_legs, slot_feet, " ..
            "slot_mainhand, slot_offhand, slot_ranged FROM mod_transmog_system_sets WHERE account_id = %d",
            accountId
        ))
        
        local sets = {}
        if query then
            repeat
                local setNumber = query:GetUInt8(0)
                local setName = query:GetString(1)
                local slots = {
                    [0]  = query:GetUInt32(2),   -- head
                    [2]  = query:GetUInt32(3),   -- shoulder
                    [14] = query:GetUInt32(4),   -- back
                    [4]  = query:GetUInt32(5),   -- chest
                    [3]  = query:GetUInt32(6),   -- shirt
                    [18] = query:GetUInt32(7),   -- tabard
                    [8]  = query:GetUInt32(8),   -- wrist
                    [9]  = query:GetUInt32(9),   -- hands
                    [5]  = query:GetUInt32(10),  -- waist
                    [6]  = query:GetUInt32(11),  -- legs
                    [7]  = query:GetUInt32(12),  -- feet
                    [15] = query:GetUInt32(13),  -- mainhand
                    [16] = query:GetUInt32(14),  -- offhand
                    [17] = query:GetUInt32(15),  -- ranged
                }
                sets[setNumber] = {
                    name = setName,
                    slots = slots
                }
            until not query:NextRow()
        end
        return sets
    end
    
    local function SavePlayerSet(accountId, setNumber, setName, slotData)
        -- Build the INSERT/REPLACE query
        local columns = {"account_id", "set_number", "set_name"}
        local values = {accountId, setNumber, "'" .. setName:gsub("'", "''") .. "'"}
        
        -- Add slot columns and values
        for slot, column in pairs(SLOT_TO_COLUMN) do
            table.insert(columns, column)
            local itemId = slotData[slot] or 0
            table.insert(values, itemId)
        end
        
        local sql = string.format(
            "REPLACE INTO mod_transmog_system_sets (%s) VALUES (%s)",
            table.concat(columns, ", "),
            table.concat(values, ", ")
        )
        
        CharDBExecute(sql)
    end
    
    local function DeletePlayerSet(accountId, setNumber)
        CharDBExecute(string.format(
            "DELETE FROM mod_transmog_system_sets WHERE account_id = %d AND set_number = %d",
            accountId, setNumber
        ))
    end
    
    -- ============================================================================
    -- Set Management - AIO Handlers
    -- ============================================================================
    
    -- Request all sets for account
    TRANSMOG_HANDLER.RequestSets = function(player)
        local accountId = player:GetAccountId()
        local sets = GetPlayerSets(accountId)
        
        AIO.Msg():Add("TRANSMOG", "SetsData", sets):Send(player)
    end
    
    -- Save a new set or update existing
    TRANSMOG_HANDLER.SaveSet = function(player, setNumber, setName, slotData)
        if not setNumber or setNumber < 1 or setNumber > 10 then
            AIO.Msg():Add("TRANSMOG", "SetError", "Invalid set number"):Send(player)
            return
        end
        
        if not setName or setName == "" then
            setName = "Set " .. setNumber
        end
        
        -- Sanitize setName (max 64 chars)
        setName = setName:sub(1, 64)
        
        local accountId = player:GetAccountId()
        
        -- Convert slot data keys to numbers if needed
        local convertedSlotData = {}
        if slotData then
            for slot, itemId in pairs(slotData) do
                local slotNum = tonumber(slot)
                if slotNum and itemId and itemId > 0 then
                    convertedSlotData[slotNum] = itemId
                end
            end
        end
        
        SavePlayerSet(accountId, setNumber, setName, convertedSlotData)
        
        AIO.Msg():Add("TRANSMOG", "SetSaved", {
            setNumber = setNumber,
            setName = setName,
            slots = convertedSlotData
        }):Send(player)
    end
    
    -- Load a set (preview only, returns data to client)
    TRANSMOG_HANDLER.LoadSet = function(player, setNumber)
        if not setNumber or setNumber < 1 or setNumber > 10 then
            AIO.Msg():Add("TRANSMOG", "SetError", "Invalid set number"):Send(player)
            return
        end
        
        local accountId = player:GetAccountId()
        local sets = GetPlayerSets(accountId)
        
        if not sets[setNumber] then
            AIO.Msg():Add("TRANSMOG", "SetError", "Set not found"):Send(player)
            return
        end
        
        AIO.Msg():Add("TRANSMOG", "SetLoaded", {
            setNumber = setNumber,
            setName = sets[setNumber].name,
            slots = sets[setNumber].slots
        }):Send(player)
    end
    
    -- Delete a set
    TRANSMOG_HANDLER.DeleteSet = function(player, setNumber)
        if not setNumber or setNumber < 1 or setNumber > 10 then
            AIO.Msg():Add("TRANSMOG", "SetError", "Invalid set number"):Send(player)
            return
        end
        
        local accountId = player:GetAccountId()
        DeletePlayerSet(accountId, setNumber)
        
        AIO.Msg():Add("TRANSMOG", "SetDeleted", { setNumber = setNumber }):Send(player)
    end
    
    -- Apply a set (only items in collection will be applied)
    TRANSMOG_HANDLER.ApplySet = function(player, setNumber)
        if not setNumber or setNumber < 1 or setNumber > 10 then
            AIO.Msg():Add("TRANSMOG", "SetError", "Invalid set number"):Send(player)
            return
        end
        
        local accountId = player:GetAccountId()
        local guid = player:GetGUIDLow()
        local sets = GetPlayerSets(accountId)
        
        if not sets[setNumber] then
            AIO.Msg():Add("TRANSMOG", "SetError", "Set not found"):Send(player)
            return
        end
        
        local setData = sets[setNumber]
        local appliedSlots = {}
        local skippedCount = 0
        
        for slot, itemId in pairs(setData.slots) do
            if itemId and itemId > 0 then
                -- Check if player has this appearance in collection (skip if ALLOW_UNCOLLECTED_TRANSMOG)
                if ALLOW_UNCOLLECTED_TRANSMOG or HasAppearance(accountId, itemId) then
                    -- Save to active transmogs
                    SaveActiveTransmog(guid, slot, itemId)
                    
                    -- Apply visual if item equipped
                    local equippedItem = player:GetItemByPos(255, slot)
                    if equippedItem and ENABLE_TRANSMOG_APPLY_TRANSMOG_VISUAL then
                        ApplyTransmogVisual(player, slot, itemId)
                    end
                    
                    appliedSlots[slot] = itemId
                else
                    skippedCount = skippedCount + 1
                end
            end
        end
        
        AIO.Msg():Add("TRANSMOG", "SetApplied", {
            setNumber = setNumber,
            setName = setData.name,
            appliedSlots = appliedSlots,
            skippedCount = skippedCount
        }):Send(player)
    end
   
    -- ============================================================================
    -- Player Events - Mod-Ale - Event IDs from Hooks.h
    -- ============================================================================
    
    -- Event IDs from Hooks.h (mod-ale/Eluna for AzerothCore)
    local PLAYER_EVENT_ON_LOGIN                     = 3  -- (event, player) 
    local PLAYER_EVENT_ON_LOGOUT                    = 4  -- (event, player)
    local PLAYER_EVENT_ON_EQUIP                     = 29 -- (event, player, item, bag, slot)
    local PLAYER_EVENT_ON_LOOT_ITEM                 = 32 -- (event, player, item, count)
    local PLAYER_EVENT_ON_COMMAND                   = 42 -- (event, player, command, chatHandler) - player is nil if command used from console. Can return false
    local PLAYER_EVENT_ON_QUEST_REWARD_ITEM         = 51 -- (event, player, item, count)
    local PLAYER_EVENT_ON_CREATE_ITEM               = 52 -- (event, player, item, count)
    local PLAYER_EVENT_ON_STORE_NEW_ITEM            = 53 -- (event, player, item, count)
    local PLAYER_EVENT_ON_COMPLETE_QUEST            = 54 -- (event, player, quest)
    local PLAYER_EVENT_ON_GROUP_ROLL_REWARD_ITEM    = 56 -- (event, player, item, count, voteType, roll)
    
    -- ============================================================================
    -- Helper Function - Scan Items and Quests
    -- ============================================================================  
    
    -- ScanAllItems is a workaround for items not detected by the PLAYER_EVENT_X hooks
    -- It scans all possible item slots on login
    -- This is required to catch items received via mail, trade, or repurchased from vendors
    local function ScanAllItems(player)
        -- Scan equipment and backpack (slots 0-38)
        for slot = 0, 38 do
            local item = player:GetItemByPos(255, slot)
            if item then
			    if COLLECTION_ON_CHARACTER_LOGIN_SCANNED_ITEMS then
                    AddToCollection(player, item:GetEntry(), false)
				end
            end
        end
    
        -- Scan regular bags (19-22)
        for bag = 0, 3 do
            local bagSlot = 19 + bag
            local bagItem = player:GetItemByPos(255, bagSlot)
            if bagItem then
                local bagSize = bagItem:GetBagSize()
                if bagSize and bagSize > 0 then
                    for slotInBag = 0, bagSize - 1 do
                        local item = player:GetItemByPos(bagSlot, slotInBag)
                        if item then
						    if COLLECTION_ON_CHARACTER_LOGIN_SCANNED_ITEMS then
                                AddToCollection(player, item:GetEntry(), false)
							end
                        end
                    end
                end
            end
        end
    
        -- Scan bank main slots (39-66)
        for slot = 39, 66 do
            local item = player:GetItemByPos(255, slot)
            if item then
			    if COLLECTION_ON_CHARACTER_LOGIN_SCANNED_ITEMS then
                    AddToCollection(player, item:GetEntry(), false)
				end
            end
        end
    
        -- Scan bank bags (67-73)
        for bankBag = 0, 6 do
            local bankBagSlot = 67 + bankBag
            local bankBagItem = player:GetItemByPos(255, bankBagSlot)
            if bankBagItem then
                local bankBagSize = bankBagItem:GetBagSize()
                if bankBagSize and bankBagSize > 0 then
                    for slotInBankBag = 0, bankBagSize - 1 do
                        local item = player:GetItemByPos(bankBagSlot, slotInBankBag)
                        if item then
						    if COLLECTION_ON_CHARACTER_LOGIN_SCANNED_ITEMS then
                                AddToCollection(player, item:GetEntry(), false)
							end
                        end
                    end
                end
            end
        end
    end


    -- ScanAllQuests is a helper function used to resynchronize item collections from quests completed before the script was installed
    local function ScanAllQuests(player)
        if not player then
            return
        end
        
        local guid = player:GetGUIDLow()
        
        -- 1. Scan completed quests (already turned in) - get ALL items
        local completedQuery = CharDBQuery(string.format(
            "SELECT quest FROM character_queststatus_rewarded WHERE guid = %d",
            guid
        ))
        
        if completedQuery then
            repeat
                local questId = completedQuery:GetUInt32(0)
                
                -- Get ALL items from completed quests
                local questQuery = WorldDBQuery(string.format(
                    "SELECT RewardItem1, RewardItem2, RewardItem3, RewardItem4, " ..
                    "RewardChoiceItemID1, RewardChoiceItemID2, RewardChoiceItemID3, " ..
                    "RewardChoiceItemID4, RewardChoiceItemID5, RewardChoiceItemID6, " ..
                    "StartItem, " ..
                    "RequiredItemId1, RequiredItemId2, RequiredItemId3, " ..
                    "RequiredItemId4, RequiredItemId5, RequiredItemId6, " ..
                    "ItemDrop1, ItemDrop2, ItemDrop3, ItemDrop4 " ..
					"FROM quest_template WHERE ID = %d",
                    questId
                ))
                
                if questQuery then
                    -- Process all item fields above
                    for i = 0, 20 do
                        local itemId = questQuery:GetUInt32(i)
                        if itemId and itemId > 0 then
						    if COLLECTION_ON_PREVIOUS_QUESTS then
                                AddToCollection(player, itemId, true)
							end
                        end
                    end
                end
            until not completedQuery:NextRow()
        end
        
        -- 2. Scan quests in journal - only get StartItem
        local activeQuestsQuery = CharDBQuery(string.format(
            "SELECT quest FROM character_queststatus WHERE guid = %d AND status > 0",
            guid
        ))
        
        if activeQuestsQuery then
            repeat
                local questId = activeQuestsQuery:GetUInt32(0)
                
                -- Only get the StartItem for active quests
                local startItemQuery = WorldDBQuery(string.format(
                    "SELECT StartItem FROM quest_template WHERE ID = %d",
                    questId
                ))
                
                if startItemQuery then
                    local startItem = startItemQuery:GetUInt32(0)
                    if startItem and startItem > 0 then
					    if COLLECTION_ON_PREVIOUS_QUESTS then
                            AddToCollection(player, startItem, true)
						end
                    end
                end
            until not activeQuestsQuery:NextRow()
        end
    end
	
    -- ============================================================================
    -- PLAYER_EVENT_ON_LOGIN - Scan inventory, quests and apply transmogs
    -- ============================================================================    
    local function OnPlayerLogin(event, player)
        if ENABLE_SCAN_ITEMS then
            ScanAllItems(player)
        end
        
        if ENABLE_SCAN_QUESTS then
            ScanAllQuests(player)
        end
        
        if ENABLE_APPLY_ALL_TRANSMOGS then
            ApplyAllTransmogs(player)
            -- Also apply enchant transmogs
            ApplyAllEnchantTransmogs(player)
        end
    end
	
    RegisterPlayerEvent(PLAYER_EVENT_ON_LOGIN, OnPlayerLogin)

    -- ============================================================================
    -- PLAYER_EVENT_ON_LOGOUT - Clear session notification cache
    -- ============================================================================
    
	local function OnPlayerLogout(event, player)
        SessionNotifiedItems[player:GetGUIDLow()] = nil
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_LOGOUT, OnPlayerLogout)
	
    -- ============================================================================
    -- PLAYER_EVENT_ON_EQUIP - Equipement Changes
    -- ============================================================================
    
	local function OnPlayerEquip(event, player, item, bagOrSlot, slot)
        if not player or not item then return end
        
        -- Get the actual slot (bagOrSlot is 255 for equipment slots, slot is the equipment slot)
        local equipSlot = slot
        if bagOrSlot ~= 255 then return end  -- Not an equipment slot
        
        if not TRANSMOG_SLOTS[equipSlot] then return end
        
        -- Add to collection
        local itemId = item:GetEntry()
		if COLLECTION_ON_EQUIP then
            AddToCollection(player, itemId, true)
		end
        
        -- Apply transmog if one is active for this slot
        local guid = player:GetGUIDLow()
        local transmogs = GetActiveTransmogs(guid)
        local activeItemId = transmogs[equipSlot]
        
        if activeItemId then
		    if ENABLE_TRANSMOG_APPLY_TRANSMOG_VISUAL then
                ApplyTransmogVisual(player, equipSlot, activeItemId)
			end
        end
        
        -- Also apply enchant transmog if one is active for this slot
        if IsEnchantEligibleSlot(equipSlot) then
            local enchantTransmogs = GetActiveEnchantTransmogs(guid)
            local activeEnchantId = enchantTransmogs[equipSlot]
            if activeEnchantId then
                -- Use enchant ID directly
                ApplyEnchantVisual(player, equipSlot, activeEnchantId)
            end
        end
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_EQUIP, OnPlayerEquip)
    
    -- ============================================================================
    -- PLAYER_EVENT_ON_LOOT_ITEM - from corpses/chests
    -- ============================================================================
    
    local function OnPlayerLootItem(event, player, item, count)
        if not player or not item then return end
		if COLLECTION_ON_LOOT_ITEM then
            AddToCollection(player, item:GetEntry(), true)
		end
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_LOOT_ITEM, OnPlayerLootItem)

    -- ============================================================================
    -- PLAYER_EVENT_ON_COMMAND
    -- ============================================================================
    
	-- TO DO - GM Command

    -- ============================================================================
    -- PLAYER_EVENT_ON_QUEST_REWARD_ITEM - when pick a reward
    -- ============================================================================
	
    local function OnPlayerQuestRewardItem(event, player, item, count)
        if not player or not item then return end
		if COLLECTION_ON_QUEST_REWARD_ITEM then
            AddToCollection(player, item:GetEntry(), true)
		end
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_QUEST_REWARD_ITEM, OnPlayerQuestRewardItem)

    -- ============================================================================
    -- PLAYER_EVENT_ON_CREATE_ITEM - craft
    -- ============================================================================
	
    local function OnPlayerCreateItem(event, player, item, count)
        if not player or not item then return end
		if COLLECTION_ON_CREATE_ITEM then
            AddToCollection(player, item:GetEntry(), true)
		end
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_CREATE_ITEM, OnPlayerCreateItem)

    -- ============================================================================
    -- PLAYER_EVENT_ON_STORE_NEW_ITEM - eg. character creation and master loot
    -- ============================================================================
	
    -- Store new items (catches master loot rule and items from new characters created)
    local function OnPlayerStoreNewItem(event, player, item, count)
        if not player or not item then return end
		if COLLECTION_ON_STORE_NEW_ITEM then
            AddToCollection(player, item:GetEntry(), true)
		end
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_STORE_NEW_ITEM, OnPlayerStoreNewItem)

    -- ============================================================================
    -- PLAYER_EVENT_ON_COMPLETE_QUEST - when quest is turned 
    -- ============================================================================
	
    -- Quest completion - scan for choice rewards the player may have selected
    local function OnPlayerQuestComplete(event, player, quest)
        if not player or not quest then return end
        
        -- Get quest rewards from world database
        local questId = quest:GetId()
        local query = WorldDBQuery(string.format(
            "SELECT RewardItem1, RewardItem2, RewardItem3, RewardItem4, " ..
            "RewardChoiceItemID1, RewardChoiceItemID2, RewardChoiceItemID3, " ..
            "RewardChoiceItemID4, RewardChoiceItemID5, RewardChoiceItemID6 " ..
            "FROM quest_template WHERE ID = %d",
            questId
        ))
        
        if query then
            -- Add guaranteed quest rewards to collection
            for i = 0, 3 do
                local itemId = query:GetUInt32(i)
                if itemId and itemId > 0 then
				    if COLLECTION_ON_COMPLETE_QUEST then
                        AddToCollection(player, itemId, true)
					end
                end
            end
    		
    		-- Add choices rewards to collection
            for i = 4, 9 do
                local itemId = query:GetUInt32(i)
                if itemId and itemId > 0 then
                    if COLLECTION_ON_COMPLETE_QUEST then
					    AddToCollection(player, itemId, true)
					end
                end
            end
            -- Rewards are handled by PLAYER_EVENT_ON_QUEST_REWARD_ITEM
        end
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_COMPLETE_QUEST, OnPlayerQuestComplete)
   
    -- ============================================================================
    -- PLAYER_EVENT_ON_GROUP_ROLL_REWARD_ITEM - when winning dice roll
    -- ============================================================================
	
    local function OnPlayerGroupRollRewardItem(event, player, item, count, voteType, roll)
        if not player or not item then return end
		if COLLECTION_ON_GROUP_ROLL_REWARD_ITEM then
            AddToCollection(player, item:GetEntry(), true)
		end
    end
    
    RegisterPlayerEvent(PLAYER_EVENT_ON_GROUP_ROLL_REWARD_ITEM, OnPlayerGroupRollRewardItem)
    
    -- ============================================================================
    -- Spell support - Image mirror
    -- ============================================================================
    
    -- TO DO
    
    -- ============================================================================
    -- SERVER STARTUP - Build Cache
    -- ============================================================================
    -- Build the item cache on server startup (called once when script loads)
    -- ============================================================================
    
    BuildServerItemCacheAsync()
       
    print("[mod-transmog-system] AIO Server Bridge loaded")
    print(string.format("[mod-transmog-system] Settings: ALLOW_UNCOLLECTED_TRANSMOG=%s, DEBUG=%s, CACHE_VERSION=%d", 
        tostring(ALLOW_UNCOLLECTED_TRANSMOG), tostring(ENABLE_DEBUG_MESSAGES), CACHE_VERSION))
end