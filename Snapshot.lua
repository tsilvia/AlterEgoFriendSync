local _, addon = ...

local Util = addon.Util
local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

local Snapshot = {}
addon.Snapshot = Snapshot

local function tableOrEmpty(value)
  return type(value) == "table" and value or {}
end

local function text(value)
  if type(value) ~= "string" then
    return ""
  end
  -- self imposed limit of 2048 characters for safety
  return value:sub(1, 2048)
end

local function number(value)
  local parsed
  if type(value) == "number" then
    parsed = value
  elseif type(value) == "string" then
    parsed = tonumber(value)
  end
  -- Reject nil, NaN (the only value where x ~= x), and ±infinity.
  if not parsed or parsed ~= parsed or parsed == math.huge or parsed == -math.huge then
    return 0
  end
  return parsed
end

local function boundedArray(source, maximum, mapper)
  local result = {}
  if type(source) ~= "table" then
    return result
  end
  for index = 1, math.min(#source, maximum) do
    local mapped = mapper(source[index])
    if mapped then
      result[#result + 1] = mapped
    end
  end
  return result
end

-- Like boundedArray, but keeps the last `maximum` entries. With `maximum` or fewer
-- entries both keep everything, so 1.x receivers leave the result unchanged.
local function newestBoundedArray(source, maximum, mapper)
  local result = {}
  if type(source) ~= "table" then
    return result
  end
  for index = math.max(1, #source - maximum + 1), #source do
    local mapped = mapper(source[index])
    if mapped then
      result[#result + 1] = mapped
    end
  end
  return result
end

local function trimInfo(sourceInfo)
  sourceInfo = tableOrEmpty(sourceInfo)
  local sourceRace = tableOrEmpty(sourceInfo.race)
  local sourceClass = tableOrEmpty(sourceInfo.class)
  local sourceFaction = tableOrEmpty(sourceInfo.factionGroup)
  local sourceIlvl = tableOrEmpty(sourceInfo.ilvl)
  local sourceGuild = tableOrEmpty(sourceInfo.guild)
  return {
    name = text(sourceInfo.name),
    realm = text(sourceInfo.realm),
    level = number(sourceInfo.level),
    race = {name = text(sourceRace.name), file = text(sourceRace.file), id = number(sourceRace.id)},
    class = {name = text(sourceClass.name), file = text(sourceClass.file), id = number(sourceClass.id)},
    factionGroup = {english = text(sourceFaction.english), localized = text(sourceFaction.localized)},
    ilvl = {
      level = number(sourceIlvl.level),
      equipped = number(sourceIlvl.equipped),
      pvp = number(sourceIlvl.pvp),
      color = text(sourceIlvl.color) ~= "" and text(sourceIlvl.color) or "ffffffff",
    },
    guild = {
      isInGuild = sourceGuild.isInGuild == true,
      name = text(sourceGuild.name),
      rankName = text(sourceGuild.rankName),
      rankIndex = number(sourceGuild.rankIndex),
      realm = text(sourceGuild.realm),
    },
  }
end

local function trimMythicplus(sourceMythic)
  sourceMythic = tableOrEmpty(sourceMythic)
  local sourceRuns = tableOrEmpty(sourceMythic.numCompletedDungeonRuns)
  local sourceKeystone = tableOrEmpty(sourceMythic.keystone)
  return {
    rating = number(sourceMythic.rating),
    bestSeasonScore = number(sourceMythic.bestSeasonScore),
    bestSeasonNumber = number(sourceMythic.bestSeasonNumber),
    numCompletedDungeonRuns = {
      heroic = number(sourceRuns.heroic),
      mythic = number(sourceRuns.mythic),
      mythicPlus = number(sourceRuns.mythicPlus),
    },
    keystone = {
      challengeModeID = number(sourceKeystone.challengeModeID),
      mapId = number(sourceKeystone.mapId),
      level = number(sourceKeystone.level),
      color = text(sourceKeystone.color),
      itemId = number(sourceKeystone.itemId),
      itemLink = text(sourceKeystone.itemLink),
    },
    -- C_MythicPlus.GetRunHistory lists oldest first; this week's runs drive the vault display.
    runHistory = newestBoundedArray(sourceMythic.runHistory, 200, function(run)
      if type(run) ~= "table" then return nil end
      return {
        thisWeek = run.thisWeek == true,
        level = number(run.level),
        mapChallengeModeID = number(run.mapChallengeModeID),
      }
    end),
    dungeons = boundedArray(sourceMythic.dungeons, 50, function(dungeon)
      if type(dungeon) ~= "table" then return nil end
      return {
        challengeModeID = number(dungeon.challengeModeID),
        rating = number(dungeon.rating),
        level = number(dungeon.level),
        finishedSuccess = dungeon.finishedSuccess == true,
        bestOverAllScore = number(dungeon.bestOverAllScore),
        bestTimedRun = type(dungeon.bestTimedRun) == "table" and {} or nil,
        bestNotTimedRun = type(dungeon.bestNotTimedRun) == "table" and {} or nil,
        affixScores = boundedArray(dungeon.affixScores, 10, function(score)
          if type(score) ~= "table" then return nil end
          return {
            id = number(score.id),
            name = text(score.name),
            score = number(score.score),
            level = number(score.level),
            durationSec = number(score.durationSec),
            overTime = score.overTime == true,
          }
        end),
      }
    end),
  }
end

local function trimVault(sourceVault)
  sourceVault = tableOrEmpty(sourceVault)
  return {
    hasAvailableRewards = sourceVault.hasAvailableRewards == true,
    slots = boundedArray(sourceVault.slots, 20, function(slot)
      if type(slot) ~= "table" then return nil end
      return {
        id = number(slot.id),
        type = number(slot.type),
        index = number(slot.index),
        progress = number(slot.progress),
        threshold = number(slot.threshold),
        level = number(slot.level),
        activityTierID = number(slot.activityTierID),
        exampleRewardLink = text(slot.exampleRewardLink),
        exampleRewardUpgradeLink = text(slot.exampleRewardUpgradeLink),
      }
    end),
    activityEncounterInfo = boundedArray(sourceVault.activityEncounterInfo, 100, function(encounter)
      if type(encounter) ~= "table" then return nil end
      return {
        type = number(encounter.type),
        index = number(encounter.index),
        instanceID = number(encounter.instanceID),
        encounterID = number(encounter.encounterID),
        bestDifficulty = number(encounter.bestDifficulty),
      }
    end),
    worldActivityProgress = boundedArray(sourceVault.worldActivityProgress, 50, function(progress)
      if type(progress) ~= "table" then return nil end
      return {
        activityTierID = number(progress.activityTierID),
        difficulty = number(progress.difficulty),
        numPoints = number(progress.numPoints),
      }
    end),
  }
end

local function trimCurrencies(sourceCurrencies)
  return boundedArray(sourceCurrencies, 100, function(currency)
    if type(currency) ~= "table" then return nil end
    return {
      id = number(currency.id),
      currencyType = text(currency.currencyType),
      name = text(currency.name),
      iconFileID = number(currency.iconFileID),
      quantity = number(currency.quantity),
      totalEarned = number(currency.totalEarned),
      quantityEarnedThisWeek = number(currency.quantityEarnedThisWeek),
      maxQuantity = number(currency.maxQuantity),
      maxWeeklyQuantity = number(currency.maxWeeklyQuantity),
      bagCount = number(currency.bagCount),
      hasBuff = currency.hasBuff == true,
      questCompleted = currency.questCompleted == true,
    }
  end)
end

local MAX_PREY_QUESTS = 100

local function heapSwap(heap, a, b)
  heap[a], heap[b] = heap[b], heap[a]
end

-- Max-heap of quest IDs: heap[1] is always the largest kept ID.
local function heapPush(heap, value)
  heap[#heap + 1] = value
  local index = #heap
  while index > 1 do
    local parent = math.floor(index / 2)
    if heap[parent] >= heap[index] then
      return
    end
    heapSwap(heap, parent, index)
    index = parent
  end
end

local function heapReplaceTop(heap, value)
  heap[1] = value
  local index = 1
  while true do
    local largest = index
    local left, right = index * 2, index * 2 + 1
    if heap[left] and heap[left] > heap[largest] then largest = left end
    if heap[right] and heap[right] > heap[largest] then largest = right end
    if largest == index then
      return
    end
    heapSwap(heap, index, largest)
    index = largest
  end
end

-- Keeps the 100 lowest quest IDs so the same data always trims to the same record.
-- Holds at most 100 IDs while scanning, so a huge quest table is never copied or sorted.
local function trimPrey(sourcePrey)
  local completedByID = {}
  local kept = {}
  for questID, completed in pairs(tableOrEmpty(tableOrEmpty(sourcePrey).questsCompleted)) do
    local sanitizedID = number(questID)
    if sanitizedID > 0 and type(completed) == "boolean" then
      if completedByID[sanitizedID] ~= nil then
        -- "91001" and 91001 sanitize to the same ID; true wins regardless of pairs() order.
        completedByID[sanitizedID] = completedByID[sanitizedID] or completed
      elseif #kept < MAX_PREY_QUESTS then
        heapPush(kept, sanitizedID)
        completedByID[sanitizedID] = completed
      elseif sanitizedID < kept[1] then
        -- The largest kept ID only shrinks, so an evicted ID can never come back.
        completedByID[kept[1]] = nil
        heapReplaceTop(kept, sanitizedID)
        completedByID[sanitizedID] = completed
      end
    end
  end

  local questsCompleted = {}
  for _, questID in ipairs(kept) do
    questsCompleted[questID] = completedByID[questID]
  end
  return {questsCompleted = questsCompleted}
end

local function trimEquipment(sourceEquipment)
  return boundedArray(sourceEquipment, 20, function(item)
    if type(item) ~= "table" then return nil end
    return {
      itemName = text(item.itemName),
      itemLink = text(item.itemLink),
      itemQuality = number(item.itemQuality),
      itemLevel = number(item.itemLevel),
      itemMinLevel = number(item.itemMinLevel),
      itemType = text(item.itemType),
      itemSubType = text(item.itemSubType),
      itemStackCount = number(item.itemStackCount),
      itemEquipLoc = text(item.itemEquipLoc),
      itemTexture = number(item.itemTexture),
      sellPrice = number(item.sellPrice),
      classID = number(item.classID),
      subclassID = number(item.subclassID),
      bindType = number(item.bindType),
      expansionID = number(item.expansionID),
      setID = number(item.setID),
      isCraftingReagent = item.isCraftingReagent == true,
      itemUpgradeTrack = text(item.itemUpgradeTrack),
      itemUpgradeLevel = number(item.itemUpgradeLevel),
      itemUpgradeMax = number(item.itemUpgradeMax),
      itemUpgradeColor = text(item.itemUpgradeColor),
      itemSlotID = number(item.itemSlotID),
      itemSlotName = text(item.itemSlotName),
    }
  end)
end

-- AlterEgo only displays unexpired lockouts of current-season raids, and stores
-- instanceEncounterID = 0 for every encounter of a raid outside that list. A single
-- zero can be a boss-name mismatch inside a current raid, so all must be zero.
local function isHiddenLockout(instance, now)
  if type(instance) ~= "table" or number(instance.expires) <= now then
    return true
  end
  local encounters = tableOrEmpty(instance.encounters)
  for index = 1, math.min(#encounters, 100) do
    local encounter = encounters[index]
    if type(encounter) == "table" and number(encounter.instanceEncounterID) ~= 0 then
      return false
    end
  end
  return true
end

-- 1.x clients fingerprint through Util:CopySerializable, which silently stops
-- copying after 10,000 nodes. This must equal that limit: lower would reject 1.x
-- records that verify today, higher would hash differently on 1.x receivers.
local MAX_RECORD_NODES = 10000

-- Counts every key at every depth, the same way Util:CopySerializable charges its limit.
local function countNodes(value)
  local count = 0
  for _, child in pairs(value) do
    count = count + 1
    if type(child) == "table" then
      count = count + countNodes(child)
    end
  end
  return count
end

local function trimLockout(instance)
  return {
    id = number(instance.id),
    name = text(instance.name),
    instanceID = number(instance.instanceID),
    difficultyID = number(instance.difficultyID),
    expires = number(instance.expires),
    encounters = boundedArray(instance.encounters, 100, function(encounter)
      if type(encounter) ~= "table" then return nil end
      return {
        index = number(encounter.index),
        instanceEncounterID = number(encounter.instanceEncounterID),
        bossName = text(encounter.bossName),
        fileDataID = number(encounter.fileDataID),
        isKilled = encounter.isKilled == true,
      }
    end),
  }
end

-- Builds raid lockouts in order until the next one would exceed `budget` nodes.
-- Everything else at its Trim limits stays under MAX_RECORD_NODES, so lockouts are
-- the only overflow. Stopping at the first misfit, rather than skipping it, keeps
-- the result a prefix that 1.x Trim leaves as-is.
-- Receivers keep the first 100 source entries; own records skip hidden lockouts
-- first and keep the first 100 visible ones.
local function trimLockouts(sourceRaids, hiddenLockoutsBefore, budget)
  local lockouts = {}
  local savedInstances = tableOrEmpty(sourceRaids).savedInstances
  if type(savedInstances) ~= "table" then
    return lockouts
  end
  for index = 1, #savedInstances do
    if not hiddenLockoutsBefore and index > 100 then
      break
    end
    local instance = savedInstances[index]
    local hidden = hiddenLockoutsBefore and isHiddenLockout(instance, hiddenLockoutsBefore)
    if not hidden and type(instance) == "table" then
      local lockout = trimLockout(instance)
      local cost = 1 + countNodes(lockout)
      if cost > budget then
        break
      end
      budget = budget - cost
      lockouts[#lockouts + 1] = lockout
      if #lockouts == 100 then
        break
      end
    end
  end
  return lockouts
end

-- Sanitize a character into a shareable record with typed fields and bounded arrays.
-- Pass hiddenLockoutsBefore (a time() timestamp) only when building our own records:
-- receivers must not drop lockouts, or records from 1.x senders would stop verifying.
function Snapshot:Trim(character, hiddenLockoutsBefore)
  if type(character) ~= "table" or type(character.GUID) ~= "string" or character.GUID == "" then
    return nil
  end

  local record = {
    GUID = character.GUID,
    lastUpdate = number(character.lastUpdate),
    currentSeason = number(character.currentSeason),
    currentSeasonID = character.currentSeasonID ~= nil and number(character.currentSeasonID) or nil,
    enabled = true,
    order = number(character.order),
    info = trimInfo(character.info),
    mythicplus = trimMythicplus(character.mythicplus),
    vault = trimVault(character.vault),
    raids = {savedInstances = {}},
    currencies = trimCurrencies(character.currencies),
    prey = trimPrey(character.prey),
    equipment = trimEquipment(character.equipment),

    -- Money remains local-only.
    money = 0,
  }
  record.raids.savedInstances = trimLockouts(
    character.raids,
    hiddenLockoutsBefore,
    MAX_RECORD_NODES - countNodes(record)
  )
  return record
end

-- Serialize with stable key order so identical tables always produce the same bytes.
function Snapshot:SerializeStable(value)
  return LibSerialize:SerializeEx({
    stable = true,
    errorOnUnserializableType = true,
  }, value)
end

-- These are local presentation/activity fields. AlterEgo rewrites order while
-- rendering and touches lastUpdate for unrelated events, so including either
-- would create false network updates.
local FINGERPRINT_EXCLUDED = {order = true, enabled = true, lastUpdate = true}

-- Content hash of a record, ignoring local presentation fields that would cause false updates.
function Snapshot:Fingerprint(record)
  if type(record) ~= "table" then
    error("Snapshot:Fingerprint expects a table, got " .. type(record), 2)
  end
  local fingerprintRecord = {}
  for key, value in pairs(record) do
    if not FINGERPRINT_EXCLUDED[key] then
      fingerprintRecord[key] = value
    end
  end
  local ok, serialized = pcall(self.SerializeStable, self, fingerprintRecord)
  if not ok then
    error("Snapshot:Fingerprint cannot serialize record: " .. tostring(serialized), 2)
  end
  return tostring(LibDeflate:Adler32(serialized)) .. ":" .. tostring(#serialized)
end

-- Build this player's shareable records and fingerprints, excluding injected friend characters.
function Snapshot:BuildOwn()
  local characters = Util:GetAlterEgoCharacters()
  local records = {}
  local fingerprints = {}
  if not characters then
    return records, fingerprints
  end

  -- Snapshot each owned character; skip friend-injected rows so we do not re-share them.
  local injected = addon.db and addon.db.injected or {}
  -- AlterEgo stamps lockout expiry with time(), not server time.
  local now = time()
  for guid, character in pairs(characters) do
    if not injected[guid] then
      local record = self:Trim(character, now)
      if record then
        records[guid] = record
        fingerprints[guid] = self:Fingerprint(record)
      end
    end
  end
  return records, fingerprints
end

function Snapshot:IsValidRecord(record)
  if type(record) ~= "table" or type(record.GUID) ~= "string" or record.GUID == "" then
    return false
  end
  if type(record.info) ~= "table" or type(record.info.name) ~= "string" then
    return false
  end
  if type(record.mythicplus) ~= "table" or type(record.vault) ~= "table" or type(record.raids) ~= "table" then
    return false
  end
  return true
end
