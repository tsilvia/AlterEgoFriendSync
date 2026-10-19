-- Lightweight runtime tests for pure-data behavior. Run from the repository
-- root with: npx -p fengari-node-cli fengari tests/addon_test.lua
--
-- Cases run top-to-bottom and share mutable fixture state. Keep that order.

--------------------------------------------------------------------------------
-- Environment stubs (Fengari / WoW API surface used by the addon)
--------------------------------------------------------------------------------

_G = _G or _ENV
function strmatch(value, pattern) return string.match(value, pattern) end

C_AddOns = {
  GetAddOnMetadata = function(name, field)
    if field == "Title" then return name end
    if field == "Version" then return "test" end
  end,
}
DEFAULT_CHAT_FRAME = {AddMessage = function(_, message) end}
GetServerTime = function() return 1000 end
GetTime = function() return 10 end
time = function() return 1000 end

-- Fengari provides these; WoW's Lua LS runtime does not declare them.
---@type fun(filename: string)
local dofile = _G["dofile"]
---@type fun(filename: string): function?
local loadfile = _G["loadfile"]

dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibSerialize/LibSerialize.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

local function check(case, condition, message)
  assert(condition, case .. ": " .. (message or "failed"))
end

--------------------------------------------------------------------------------
-- Shared fixture
--------------------------------------------------------------------------------

local addon = {}

local function loadModule(filename)
  local chunk = assert(loadfile(filename), "missing " .. filename)
  chunk("AlterEgoFriendSync", addon)
end

local function resetFixture()
  addon.db = {injected = {}}
  AlterEgoDB = {
    global = {
      dbVersion = 38,
      characters = {
        ["Player-1"] = {
          GUID = "Player-1",
          lastUpdate = 100,
          enabled = true,
          order = 9,
          currentSeason = 1,
          info = {
            name = "Alpha",
            realm = "Realm",
            level = 80,
            race = {name = "Human"},
            class = {file = "MAGE", id = 8},
            factionGroup = {},
            ilvl = {level = 600},
            guild = {},
          },
          mythicplus = {
            rating = 1234,
            numCompletedDungeonRuns = {},
            keystone = {level = 7},
            runHistory = {},
            dungeons = {},
          },
          vault = {},
          raids = {},
          equipment = {
            {
              itemName = "Test Helm",
              itemLink = "|cff0070dd|Hitem:12345::::::::80:::::|h[Test Helm]|h|r",
              itemQuality = 3,
              itemLevel = 650,
              itemTexture = 98765,
              itemUpgradeTrack = "Champion",
              itemUpgradeLevel = 4,
              itemUpgradeMax = 8,
              itemSlotID = 1,
              itemSlotName = "Head",
            },
          },
          currencies = {
            {
              id = 1,
              currencyType = "crest",
              quantity = 99,
              totalEarned = 120,
              quantityEarnedThisWeek = 10,
            },
          },
          prey = {
            questsCompleted = {
              [91001] = true,
              [91002] = false,
            },
          },
        },
      },
    },
  }
end

loadModule("Boot.lua")
check("boot", addon.debug == true, "git checkout must enable addon.debug via the @debug@ block")
loadModule("Util.lua")
loadModule("Snapshot.lua")
resetFixture()

--------------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------------

local function test_snapshot_build_own()
  local records = addon.Snapshot:BuildOwn()
  check("snapshot/build", records["Player-1"], "own character was not snapshotted")
  check("snapshot/build", records["Player-1"].equipment[1].itemName == "Test Helm", "equipment name missing")
  check("snapshot/build", records["Player-1"].equipment[1].itemLevel == 650, "equipment item level missing")
  check("snapshot/build", records["Player-1"].equipment[1].itemSlotID == 1, "equipment slot missing")
  check(
    "snapshot/build",
    records["Player-1"].equipment[1].itemUpgradeTrack == "Champion",
    "equipment upgrade track missing"
  )
  check("snapshot/build", records["Player-1"].currencies[1].id == 1, "currency ID missing")
  check("snapshot/build", records["Player-1"].currencies[1].quantity == 99, "currency quantity missing")
  check("snapshot/build", records["Player-1"].currencies[1].totalEarned == 120, "currency total missing")
  check(
    "snapshot/build",
    records["Player-1"].currencies[1].quantityEarnedThisWeek == 10,
    "weekly currency quantity missing"
  )
  check("snapshot/build", records["Player-1"].prey.questsCompleted[91001] == true, "completed prey hunt missing")
  check("snapshot/build", records["Player-1"].prey.questsCompleted[91002] == false, "prey hunt status missing")
  check("snapshot/build", records["Player-1"].mythicplus.rating == 1234, "core data missing")
end

local function test_snapshot_trim_sanitizes()
  local records = addon.Snapshot:BuildOwn()
  local malformed = addon.Util:CopySerializable(records["Player-1"])
  malformed.info.level = {}
  malformed.info.ilvl.level = "not-a-number"
  malformed.currencies[1].quantity = "not-a-number"
  malformed.prey.questsCompleted.invalid = "yes"
  malformed.equipment[1].itemLevel = "not-a-number"
  malformed.mythicplus.dungeons = {
    {challengeModeID = {}, affixScores = {{score = "bad", durationSec = {}}}},
  }

  local sanitized = addon.Snapshot:Trim(malformed)
  check("snapshot/trim", sanitized.info.level == 0, "malformed level was not sanitized")
  check("snapshot/trim", sanitized.info.ilvl.level == 0, "malformed item level was not sanitized")
  check("snapshot/trim", sanitized.currencies[1].quantity == 0, "malformed currency was not sanitized")
  check("snapshot/trim", sanitized.prey.questsCompleted.invalid == nil, "malformed prey hunt was not removed")
  check("snapshot/trim", sanitized.equipment[1].itemLevel == 0, "malformed equipment was not sanitized")
  check(
    "snapshot/trim",
    sanitized.mythicplus.dungeons[1].challengeModeID == 0,
    "malformed dungeon ID was not sanitized"
  )
  check(
    "snapshot/trim",
    sanitized.mythicplus.dungeons[1].affixScores[1].durationSec == 0,
    "malformed affix data was not sanitized"
  )
end

local function test_snapshot_fingerprint()
  local _, fingerprints = addon.Snapshot:BuildOwn()
  local firstFingerprint = fingerprints["Player-1"]

  AlterEgoDB.global.characters["Player-1"].lastUpdate = 999
  AlterEgoDB.global.characters["Player-1"].order = 1
  local _, secondFingerprints = addon.Snapshot:BuildOwn()
  check(
    "snapshot/fingerprint",
    firstFingerprint == secondFingerprints["Player-1"],
    "volatile fields changed the fingerprint"
  )

  AlterEgoDB.global.characters["Player-1"].mythicplus.rating = 1300
  local _, thirdFingerprints = addon.Snapshot:BuildOwn()
  check(
    "snapshot/fingerprint",
    firstFingerprint ~= thirdFingerprints["Player-1"],
    "core change did not change the fingerprint"
  )
end

-- The released 1.1.1 Snapshot module, loaded into its own addon table so it runs
-- exactly as a 1.x client would. Util.lua is unchanged since 1.1.1.
local legacyAddon = {}
assert(loadfile("Util.lua"), "missing Util.lua")("AlterEgoFriendSync", legacyAddon)
assert(loadfile("tests/legacy/Snapshot_1_1_1.lua"), "missing tests/legacy/Snapshot_1_1_1.lua")(
  "AlterEgoFriendSync",
  legacyAddon
)
local LegacySnapshot = legacyAddon.Snapshot

-- The 1.x Fingerprint, which 1.x receivers still use to verify our records.
local function legacyFingerprint(record)
  return LegacySnapshot:Fingerprint(record)
end

local function filled(count, make)
  local result = {}
  for index = 1, count do
    result[index] = make(index)
  end
  return result
end

-- Every array at its Trim limit, far over the record node cap.
local function buildMaxCharacter(questIDOrder)
  local questsCompleted = {}
  for _, questID in ipairs(questIDOrder or filled(150, function(index) return 90000 + index end)) do
    questsCompleted[questID] = questID % 2 == 0
  end
  return {
    GUID = "Player-Max",
    lastUpdate = 100,
    order = 3,
    currentSeason = 1,
    currentSeasonID = 15,
    info = {name = "Max", realm = "Realm", level = 80},
    mythicplus = {
      rating = 3000,
      runHistory = filled(200, function(index)
        return {thisWeek = true, level = index, mapChallengeModeID = index}
      end),
      dungeons = filled(50, function(index)
        return {
          challengeModeID = index,
          bestTimedRun = {},
          bestNotTimedRun = {},
          affixScores = filled(10, function(affix) return {id = affix, name = "Affix", score = affix} end),
        }
      end),
    },
    vault = {
      slots = filled(20, function(index) return {id = index, index = index} end),
      activityEncounterInfo = filled(100, function(index) return {index = index} end),
      worldActivityProgress = filled(50, function(index) return {activityTierID = index} end),
    },
    raids = {
      savedInstances = filled(100, function(index)
        return {
          id = index,
          name = "Raid",
          encounters = filled(100, function(encounter) return {index = encounter, bossName = "Boss"} end),
        }
      end),
    },
    currencies = filled(100, function(index) return {id = index, name = "Currency"} end),
    prey = {questsCompleted = questsCompleted},
    equipment = filled(20, function(index) return {itemName = "Item", itemSlotID = index} end),
  }
end

local function copiedNodeCount(record)
  local state = {seen = {}, count = 0}
  addon.Util:CopySerializable(record, state)
  return state.count
end

local function test_snapshot_fingerprint_matches_legacy()
  local normal = addon.Snapshot:Trim(AlterEgoDB.global.characters["Player-1"])
  check(
    "snapshot/fingerprint-legacy",
    addon.Snapshot:Fingerprint(normal) == legacyFingerprint(normal),
    "normal record fingerprint differs from 1.x"
  )

  local maximum = addon.Snapshot:Trim(buildMaxCharacter())
  check(
    "snapshot/trim-cap",
    copiedNodeCount(maximum) <= 10000,
    "maximum record has " .. copiedNodeCount(maximum) .. " nodes"
  )
  check(
    "snapshot/trim-cap",
    #maximum.raids.savedInstances < 100 and #maximum.mythicplus.dungeons == 50,
    "cap did not drop raid lockouts first"
  )
  check(
    "snapshot/fingerprint-legacy",
    addon.Snapshot:Fingerprint(maximum) == legacyFingerprint(maximum),
    "maximum record fingerprint differs from 1.x"
  )
end

-- A record in Trim's output shape with exactly `target` nodes, as a 1.x sender would
-- produce it. Built without calling Trim on the result so the cap cannot shrink it:
-- 10-boss raid lockouts (67 nodes each) plus prey quests (1 node each) to land exactly.
local function buildRecordWithNodes(target)
  local base = buildMaxCharacter()
  base.raids.savedInstances = {}
  base.prey.questsCompleted = {}
  local record = addon.Snapshot:Trim(base)
  local remaining = target - copiedNodeCount(record)
  local lockoutNodes = 7 + 6 * 10
  local lockouts = math.floor(remaining / lockoutNodes)
  assert(lockouts <= 100, "fixture needs more raid lockouts than Trim keeps")
  record.raids.savedInstances = filled(lockouts, function(index)
    return {
      id = index,
      name = "Raid",
      instanceID = index,
      difficultyID = 16,
      expires = 0,
      encounters = filled(10, function(encounter)
        return {index = encounter, instanceEncounterID = 0, bossName = "Boss", fileDataID = 0, isKilled = true}
      end),
    }
  end)
  for questID = 1, remaining - lockouts * lockoutNodes do
    record.prey.questsCompleted[90000 + questID] = true
  end
  return record, lockouts
end

local function test_snapshot_trim_cap_boundary()
  local atCap, atCapLockouts = buildRecordWithNodes(10000)
  local record = addon.Snapshot:Trim(atCap)
  check("snapshot/cap-boundary", copiedNodeCount(record) == 10000, "fixture is not exactly 10,000 nodes")
  check(
    "snapshot/cap-boundary",
    #record.raids.savedInstances == atCapLockouts,
    "a 10,000-node record was trimmed"
  )
  check(
    "snapshot/cap-boundary",
    addon.Snapshot:Fingerprint(record) == legacyFingerprint(record),
    "a 10,000-node record fingerprints differently from 1.x"
  )

  local overCap, overCapLockouts = buildRecordWithNodes(10001)
  local capped = addon.Snapshot:Trim(overCap)
  check(
    "snapshot/cap-boundary",
    copiedNodeCount(capped) <= 10000 and #capped.raids.savedInstances == overCapLockouts - 1,
    "a 10,001-node record did not drop exactly its last raid lockout"
  )
  check(
    "snapshot/cap-boundary",
    addon.Snapshot:Fingerprint(capped) == legacyFingerprint(capped),
    "a capped record fingerprints differently from 1.x"
  )
end

-- 1.x senders under 10,000 nodes verify today, so a new receiver must not trim them.
local function test_snapshot_legacy_sender_verifies()
  for _, target in ipairs({8001, 9000, 10000}) do
    local sent = buildRecordWithNodes(target)
    check(
      "snapshot/legacy-sender",
      copiedNodeCount(sent) == target,
      "fixture is not exactly " .. target .. " nodes"
    )
    local senderFingerprint = legacyFingerprint(sent)
    local received = addon.Util:CopySerializable(sent)
    check(
      "snapshot/legacy-sender",
      addon.Snapshot:Fingerprint(addon.Snapshot:Trim(received)) == senderFingerprint,
      "a " .. target .. "-node record from a 1.x sender failed to verify"
    )
  end
end

local function test_snapshot_trim_idempotent()
  local serialize = function(record) return addon.Snapshot:SerializeStable(record) end
  for _, character in ipairs({AlterEgoDB.global.characters["Player-1"], buildMaxCharacter()}) do
    local once = addon.Snapshot:Trim(character)
    check(
      "snapshot/trim-idempotent",
      serialize(addon.Snapshot:Trim(once)) == serialize(once),
      "Trim(Trim(x)) differs from Trim(x) for " .. character.GUID
    )
  end
end

local function test_snapshot_trim_deterministic()
  local ascending = filled(150, function(index) return 90000 + index end)
  local descending = filled(150, function(index) return 90151 - index end)
  local first = addon.Snapshot:Trim(buildMaxCharacter(ascending))
  local second = addon.Snapshot:Trim(buildMaxCharacter(descending))
  check(
    "snapshot/trim-deterministic",
    addon.Snapshot:SerializeStable(first) == addon.Snapshot:SerializeStable(second),
    "insertion order changed the trimmed record"
  )
  check(
    "snapshot/trim-prey",
    addon.Util:Count(first.prey.questsCompleted) == 100
      and first.prey.questsCompleted[90100] ~= nil
      and first.prey.questsCompleted[90101] == nil,
    "prey did not keep the 100 lowest quest IDs"
  )
end

local function test_snapshot_run_history_keeps_newest()
  local character = buildMaxCharacter()
  character.mythicplus.runHistory = filled(250, function(index)
    return {thisWeek = index > 245, level = index, mapChallengeModeID = 1}
  end)
  local record = addon.Snapshot:Trim(character)
  local runs = record.mythicplus.runHistory
  local thisWeek = 0
  for _, run in ipairs(runs) do
    if run.thisWeek then thisWeek = thisWeek + 1 end
  end
  check(
    "snapshot/run-history",
    #runs == 200 and runs[1].level == 51 and runs[200].level == 250 and thisWeek == 5,
    "run history did not keep the newest 200 runs"
  )
  check(
    "snapshot/run-history",
    addon.Snapshot:SerializeStable(addon.Snapshot:Trim(record)) == addon.Snapshot:SerializeStable(record),
    "re-trimming the newest 200 runs changed them"
  )
end

-- The cap only cuts raid lockouts, which relies on everything else fitting at its limits.
local function test_snapshot_non_raid_maximum_fits_cap()
  local character = buildMaxCharacter()
  character.raids.savedInstances = {}
  local record = addon.Snapshot:Trim(character)
  check(
    "snapshot/non-raid-maximum",
    copiedNodeCount(record) <= 10000,
    "non-raid data alone exceeds the cap"
  )
  local maximum = addon.Snapshot:Trim(buildMaxCharacter())
  check(
    "snapshot/non-raid-maximum",
    #maximum.mythicplus.runHistory == 200
      and #maximum.mythicplus.dungeons == 50
      and #maximum.vault.activityEncounterInfo == 100
      and #maximum.currencies == 100
      and #maximum.equipment == 20,
    "the cap cut non-raid data"
  )
end

local function test_snapshot_fingerprint_checks_content()
  check(
    "snapshot/fingerprint-input",
    not pcall(addon.Snapshot.Fingerprint, addon.Snapshot, nil),
    "non-table input did not raise"
  )
  check(
    "snapshot/fingerprint-input",
    not pcall(addon.Snapshot.Fingerprint, addon.Snapshot, {GUID = "Player-1", callback = print}),
    "record with a function did not raise"
  )

  local trimmed = addon.Snapshot:Trim(buildMaxCharacter())
  local copy = addon.Util:CopySerializable(trimmed)
  check(
    "snapshot/fingerprint-plain-table",
    addon.Snapshot:Fingerprint(copy) == addon.Snapshot:Fingerprint(trimmed),
    "a plain copy of a trimmed record fingerprinted differently"
  )

  trimmed.info.onClick = print
  local ok, message = pcall(addon.Snapshot.Fingerprint, addon.Snapshot, trimmed)
  check(
    "snapshot/fingerprint-mutated",
    not ok and tostring(message):find("Snapshot:Fingerprint cannot serialize record", 1, true) ~= nil,
    "a function added after Trim was not reported: " .. tostring(message)
  )
end

local function lockout(name, expires, encounterIDs)
  return {
    id = 1,
    name = name,
    instanceID = 1,
    difficultyID = 16,
    expires = expires,
    encounters = filled(#encounterIDs, function(index)
      return {index = index, instanceEncounterID = encounterIDs[index], bossName = "Boss", isKilled = true}
    end),
  }
end

local function lockoutNames(record)
  local names = {}
  for index, instance in ipairs(record.raids.savedInstances) do
    names[index] = instance.name
  end
  return table.concat(names, ",")
end

local function test_snapshot_drops_hidden_lockouts()
  local character = AlterEgoDB.global.characters["Player-1"]
  character.raids = {
    savedInstances = {
      lockout("expired-reset", 0, {3001, 3002}),
      lockout("current", 2000, {3001, 3002}),
      lockout("legacy", 2000, {0, 0, 0}),
      lockout("expired-since-scan", 1000, {3001}),
      lockout("current-name-mismatch", 2000, {3001, 0}),
      lockout("no-encounters", 2000, {}),
    },
  }

  local sent = addon.Snapshot:BuildOwn()["Player-1"]
  check(
    "snapshot/hidden-lockouts",
    lockoutNames(sent) == "current,current-name-mismatch",
    "sent lockouts were " .. lockoutNames(sent)
  )
  check("snapshot/hidden-lockouts", #character.raids.savedInstances == 6, "BuildOwn changed AlterEgo's data")

  local received = addon.Snapshot:Trim(addon.Util:CopySerializable(sent))
  check(
    "snapshot/hidden-lockouts-receiver",
    addon.Snapshot:SerializeStable(received) == addon.Snapshot:SerializeStable(sent)
      and addon.Snapshot:Fingerprint(received) == addon.Snapshot:Fingerprint(sent)
      and legacyFingerprint(received) == addon.Snapshot:Fingerprint(sent),
    "a filtered record did not verify on new and 1.x receivers"
  )

  local legacySent = addon.Snapshot:Trim(character)
  local legacyReceived = addon.Snapshot:Trim(addon.Util:CopySerializable(legacySent))
  check(
    "snapshot/hidden-lockouts-legacy-sender",
    #legacyReceived.raids.savedInstances == 6
      and addon.Snapshot:Fingerprint(legacyReceived) == legacyFingerprint(legacySent),
    "a 1.x record with hidden lockouts failed to verify on a new receiver"
  )

  local manyHidden = filled(120, function() return lockout("legacy", 2000, {0}) end)
  manyHidden[121] = lockout("current", 2000, {3001})
  character.raids = {savedInstances = manyHidden}
  check(
    "snapshot/hidden-lockouts-limit",
    lockoutNames(addon.Snapshot:BuildOwn()["Player-1"]) == "current",
    "hidden lockouts used up Trim's 100-lockout limit"
  )

  character.raids = {}
end

-- Current lockouts sit last, where the cap cuts first; only the hidden ones push the
-- record over 10,000 nodes, so filtering before the cap must leave real progress intact.
local function test_snapshot_hidden_lockouts_filtered_before_cap()
  local tenBosses = filled(10, function(index) return 3000 + index end)
  local noBosses = filled(10, function() return 0 end)
  local character = buildMaxCharacter()
  character.GUID = "Player-Cap"
  character.raids.savedInstances = filled(60, function() return lockout("legacy", 2000, noBosses) end)
  for _ = 1, 3 do
    table.insert(character.raids.savedInstances, lockout("current", 2000, tenBosses))
  end

  local unfiltered = addon.Snapshot:Trim(character)
  check(
    "snapshot/hidden-before-cap",
    not lockoutNames(unfiltered):find("current"),
    "fixture does not make the unfiltered cap drop the current lockouts"
  )

  AlterEgoDB.global.characters["Player-Cap"] = character
  local sent = addon.Snapshot:BuildOwn()["Player-Cap"]
  AlterEgoDB.global.characters["Player-Cap"] = nil
  check(
    "snapshot/hidden-before-cap",
    lockoutNames(sent) == "current,current,current",
    "sent lockouts were " .. lockoutNames(sent)
  )
  check(
    "snapshot/hidden-before-cap",
    #sent.mythicplus.runHistory == 200 and #sent.equipment == 20 and #sent.currencies == 100,
    "the cap dropped data after hidden lockouts were filtered"
  )
  check(
    "snapshot/hidden-before-cap",
    addon.Snapshot:Fingerprint(sent) == legacyFingerprint(sent),
    "filtered record fingerprints differently from 1.x"
  )
end

-- Covers each way 1.1.1 Trim differs: it keeps the first 200 runs and the first
-- 100 prey quests pairs() reaches, has no node cap, and keeps hidden lockouts.
local function compatibilityCharacters()
  local manyRuns = buildMaxCharacter()
  manyRuns.GUID = "Player-Runs"
  manyRuns.raids = {}
  manyRuns.mythicplus.runHistory = filled(250, function(index)
    return {thisWeek = index > 245, level = index, mapChallengeModeID = 1}
  end)

  local hiddenLockouts = buildMaxCharacter()
  hiddenLockouts.GUID = "Player-Hidden"
  hiddenLockouts.raids = {
    savedInstances = {
      lockout("expired", 0, {3001}),
      lockout("legacy", 2000, {0, 0}),
      lockout("current", 2000, {3001, 3002}),
    },
  }

  return {
    AlterEgoDB.global.characters["Player-1"],
    buildMaxCharacter(),
    manyRuns,
    hiddenLockouts,
    (buildRecordWithNodes(10000)),
    (buildRecordWithNodes(10001)),
  }
end

-- What a 1.1.1 receiver does with our DATA: Trim the record, then compare fingerprints.
local function test_snapshot_verifies_on_1x_receiver()
  for _, character in ipairs(compatibilityCharacters()) do
    for _, hiddenLockoutsBefore in ipairs({false, 1000}) do
      local sent = addon.Snapshot:Trim(character, hiddenLockoutsBefore or nil)
      local received = LegacySnapshot:Trim(addon.Util:CopySerializable(sent))
      check(
        "snapshot/1x-receiver",
        LegacySnapshot:Fingerprint(received) == addon.Snapshot:Fingerprint(sent),
        character.GUID .. " (hidden lockouts " .. tostring(hiddenLockoutsBefore) .. ") failed to verify on 1.1.1"
      )
    end
  end
end

-- 1.1.1 records over 10,000 nodes fingerprint a pairs()-order-dependent partial
-- copy, so only records within the cap are expected to verify.
local function test_snapshot_accepts_1x_sender()
  local verified = 0
  for _, character in ipairs(compatibilityCharacters()) do
    local sent = LegacySnapshot:Trim(character)
    if copiedNodeCount(sent) <= 10000 then
      local received = addon.Snapshot:Trim(addon.Util:CopySerializable(sent))
      check(
        "snapshot/1x-sender",
        addon.Snapshot:Fingerprint(received) == LegacySnapshot:Fingerprint(sent),
        "a 1.1.1 record from " .. character.GUID .. " failed to verify"
      )
      verified = verified + 1
    end
  end
  check("snapshot/1x-sender", verified >= 4, "only " .. verified .. " fixtures fit 1.1.1's node cap")
end

local function test_snapshot_excludes_injected()
  addon.db.injected["Player-1"] = "friend#1234"
  local excluded = addon.Snapshot:BuildOwn()
  check("snapshot/injected", not excluded["Player-1"], "injected friend character was re-shared")
  addon.db.injected = {}
end

--------------------------------------------------------------------------------
-- Injection
--------------------------------------------------------------------------------

local function setup_injection()
  local aceAddon = LibStub:NewLibrary("AceAddon-3.0", 1)
  aceAddon.GetAddon = function()
    return {
      Render = function()
        for _, character in pairs(AlterEgoDB.global.characters) do
          character.order = (character.order or 0) + 1
        end
      end,
    }
  end

  addon.db.settings = {view = "mine"}
  addon.db.hiddenOwn = {}
  addon.db.disabledFriends = {}

  local remoteRecord = addon.Snapshot:Trim(AlterEgoDB.global.characters["Player-1"])
  remoteRecord.GUID = "Player-2"
  remoteRecord.info.name = "Beta"
  addon.db.peers = {
    ["friend#1234"] = {
      approved = true,
      snapshots = {["Player-2"] = remoteRecord},
    },
  }

  loadModule("Injection.lua")
  loadModule("UI.lua")
end

local function test_injection_views()
  setup_injection()
  local ownBeforeView = addon.Snapshot:SerializeStable(AlterEgoDB.global.characters["Player-1"])

  addon.Injection:SetView("both")
  check("injection/both", AlterEgoDB.global.characters["Player-1"], "both view removed own character")
  check("injection/both", AlterEgoDB.global.characters["Player-2"], "both view did not inject friend")
  check(
    "injection/both",
    AlterEgoDB.global.characters["Player-2"].info.name:find("Beta", 1, true),
    "friend marker removed name"
  )

  addon.Injection:SetView("friend")
  check(
    "injection/friend",
    AlterEgoDB.global.characters["Player-1"].enabled == false,
    "friend view did not hide own character"
  )
  check(
    "injection/friend",
    AlterEgoDB.global.characters["Player-2"].enabled == true,
    "friend view hid friend character"
  )

  AlterEgoDB.global.characters["Player-2"].enabled = false
  addon.Injection:RefreshView()
  check(
    "injection/disabled-persisted",
    addon.db.disabledFriends["friend#1234"]["Player-2"] == true
      and AlterEgoDB.global.characters["Player-2"].enabled == false,
    "friend checkbox choice was not preserved across refresh"
  )

  AlterEgoDB.global.characters["Player-2"].enabled = true
  addon.Injection:RefreshView()
  check(
    "injection/enabled-persisted",
    addon.db.disabledFriends["friend#1234"] == nil
      and AlterEgoDB.global.characters["Player-2"].enabled == true,
    "re-enabled friend character was not preserved across refresh"
  )

  addon.Injection:Shutdown()
  check(
    "injection/shutdown",
    AlterEgoDB.global.characters["Player-1"].enabled == true,
    "shutdown did not restore own state"
  )
  check(
    "injection/shutdown",
    not AlterEgoDB.global.characters["Player-2"],
    "shutdown did not purge injected friend"
  )
  check(
    "injection/shutdown",
    ownBeforeView == addon.Snapshot:SerializeStable(AlterEgoDB.global.characters["Player-1"]),
    "view cycle changed the own-character record"
  )

  check(
    "injection/source-friend",
    addon.Injection:SetCharacterSource("friend#1234")
      and addon.db.settings.view == "friend"
      and addon.db.settings.selectedPeer == "friend#1234"
      and AlterEgoDB.global.characters["Player-1"].enabled == false
      and AlterEgoDB.global.characters["Player-2"],
    "friend source did not select and show only that friend"
  )
  check(
    "injection/source-friend-checkbox-own",
    not addon.Injection:ShouldShowCharacterCheckbox("Player-1"),
    "friend source left an own-character checkbox visible"
  )
  check(
    "injection/source-friend-checkbox-friend",
    addon.Injection:ShouldShowCharacterCheckbox("Player-2"),
    "friend source hid the selected friend's checkbox"
  )

  local characterMenu = {items = {}}
  function characterMenu:CreateCheckbox(label, isChecked, onClick, value)
    self.items[#self.items + 1] = {label = label, isChecked = isChecked, onClick = onClick, value = value}
  end
  addon.UI:BuildFriendCharacterMenu(characterMenu)
  check(
    "ui/friend-character-menu",
    #characterMenu.items == 1 and characterMenu.items[1].value == "Player-2",
    "friend character menu did not exclude non-selected characters"
  )

  check(
    "injection/source-invalid",
    not addon.Injection:SetCharacterSource("stranger#9999")
      and addon.db.settings.selectedPeer == "friend#1234",
    "invalid friend source changed the selection"
  )
  check(
    "injection/source-mine",
    addon.Injection:SetCharacterSource(nil)
      and addon.db.settings.view == "mine"
      and addon.db.settings.selectedPeer == nil
      and AlterEgoDB.global.characters["Player-1"].enabled == true
      and not AlterEgoDB.global.characters["Player-2"],
    "own-character source did not restore the local view"
  )
end

--------------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------------

local function setup_transport()
  C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return 0 end,
    InChatMessagingLockdown = function() return false end,
    AreOutgoingAddonChatMessagesRestricted = function() return false end,
  }
  C_BattleNet = {SendGameData = function() return 0 end}
  C_Timer = {
    NewTicker = function() return {Cancel = function() end} end,
    After = function(_, callback) callback() end,
  }
  Enum = {
    SendAddonMessageResult = {
      Success = 0,
      AddonMessageThrottle = 3,
      ChannelThrottle = 8,
      AddOnMessageLockdown = 11,
    },
    RegisterAddonMessagePrefixResult = {Success = 0, DuplicatePrefix = 1},
  }

  loadModule("Transport.lua")

  -- LibDeflate targets WoW's Lua 5.1 numeric/bit behavior and its compressed
  -- output does not round-trip under Fengari's Lua 5.3 VM. Keep transport logic
  -- testable here with an identity codec; the bundled canonical LibDeflate build
  -- must be exercised in the live-client checklist.
  local deflater = LibStub("LibDeflate")
  deflater.CompressDeflate = function(_, value) return value end
  deflater.DecompressDeflate = function(_, value) return value end
  deflater.EncodeForWoWAddonChannel = function(_, value) return value end
  deflater.DecodeForWoWAddonChannel = function(_, value) return value end
end

local function test_serializer_round_trip()
  local serializer = LibStub("LibSerialize")
  local raw = serializer:Serialize({value = "round trip"})
  local deserializeOK = serializer:Deserialize(raw)
  check("transport/serialize", deserializeOK, "serializer round-trip failed")
end

local function test_transport_out_of_order_reassembly()
  local received
  addon.Protocol = {
    CanReceiveFrame = function() return true end,
    Receive = function(_, sourceType, sourceID, envelope)
      received = {sourceType, sourceID, envelope}
    end,
  }

  local payload = addon.Transport:EncodeEnvelope("DATA", {value = string.rep("abc", 1000)})
  local directEnvelope = addon.Transport:DecodeEnvelope(payload, "DATA")
  check(
    "transport/envelope",
    directEnvelope and directEnvelope.kind == "DATA",
    "direct envelope round-trip failed"
  )

  local chunks = assert(addon.Transport:FramePayload("DATA", payload, 100))
  for index = #chunks, 1, -1 do
    addon.Transport:Receive("BNET", 42, chunks[index])
  end

  check("transport/reassemble", received, "out-of-order transfer was not reassembled")
  check("transport/reassemble", received[1] == "BNET" and received[2] == 42, "sender metadata changed")
  check("transport/reassemble", received[3].kind == "DATA", "message kind changed")
  check(
    "transport/reassemble",
    received[3].body.value == string.rep("abc", 1000),
    "payload changed"
  )
end

--------------------------------------------------------------------------------
-- Protocol
--------------------------------------------------------------------------------

local lockedDown = false
local buildOwnCalls = 0
local sentIndexTo = {}

local function setup_protocol()
  C_ChatInfo.InChatMessagingLockdown = function() return lockedDown end
  loadModule("Protocol.lua")

  local buildOwn = addon.Snapshot.BuildOwn
  addon.Snapshot.BuildOwn = function(...)
    buildOwnCalls = buildOwnCalls + 1
    return buildOwn(...)
  end
  addon.Transport.Send = function(_, runtimePeer, kind)
    if kind == "INDEX" then
      sentIndexTo[#sentIndexTo + 1] = runtimePeer.key
    end
    return true
  end

  local protocol = addon.Protocol
  addon.db.peers = {
    ["online#1"] = {key = "online#1", battleTag = "Online#1", approved = true},
    ["online#2"] = {key = "online#2", battleTag = "Online#2", approved = true},
    ["offline#3"] = {key = "offline#3", battleTag = "Offline#3", approved = true},
  }
  protocol.friendsByBattleTag = {
    ["online#1"] = {key = "online#1", online = true, gameAccountID = 11},
    ["online#2"] = {key = "online#2", online = true, gameAccountID = 12},
    ["offline#3"] = {key = "offline#3", online = false},
  }
end

local function resetProtocolCounters()
  buildOwnCalls = 0
  sentIndexTo = {}
end

local function test_protocol_offline_not_queued()
  local protocol = addon.Protocol
  resetProtocolCounters()
  lockedDown = true
  local sent, err = protocol:SendIndex(addon.db.peers["offline#3"])
  check("protocol/offline-queue", not sent and err == "friend is offline", "offline friend was not rejected")
  check("protocol/offline-queue", not protocol.pendingIndex["offline#3"], "offline friend was queued during lockdown")
  check("protocol/offline-queue", buildOwnCalls == 0, "offline friend triggered BuildOwn")

  lockedDown = false
  protocol:SendRequestedData(addon.db.peers["offline#3"], {"Player-1"})
  check("protocol/offline-data", buildOwnCalls == 0, "offline data request triggered BuildOwn")
end

local function test_protocol_flush_builds_once()
  local protocol = addon.Protocol
  resetProtocolCounters()
  protocol.pendingIndex = {}
  lockedDown = true
  for _, peer in pairs(addon.db.peers) do
    protocol:SendIndex(peer)
  end
  check(
    "protocol/lockdown-queue",
    protocol.pendingIndex["online#1"] and protocol.pendingIndex["online#2"] and not protocol.pendingIndex["offline#3"],
    "lockdown did not queue exactly the online friends"
  )
  check("protocol/lockdown-queue", buildOwnCalls == 0, "queuing during lockdown triggered BuildOwn")

  -- A friend who logs off mid-lockdown is skipped at flush time.
  protocol.friendsByBattleTag["online#2"].online = false
  lockedDown = false
  protocol:FlushPending()
  check("protocol/flush", buildOwnCalls == 1, "flush ran BuildOwn " .. buildOwnCalls .. " times")
  check(
    "protocol/flush",
    #sentIndexTo == 1 and sentIndexTo[1] == "online#1",
    "flush did not send INDEX to only the online friend"
  )
  check("protocol/flush", next(protocol.pendingIndex) == nil, "flush left friends queued")
  protocol.friendsByBattleTag["online#2"].online = true

  resetProtocolCounters()
  protocol.pendingIndex = {["offline#3"] = true}
  protocol:FlushPending()
  check("protocol/flush-offline", buildOwnCalls == 0, "flush with only offline friends triggered BuildOwn")
end

local function sentToBothOnline()
  table.sort(sentIndexTo)
  return #sentIndexTo == 2 and sentIndexTo[1] == "online#1" and sentIndexTo[2] == "online#2"
end

local function test_protocol_broadcast_builds_once()
  local protocol = addon.Protocol
  lockedDown = false

  resetProtocolCounters()
  protocol:CheckForChanges(true)
  check("protocol/check-changes", buildOwnCalls == 1, "CheckForChanges ran BuildOwn " .. buildOwnCalls .. " times")
  check("protocol/check-changes", sentToBothOnline(), "CheckForChanges did not send INDEX to both online friends")

  resetProtocolCounters()
  protocol:SyncAll()
  check("protocol/sync-all", buildOwnCalls == 1, "SyncAll ran BuildOwn " .. buildOwnCalls .. " times")
  check("protocol/sync-all", sentToBothOnline(), "SyncAll did not send INDEX to both online friends")

  resetProtocolCounters()
  lockedDown = true
  protocol:SyncAll()
  check("protocol/sync-all-lockdown", buildOwnCalls == 0, "SyncAll during lockdown triggered BuildOwn")
  lockedDown = false
  protocol.pendingIndex = {}

  resetProtocolCounters()
  protocol.friendsByBattleTag["online#1"].online = false
  protocol.friendsByBattleTag["online#2"].online = false
  protocol:SyncAll()
  check("protocol/sync-all-offline", buildOwnCalls == 0, "SyncAll with no friend online triggered BuildOwn")

  resetProtocolCounters()
  protocol.lastLocalFingerprints = {stale = "keep"}
  protocol:CheckForChanges(true)
  check("protocol/check-changes-offline", buildOwnCalls == 0, "CheckForChanges with no friend online triggered BuildOwn")
  check("protocol/check-changes-offline", #sentIndexTo == 0, "CheckForChanges with no friend online sent an INDEX")
  check(
    "protocol/check-changes-offline",
    protocol.lastLocalFingerprints.stale == "keep",
    "offline check replaced stale fingerprints"
  )

  protocol.friendsByBattleTag["online#1"].online = true
  protocol.friendsByBattleTag["online#2"].online = true
  resetProtocolCounters()
  protocol:CheckForChanges()
  check("protocol/check-changes-stale", buildOwnCalls == 1, "next check after friends return ran BuildOwn " .. buildOwnCalls .. " times")
  check("protocol/check-changes-stale", sentToBothOnline(), "stale fingerprints did not send INDEX once a friend was online")

  -- One approved friend online is enough to build and send. The offline approved
  -- friends must not suppress that, and they must not receive an INDEX.
  protocol.friendsByBattleTag["online#2"].online = false
  resetProtocolCounters()
  protocol:CheckForChanges(true)
  check("protocol/check-changes-mixed", buildOwnCalls == 1, "CheckForChanges with one friend online ran BuildOwn " .. buildOwnCalls .. " times")
  check(
    "protocol/check-changes-mixed",
    #sentIndexTo == 1 and sentIndexTo[1] == "online#1",
    "CheckForChanges did not send INDEX only to the online friend"
  )
  protocol.friendsByBattleTag["online#2"].online = true
end

local function test_protocol_sync_all_shares_refresh_build()
  local protocol = addon.Protocol
  local friends = {
    {battleTag = "Online#1", game = {gameAccountID = 11, characterName = "One", realmName = "Realm"}},
    {battleTag = "Online#2", game = {gameAccountID = 12, characterName = "Two", realmName = "Realm"}},
    {battleTag = "Offline#3"},
  }
  local savedFriends = protocol.friendsByBattleTag
  BNET_CLIENT_WOW = "WoW"
  BNGetNumFriends = function() return #friends end
  C_BattleNet.GetFriendAccountInfo = function(index)
    return {battleTag = friends[index].battleTag, bnetAccountID = index}
  end
  C_BattleNet.GetFriendNumGameAccounts = function(index)
    return friends[index].game and 1 or 0
  end
  C_BattleNet.GetFriendGameAccountInfo = function(index)
    local game = friends[index].game
    return {
      isOnline = true,
      clientProgram = "WoW",
      wowProjectID = 1,
      gameAccountID = game.gameAccountID,
      characterName = game.characterName,
      realmName = game.realmName,
    }
  end

  -- online#2 was offline at the last refresh, so RefreshFriends sends it an
  -- INDEX before SyncAll sends one to every online friend.
  savedFriends["online#2"].online = false
  lockedDown = false
  resetProtocolCounters()
  protocol:SyncAll()
  check("protocol/sync-all-refresh", buildOwnCalls == 1, "SyncAll with a newly online friend ran BuildOwn " .. buildOwnCalls .. " times")
  table.sort(sentIndexTo)
  check(
    "protocol/sync-all-refresh",
    #sentIndexTo == 3 and sentIndexTo[1] == "online#1" and sentIndexTo[2] == "online#2" and sentIndexTo[3] == "online#2",
    "SyncAll did not index the newly online friend from both RefreshFriends and SyncAll"
  )

  BNET_CLIENT_WOW = nil
  BNGetNumFriends = nil
  C_BattleNet.GetFriendAccountInfo = nil
  C_BattleNet.GetFriendNumGameAccounts = nil
  C_BattleNet.GetFriendGameAccountInfo = nil
  savedFriends["online#2"].online = true
  protocol.friendsByBattleTag = savedFriends
  protocol.friendsByGameAccount = {}
  protocol.friendsByCharacter = {}
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

test_snapshot_build_own()
test_snapshot_trim_sanitizes()
test_snapshot_fingerprint()
test_snapshot_fingerprint_matches_legacy()
test_snapshot_legacy_sender_verifies()
test_snapshot_trim_cap_boundary()
test_snapshot_trim_idempotent()
test_snapshot_trim_deterministic()
test_snapshot_fingerprint_checks_content()
test_snapshot_run_history_keeps_newest()
test_snapshot_non_raid_maximum_fits_cap()
test_snapshot_drops_hidden_lockouts()
test_snapshot_hidden_lockouts_filtered_before_cap()
test_snapshot_verifies_on_1x_receiver()
test_snapshot_accepts_1x_sender()
test_snapshot_excludes_injected()

test_injection_views()

setup_transport()
test_serializer_round_trip()
test_transport_out_of_order_reassembly()

setup_protocol()
test_protocol_offline_not_queued()
test_protocol_flush_builds_once()
test_protocol_broadcast_builds_once()
test_protocol_sync_all_shares_refresh_build()

print("AlterEgoFriend data, transport, and protocol tests passed.")
