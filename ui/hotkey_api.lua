-- Native Hotkey API
-- MD forwards consumer registration requests (id/area/isObjectRequired/name/
-- actionCue/actionLua) via a dedicated blackboard-list channel, mirroring
-- sn_mod_support_apis' Interact_Menu_API Send_Command/Get_Next_Args pattern
-- (raise_lua_event cannot reliably carry a complex/nested table as its
-- param - only a bare notification is safe; the actual payload must travel
-- via blackboard). This file owns the single bound-hotkeys registry
-- (persisted to its own player blackboard var so slot assignments survive
-- Lua's own reload, since Lua state itself does not), dispatches via a
-- direct SetScript("onHotkey", ...) registration (the pool lives in the
-- always-active INPUT_CONTEXT_ADDON_DEBUGLOG context), and feeds the
-- General Controls page via OnDisplayControlsOrder.

local ffi = require("ffi")
local C = ffi.C
ffi.cdef [[
	typedef uint64_t UniverseID;
	UniverseID GetPlayerID(void);
	UniverseID GetPlayerOccupiedShipID(void);
	const char* GetPlayerCurrentControlGroup(void);
	typedef struct {
		uint64_t softtargetID;
		const char* softtargetConnectionName;
		uint32_t messageID;
	} SofttargetDetails2;
	SofttargetDetails2 GetSofttarget2(void);
]]

local PAGE_ID = 1972092431
local CONTROLS_PAGE_ID = "hotkey_api_controls"
local MANAGEMENT_PAGE_ID = "hotkey_api_management"
local REQUESTS_PAGE_ID = "hotkey_api_requests"

-- Protocol version this build understands. A registration request may
-- carry its own request.version (default 1 if omitted) - anything newer
-- than this is rejected outright in ProcessRegistration, rather than risk
-- silently misinterpreting a contract this build doesn't know about yet.
-- onHotKey's dispatch is likewise versioned per bound record.
local API_VERSION = 1

-- Must be declared before debugLog() below so debugLog can see it as an
-- upvalue - default true (matches the always-on behaviour this mod has had
-- so far) until LoadDebugEnabled() restores the player's actual choice.
local debugEnabled = false

local function debugLog(fmt, ...)
  if not debugEnabled then
    return
  end
  if select("#", ...) > 0 then
    DebugError("Hotkey API: " .. string.format(fmt, ...))
  else
    DebugError("Hotkey API: " .. fmt)
  end
end

-- Working pool: DEBUG_0-9, DEBUG_A-Z, DEBUG_F1-F12 (48 actions), in the exact
-- order matching their confirmed-contiguous numeric ids 23-70 (discovery
-- method/evidence in claude/mod-hotkey_api.md). INSERT/DELETE/NUMPAD0-9/
-- SPACE/PAGEUP/PAGEDOWN are deliberately excluded (mixed/unresolved id
-- confidence).
local POOL = {
  "INPUT_ACTION_DEBUG_0", "INPUT_ACTION_DEBUG_1", "INPUT_ACTION_DEBUG_2", "INPUT_ACTION_DEBUG_3",
  "INPUT_ACTION_DEBUG_4", "INPUT_ACTION_DEBUG_5", "INPUT_ACTION_DEBUG_6", "INPUT_ACTION_DEBUG_7",
  "INPUT_ACTION_DEBUG_8", "INPUT_ACTION_DEBUG_9",
  "INPUT_ACTION_DEBUG_A", "INPUT_ACTION_DEBUG_B", "INPUT_ACTION_DEBUG_C", "INPUT_ACTION_DEBUG_D",
  "INPUT_ACTION_DEBUG_E", "INPUT_ACTION_DEBUG_F", "INPUT_ACTION_DEBUG_G", "INPUT_ACTION_DEBUG_H",
  "INPUT_ACTION_DEBUG_I", "INPUT_ACTION_DEBUG_J", "INPUT_ACTION_DEBUG_K", "INPUT_ACTION_DEBUG_L",
  "INPUT_ACTION_DEBUG_M", "INPUT_ACTION_DEBUG_N", "INPUT_ACTION_DEBUG_O", "INPUT_ACTION_DEBUG_P",
  "INPUT_ACTION_DEBUG_Q", "INPUT_ACTION_DEBUG_R", "INPUT_ACTION_DEBUG_S", "INPUT_ACTION_DEBUG_T",
  "INPUT_ACTION_DEBUG_U", "INPUT_ACTION_DEBUG_V", "INPUT_ACTION_DEBUG_W", "INPUT_ACTION_DEBUG_X",
  "INPUT_ACTION_DEBUG_Y", "INPUT_ACTION_DEBUG_Z",
  "INPUT_ACTION_DEBUG_F1", "INPUT_ACTION_DEBUG_F2", "INPUT_ACTION_DEBUG_F3", "INPUT_ACTION_DEBUG_F4",
  "INPUT_ACTION_DEBUG_F5", "INPUT_ACTION_DEBUG_F6", "INPUT_ACTION_DEBUG_F7", "INPUT_ACTION_DEBUG_F8",
  "INPUT_ACTION_DEBUG_F9", "INPUT_ACTION_DEBUG_F10", "INPUT_ACTION_DEBUG_F11", "INPUT_ACTION_DEBUG_F12",
}

-- Numeric id = 23 + (position in POOL - 1); confirmed contiguous in-game.
local POOL_NUMERIC_IDS = {}
for i, actionId in ipairs(POOL) do
  POOL_NUMERIC_IDS[actionId] = 22 + i
end

local POOL_NUMERIC_IDS_REVERSE = {}
for slot, numericId in pairs(POOL_NUMERIC_IDS) do
  POOL_NUMERIC_IDS_REVERSE[numericId] = slot
end

local BLACKBOARD_BOUND = "$hotkey_api_bound"
local BLACKBOARD_SELECTED = "$hotkey_api_selected"
local BLACKBOARD_ACTION_CUE = "$hotkey_api_action_cue"
local BLACKBOARD_REQUESTS = "$hotkey_api_requests"
local BLACKBOARD_BLOCKED = "$hotkey_api_blocked"
-- Same name MD's debug_text calls check directly (player.entity.$hotkey_api_debug_enabled)
-- to gate their own output, so toggling this from the Requests page silences
-- both Lua's debugLog() and MD's debug_text in lockstep.
local BLACKBOARD_DEBUG_ENABLED = "$hotkey_api_debug_enabled"

-- Declared via <savedvariable name="__NATIVE_HOTKEY_API_DATA" storage="userdata" />
-- in ui.xml - a real global (not local), tied to the player's profile/
-- installation rather than any one savegame (same storage class keybindings
-- themselves use), so it survives across new games/different saves. Used to
-- gate the one-time ClearAllUnboundSlots() sweep below: that sweep only
-- matters once, the very first time this mod ever runs on a given profile
-- (to clean up any leftover bindings on these pool slots predating this
-- mod's ownership of them) - every load after that, normal slot-claim/free
-- bookkeeping already keeps things clean, so re-running the full sweep on
-- every single game load/start is unnecessary.
__NATIVE_HOTKEY_API_DATA = __NATIVE_HOTKEY_API_DATA or {}

local hotkeyApi = {}

local mapMenu = nil
local optionsMenu = nil
local playerId = nil

-- boundHotkeys: keyed by slot (a POOL action-id string) ->
-- {id, area, isObjectRequired, name, actionCue, actionLua, version, confirmed}.
-- The live, in-memory-only dispatch registry, rebuilt fresh from scratch by
-- registrations every reload - never persisted itself (actionLua is a real
-- Lua function value, which can't be written to the blackboard in any shape,
-- and actionCue/area/etc. don't need to survive a reload anyway, since every
-- consumer is required to re-send its registration every time Reloaded
-- fires). onHotKey and the UI pages read this for the *current* session's
-- dispatch/display data only.
local boundHotkeys = {}

-- usedSlots: keyed by slot -> {id, confirmed}. The only thing that actually
-- needs to survive a Lua reload - which slot is durably claimed by which id,
-- so a re-registering consumer reclaims the *same* physical slot (and thus
-- the player's existing key binding for it) instead of a different one.
--
-- blockedIds: keyed by request id -> true. The player's decision to block an
-- id, which must survive reload/restart too - ids in here are skipped by
-- ProcessRegistration's slot-claiming, freeing/keeping their slot free for
-- other ids. Managed entirely from the "Hotkey Requests" management page.
--
-- Both live in __NATIVE_HOTKEY_API_DATA (userdata storage - see its own
-- declaration comment above), not the player blackboard: these are reference
-- assignments in Init() (MigrateFromBlackboardIfNeeded), so mutating
-- usedSlots[slot]/blockedIds[id] directly mutates the same persisted tables -
-- no separate Save call needed, unlike the player blackboard. Blackboard
-- storage lives *inside* the savegame, while the actual key bindings these
-- track live at the profile level (same as every other keybinding, never
-- saved in the savegame at all) - so loading an older save than the one a
-- hotkey was last bound in would make that hotkey look unclaimed again even
-- though its key binding never went away, and registering it "fresh" would
-- wipe that still-live binding. Userdata storage matches the same
-- profile-level scope the key bindings themselves use, so this can't happen
-- once migrated.
local usedSlots = {}
local blockedIds = {}

-- allRequests: flat list of every id seen via Register_Action this session,
-- whether or not it currently holds a slot (unlike boundHotkeys, which only
-- knows about ids that got one). Session-only by design - cleared and
-- rebuilt from scratch every time the Reloaded broadcast goes out, so a
-- consumer that stops registering disappears from the management page after

local allRequests = {}

-- allRequestNames: keyed by request id -> display name, for every id seen via
-- Register_Action this session, whether or not it currently holds a slot
-- (unlike boundHotkeys, which only knows about ids that got one). Session-
-- only by design - cleared and rebuilt from scratch every time the Reloaded
-- broadcast goes out, so a consumer that stops registering disappears from
-- the management page after the next refresh instead of lingering forever.
local allRequestNames = {}

-- Current page (1-based) of the requests-management table; reset whenever
-- the page is (re)opened so a stale page index from a previous, longer list
-- doesn't leave the view stuck past the end of a shorter one.
local requestsPage = 1

-- Local queue of pending registration requests, drained from
-- BLACKBOARD_REQUESTS - mirrors sn_mod_support_apis' Interact_Menu_API
-- L.queued_args/L.Get_Next_Args() exactly (md appends to a blackboard list
-- via append_to_list, then raises a bare event; lua pulls the whole list in
-- one go, queues it locally, and clears the blackboard var so md can start
-- filling it again).
local pendingRequests = {}

-- One-time migration from the old player-blackboard-based persistence (the
-- list-of-{slot,id}/list-of-id formats SaveUsedSlots/SaveBlockedIds used to
-- write) into __NATIVE_HOTKEY_API_DATA. Only runs the blackboard reads while
-- __NATIVE_HOTKEY_API_DATA.usedSlots/.blockedIds are still nil (i.e. never
-- migrated on this profile before) - after this, both are real tables
-- stored directly there, no list-conversion needed at all (a plain Lua
-- global isn't subject to SetNPCBlackboard's table-key-to-MD-member
-- conversion), and the blackboard is never read or written again for this
-- data.
local function MigrateFromBlackboardIfNeeded()
  if __NATIVE_HOTKEY_API_DATA.usedSlots == nil then
    local migrated = {}
    local ok, stored = pcall(GetNPCBlackboard, playerId, BLACKBOARD_BOUND)
    if ok and (type(stored) == "table") then
      for _, entry in ipairs(stored) do
        if (type(entry) == "table") and (type(entry.slot) == "string") and (type(entry.id) == "string") then
          -- confirmed=false until a fresh registration re-claims it this
          -- session - mirrors the previous boundHotkeys-based Clearance flow.
          migrated[entry.slot] = { id = entry.id, confirmed = false }
        end
      end
      debugLog("MigrateFromBlackboardIfNeeded: migrated %d slot/id association(s) from blackboard to userdata", #stored)
    end
    __NATIVE_HOTKEY_API_DATA.usedSlots = migrated
  end

  if __NATIVE_HOTKEY_API_DATA.blockedIds == nil then
    local migrated = {}
    local ok, stored = pcall(GetNPCBlackboard, playerId, BLACKBOARD_BLOCKED)
    if ok and (type(stored) == "table") then
      for _, id in ipairs(stored) do
        if type(id) == "string" then
          migrated[id] = true
        end
      end
      debugLog("MigrateFromBlackboardIfNeeded: migrated %d blocked id(s) from blackboard to userdata", #stored)
    end
    __NATIVE_HOTKEY_API_DATA.blockedIds = migrated
  end

  -- Reassign the upvalues used everywhere else in this file to point at the
  -- same persisted tables - every function below that reads/writes
  -- usedSlots[...]/blockedIds[...] is mutating __NATIVE_HOTKEY_API_DATA's
  -- own tables from here on, so no explicit save call is ever needed.
  usedSlots = __NATIVE_HOTKEY_API_DATA.usedSlots
  blockedIds = __NATIVE_HOTKEY_API_DATA.blockedIds
end

local function SaveDebugEnabled()
  SetNPCBlackboard(playerId, BLACKBOARD_DEBUG_ENABLED, debugEnabled)
end

local function GetNextRequest()
  if #pendingRequests == 0 then
    local ok, requestList = pcall(GetNPCBlackboard, playerId, BLACKBOARD_REQUESTS)
    if ok and (type(requestList) == "table") then
      for _, request in ipairs(requestList) do
        table.insert(pendingRequests, request)
      end
      debugLog("GetNextRequest: pulled %d request(s) from blackboard", #requestList)
    end
    -- Clear the md var by writing nil, so md can start filling it again.
    SetNPCBlackboard(playerId, BLACKBOARD_REQUESTS, nil)
  end
  return table.remove(pendingRequests, 1)
end

local function FindSlotById(id)
  for slot, used in pairs(usedSlots) do
    if used.id == id then
      return slot
    end
  end
  return nil
end

local function FindFreeSlot()
  for _, slot in ipairs(POOL) do
    if not usedSlots[slot] then
      return slot
    end
  end
  return nil
end

local function HasFreeSlot()
  return FindFreeSlot() ~= nil
end

-- "bound" (currently holds a slot) / "blocked" (deliberately disabled by the
-- player on the requests page) / "waiting" (enabled, but the pool was full
-- the last time it tried to claim a slot).
local function GetRequestStatus(id)
  if blockedIds[id] then
    return "blocked"
  elseif FindSlotById(id) then
    return "bound"
  else
    return "waiting"
  end
end

-- Human-readable text for whatever key(s) are currently bound to a slot's
-- numeric action id, or nil if nothing is bound yet. Reuses
-- menu.getInputName (gameoptions.xpl:5177) - the same function the vanilla
-- remap UI itself uses to render a key's display name - via optionsMenu,
-- since it's a method on the same shared menu table, not a standalone
-- global.
local function GetAssignedKeyText(slot)
  local numericId = POOL_NUMERIC_IDS[slot]
  if not (numericId and optionsMenu and optionsMenu.getInputName) then
    return nil
  end
  local ok, actions = pcall(GetInputActionMap)
  if not ok or (type(actions) ~= "table") then
    return nil
  end
  local inputs = actions[numericId]
  if type(inputs) ~= "table" then
    return nil
  end

  local names = {}
  for _, input in ipairs(inputs) do
    local nameOk, name = pcall(optionsMenu.getInputName, input[1], input[2], input[3] or 0)
    if nameOk and (type(name) == "string") and (name ~= "") then
      table.insert(names, name)
    end
  end
  if #names == 0 then
    return nil
  end
  return table.concat(names, " / ")
end

-- Clears any key currently bound to this slot's numeric action id (e.g. a
-- leftover from previous testing/an earlier mod that used this same pool
-- slot), so a freshly claimed slot starts genuinely unbound and the player
-- has to consciously assign a key via the General Controls page. Must only
-- be called once, at first claim - never on a re-registration of an already
-- known id, or it would wipe the player's own chosen key on every reload.
local function ClearSlotBinding(slot)
  local numericId = POOL_NUMERIC_IDS[slot]
  if not numericId then
    return
  end
  local ok, actions = pcall(GetInputActionMap)
  if not ok or (type(actions) ~= "table") then
    debugLog("ClearSlotBinding: GetInputActionMap() failed for slot %s", slot)
    return
  end
  if actions[numericId] == nil then
    debugLog("ClearSlotBinding: slot %s (numeric id %d) already unbound", slot, numericId)
    return
  end
  actions[numericId] = nil
  local saveOk, saveErr = pcall(SaveInputSettings, actions, GetInputStateMap(), GetInputRangeMap())
  if saveOk then
    debugLog("ClearSlotBinding: cleared pre-existing key binding for slot %s (numeric id %d)", slot, numericId)
  else
    debugLog("ClearSlotBinding: SaveInputSettings failed for slot %s: %s", slot, tostring(saveErr))
  end
end

-- Sweeps the entire pool (in order, checking every slot individually - a
-- free slot can be in the middle of otherwise-bound ones, e.g. after a mod
-- that used to register an id stops doing so) and clears the key binding of
-- every slot NOT currently claimed in usedSlots (loaded from userdata, or
-- migrated from the blackboard, by MigrateFromBlackboardIfNeeded). Run once
-- at startup, before notifying md, so unclaimed slots never carry a leftover
-- binding into a fresh session regardless of whether anything ever claims
-- them.
local function ClearAllUnboundSlots()
  local clearedCount = 0
  for _, slot in ipairs(POOL) do
    if usedSlots[slot] == nil then
      clearedCount = clearedCount + 1
      ClearSlotBinding(slot)
    end
  end
  debugLog("ClearAllUnboundSlots: checked %d unbound slot(s) out of %d pool slot(s)", clearedCount, #POOL)
end


-- Minimum request.version each area token requires - not just a flat
-- valid/invalid set, so a future version can introduce a new area value
-- without retroactively making it usable by a request that explicitly
-- declared an older version. "other" is deliberately never listed here:
-- there is no selected-object notion there for isObjectRequired to fall
-- back on, so onHotKey always blocks dispatch while currentArea == "other"
-- regardless of what a record's area set contains, and it is never a valid
-- value to request either.
local AREA_MIN_VERSION = {
  map = 1,
  pilot = 1,
  fps = 1,
}

-- Parses request.area ("map", "pilot", or "map;pilot" in either order) into
-- a set table ({map=true, pilot=true, ...}) for an O(1) lookup at dispatch
-- time in onHotKey, instead of string comparisons. requestVersion gates
-- which tokens are accepted (AREA_MIN_VERSION[token] <= requestVersion) -
-- a request that explicitly declares an older version only ever sees the
-- areas that existed at that version, even if this build now supports
-- newer ones too. Returns nil (invalid) for anything not a non-empty
-- string of only recognised, version-eligible, ";"-separated tokens - area
-- is mandatory, there is no default to fall back on.
local function ParseAreas(areaString, requestVersion)
  if type(areaString) ~= "string" then
    return nil
  end
  local areas = {}
  for token in areaString:gmatch("[^;]+") do
    token = token:match("^%s*(.-)%s*$")
    local minVersion = AREA_MIN_VERSION[token]
    if (not minVersion) or (requestVersion < minVersion) then
      return nil
    end
    areas[token] = true
  end
  if not next(areas) then
    return nil
  end
  return areas
end

-- For debugLog only - turns an area set back into a readable "map;pilot"
-- string (sorted, so the order is stable across calls).
local function AreaSetToString(areaSet)
  if type(areaSet) ~= "table" then
    return tostring(areaSet)
  end
  local parts = {}
  for area in pairs(areaSet) do
    table.insert(parts, area)
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

-- Validates and fully normalizes a raw registration request before
-- anything is recorded anywhere (allRequests/boundHotkeys/etc.) - every
-- field is checked here, up front; ProcessRegistration below never reads
-- the raw `request` table again once this succeeds, only the returned,
-- known-good copy. Returns (normalized) on success, or (nil, reason) on
-- failure.
local function ValidateRequest(request)
  if type(request) ~= "table" then
    return nil, "request is not a table"
  end
  if (type(request.id) ~= "string") or (request.id == "") then
    return nil, "id is missing or not a non-empty string"
  end

  local version = tonumber(request.version) or 1
  if (version < 1) or (version ~= math.floor(version)) then
    return nil, "version must be a positive integer"
  end
  if version > API_VERSION then
    return nil, string.format("version %d is newer than supported %d", version, API_VERSION)
  end

  local areas = ParseAreas(request.area, version)
  if not areas then
    return nil,
        string.format("area '%s' is missing/invalid for version %d (must be one or more of 'map', 'pilot', 'fps', separated by ';' if more than one)", tostring(request.area), version)
  end

  local isObjectRequired = request.isObjectRequired
  local isObjectRequiredValid = (isObjectRequired == nil) or (isObjectRequired == true) or (isObjectRequired == false)
      or (isObjectRequired == 0) or (isObjectRequired == 1)
  if not isObjectRequiredValid then
    return nil, "isObjectRequired must be a boolean (or MD's 1/0) if provided"
  end

  if (request.name ~= nil) and (type(request.name) ~= "string") then
    return nil, "name must be a string if provided"
  end

  if (request.actionCue ~= nil) and (request.actionLua ~= nil) then
    return nil, "actionCue and actionLua are mutually exclusive - provide only one"
  end

  return {
    id = request.id,
    version = version,
    areas = areas,
    -- Normalized to a real boolean once, here, instead of every dispatch -
    -- accepts MD's 1/0 marshalling or a real Lua boolean either way.
    isObjectRequired = (isObjectRequired == true) or (isObjectRequired == 1),
    name = request.name or request.id,
    actionCue = request.actionCue,
    actionLua = request.actionLua,
  }
end

-- Shared by both registration entry points (MD's Register_Action, via
-- OnRegisterAction/GetNextRequest below, and the direct-Lua HotkeyApi.
-- RegisterAction global) - everything from here on is source-agnostic.
-- request: table with id/area/isObjectRequired/name/actionCue/actionLua,
-- same shape either path supplies it in.
local function ProcessRegistration(request)
  debugLog("ProcessRegistration received, id: %s", (request and request.id) or "nil")

  local normalized, reason = ValidateRequest(request)
  if not normalized then
    debugLog("ProcessRegistration: invalid request (%s) - rejecting", tostring(reason))
    return
  end

  -- From here on, only `normalized` is used - never the raw `request` -
  -- so nothing partially-invalid can leak into allRequests/boundHotkeys.

  -- Tracked for the requests-management page regardless of slot/block
  -- status - this is the only place that knows about every id a consumer
  -- ever tries to register, bound or not.
  allRequestNames[normalized.id] = normalized.name
  allRequests[#allRequests + 1] = normalized.id

  if blockedIds[normalized.id] then
    -- Deliberately disabled by the player. Defensively free+clear any slot
    -- it might still hold (shouldn't normally happen - blocking already does
    -- this - but guards against any path that skipped that step).
    local boundSlot = FindSlotById(normalized.id)
    if boundSlot then
      boundHotkeys[boundSlot] = nil
      usedSlots[boundSlot] = nil
      ClearSlotBinding(boundSlot)
    end
    debugLog("ProcessRegistration: id '%s' is blocked - skipping slot claim", normalized.id)
    return
  end

  local slot = FindSlotById(normalized.id)
  if not slot then
    slot = FindFreeSlot()
    if not slot then
      debugLog("no free slot left for id '" .. normalized.id .. "' - pool exhausted")
      return
    end
    debugLog("ProcessRegistration: claimed new slot %s for id '%s'", slot, normalized.id)
    ClearSlotBinding(slot)
  else
    debugLog("ProcessRegistration: reusing existing slot %s for id '%s'", slot, normalized.id)
  end

  boundHotkeys[slot] = {
    id = normalized.id,
    area = normalized.areas,
    isObjectRequired = normalized.isObjectRequired,
    name = normalized.name,
    actionCue = normalized.actionCue,
    actionLua = normalized.actionLua,
    version = normalized.version,
    confirmed = true,
  }
  usedSlots[slot] = { id = normalized.id, confirmed = true }

  if optionsMenu and ((optionsMenu.currentOption == CONTROLS_PAGE_ID) or (optionsMenu.currentOption == REQUESTS_PAGE_ID)) then
    optionsMenu.refresh()
  end
end

function hotkeyApi.OnRegisterAction(_, _)
  local request = GetNextRequest()
  if not request or (type(request) ~= "table") or (type(request.id) ~= "string") then
    debugLog("OnRegisterAction received an invalid request")
    return
  else
    request.actionLua = nil
  end
  ProcessRegistration(request)
end

-- Public, global entry point for other mods' Lua files to register hotkeys
-- directly - no blackboard-list relay needed for this path, since a normal
-- Lua function call has none of raise_lua_event's "can't carry a complex/
-- nested table" limitation (that workaround was only ever needed for the
-- MD boundary). Same request shape as MD's Register_Action cue, except
-- actionLua may be a real Lua function (invoked directly from onHotKey)
-- rather than (or in addition to) actionCue (an MD cue reference).
--
-- Lua consumers should call this every time they receive the
-- "HotkeyApi.Register_Request" event (raised by md.HotkeyApi.
-- Reset_On_Lua_Reload, mirroring MD's Reloaded cue) - registrations must be
-- re-sent on every reload, since function references don't survive Lua's
-- own reload any more than cue references survive MD's.
--
-- Usage:
--   RegisterEvent("HotkeyApi.Register_Request", function()
--     HotkeyApi.RegisterAction({
--       id = "my_mod_my_action",
--       area = "any",
--       isObjectRequired = false,
--       name = "My Action",
--       actionLua = function(params) ... end,
--     })
--   end)
HotkeyApi = HotkeyApi or {}

function HotkeyApi.RegisterAction(request)
  if not (type(request) == "table" and type(request.id) == "string") then
    debugLog("HotkeyApi.RegisterAction: invalid request table")
    return
  else
    request.actionCue = nil
  end
  return ProcessRegistration(request)
end

function hotkeyApi.ClearUnconfirmed()
  debugLog("Clearance: clearing not confirmed (stale) used slots")
  for slot, used in pairs(usedSlots) do
    if not used.confirmed then
      debugLog("Clearance: slot %s for id '%s' was not confirmed - clearing", slot, tostring(used.id))
      ClearSlotBinding(slot)
      usedSlots[slot] = nil
      boundHotkeys[slot] = nil
    end
  end
end

-- More precise than just "no menu is shown" - that would also be true while
-- walking around inside a ship/station, or sitting docked with no menu open.
-- Mirrors the check vanilla's ego_detailmonitor/menu_docked.lua uses to
-- decide whether to pop the docked menu: occupies a ship, that ship isn't
-- docked, and the player's own control post is specifically the pilot seat
-- (not a turret/secondary gunner position).
local function IsActuallyPiloting()
  local occupiedShip = ConvertStringTo64Bit(tostring(C.GetPlayerOccupiedShipID()))
  if occupiedShip == 0 then
    return false
  end
  local controlPost = ffi.string(C.GetPlayerCurrentControlGroup())
  return (controlPost == "pilotcontrol") and (not GetComponentData(occupiedShip, "isdocked"))
end

local function detectCurrentArea()
  local currentMenu = nil
  for _, menu in ipairs(Menus) do
    if menu.shown then
      currentMenu = menu
      break
    end
  end
  if currentMenu and currentMenu.name ~= "TopLevelMenu" then
    if currentMenu.name == "MapMenu" then
      return "map"
    else
      return "other"
    end
  elseif IsActuallyPiloting() then
    return "pilot"
  elseif IsFirstPerson() then
    return "fps"
  else
    return "other"
  end
end

-- Returns the selected/targeted object component id for the given area, or
-- nil. "map" uses the map's selected component, "pilot" uses GetPlayerTarget(),
-- "fps" uses C.GetSofttarget2() (the object the player's crosshair is on).
local function GetSelectedObjectForArea(area)
  if area == "map" and mapMenu then
    local selectedComponent = nil
    if next(mapMenu.selectedcomponents) then
      for id, _ in pairs(mapMenu.selectedcomponents) do
        selectedComponent = ConvertStringTo64Bit(id)
        if IsValidComponent(selectedComponent) then
          break
        end
        selectedComponent = nil
      end
    end
    return selectedComponent
  elseif area == "pilot" then
    local target = GetPlayerTarget()
    if target and (target ~= 0) then
      return target
    end
    return nil
  elseif area == "fps" then
    local softtarget = C.GetSofttarget2()
    local id = tonumber(softtarget.softtargetID)
    if id and (id ~= 0) and IsValidComponent(id) then
      return id
    end
    return nil
  end
  return nil
end

function hotkeyApi.onHotKey(action)
  debugLog("onHotKey: received action '%s'", tostring(action))
  local record = boundHotkeys[action]
  if not record then
    return
  end

  local currentArea = detectCurrentArea()
  debugLog("onHotKey: action %s fired for id '%s' (area=%s, isObjectRequired=%s, currentArea=%s)",
    action, tostring(record.id), AreaSetToString(record.area), tostring(record.isObjectRequired), tostring(currentArea))

  if (currentArea == "other") or (not record.area[currentArea]) then
    debugLog("onHotKey: area mismatch (record.area=%s, currentArea=%s) - skipping", AreaSetToString(record.area), tostring(currentArea))
    -- PlaySound("ui_target_set_fail")
    return
  end

  -- Versioned dispatch - everything below is the version 1 contract.
  -- Records persisted before versioning existed have no .version field;
  -- treat those as version 1 too (ProcessRegistration defaults the same
  -- way for incoming requests missing request.version).
  local version = record.version or 1
  if version == 1 then
    local selected = GetSelectedObjectForArea(currentArea)
    -- Normalized to a real boolean by ValidateRequest at registration time
    -- (accepts MD's 1/0 or a real Lua boolean either way) - no need to
    -- re-check both forms on every single dispatch.
    local isObjectRequired = record.isObjectRequired

    if isObjectRequired and not selected then
      debugLog("onHotKey: isObjectRequired but no selection/target for area '%s' - skipping", tostring(record.area))
      -- PlaySound("ui_target_set_fail")
      return
    elseif isObjectRequired then
      debugLog("onHotKey: isObjectRequired and selected object/component %s for area '%s'", tostring(selected), tostring(record.area))
    else
      debugLog("onHotKey: isObjectRequired not set - but target/selection is %s for area '%s'", tostring(selected), tostring(record.area))
    end

    -- Direct-Lua dispatch: a real function call, no blackboard/event relay
    -- needed at all (that machinery only exists for the MD boundary).
    if record.actionLua then
      debugLog("onHotKey: dispatching actionLua callback for id '%s' (slot %s)", tostring(record.id), action)
      local ok, err = pcall(record.actionLua, { id = record.id, object = selected })
      if not ok then
        debugLog("onHotKey: actionLua callback for id '%s' errored: %s", tostring(record.id), tostring(err))
      end
      return
    end

    -- MD dispatch: only relevant (and only pays the blackboard-write/event
    -- cost) when an MD cue was actually registered for this id.
    if record.actionCue then
      if selected then
        SetNPCBlackboard(playerId, BLACKBOARD_SELECTED, ConvertStringToLuaID(tostring(selected)))
      else
        SetNPCBlackboard(playerId, BLACKBOARD_SELECTED, nil)
      end
      SetNPCBlackboard(playerId, BLACKBOARD_ACTION_CUE, record.actionCue)
      AddUITriggeredEvent("HotkeyApi", "execute_action", record.id)
      debugLog("onHotKey: dispatched execute_action (MD) for id '%s' (slot %s)", tostring(record.id), action)
      return
    end
  else
    debugLog("onHotKey: id '%s' has unsupported version %s - skipping", tostring(record.id), tostring(version))
  end
end

-- Row name resolution: menu.getControlName("actions", code) always reads
-- ReadText(1005, code) - a static vanilla text page with no entry for our
-- DEBUG action ids, so a plain {"actions", numericId, ...} row falls back to
-- showing the bare number. ADDON_DETAILMONITOR_I/etc. avoid this exact
-- problem by using {"functions", N} rows instead: getControlName("functions",
-- N) reads config.input.controlFunctions[N].name - a plain Lua table we can
-- write into ourselves. Offsetting by 100000 keeps our keys well clear of
-- Ego's own controlFunctions entries (seen only in the low hundreds).
local FUNCTION_KEY_BASE = 100000

-- Maps each area token to the vanilla controlsorder page names that a hotkey
-- fired in that area can conflict with.
-- pilot: only active in space flight, no overlap with walking.
-- map: active while the map overlay is open - conflicts with all menu controls
--      AND with space controls that carry context 2 (e.g. camera, diplomacy
--      shortcuts - many General controls remain active under the map).
-- fps: only active on foot, no overlap with space controls.
local AREA_PAGES = {
  pilot = { space = true },
  map   = { space = true, menus = true },
  fps   = { firstperson = true },
}

-- Maps menu.currentOption (the active controls-page key while remapping) to the
-- corresponding config.input.controlsorder page name.
local OPTION_TO_PAGE = {
  keyboard_space       = "space",
  keyboard_menus       = "menus",
  keyboard_firstperson = "firstperson",
}

-- Caches which controlsorder page each vanilla action ID belongs to.
-- Built in OnDisplayControlsOrder (before our hotkey_api page is registered)
-- and refreshed on every render so it stays in sync.
local actionIdToPages = {}

local function BuildActionIdToPages(config)
  actionIdToPages = {}
  for pageName, pageGroups in pairs(config.input.controlsorder) do
    if pageName ~= "hotkey_api" then
      for _, group in ipairs(pageGroups) do
        for _, entry in ipairs(group) do
          if type(entry) == "table" then
            if entry[1] == "actions" then
              local t = actionIdToPages[entry[2]]
              if not t then t = {}; actionIdToPages[entry[2]] = t end
              t[pageName] = true
            elseif entry[1] == "functions" then
              local func = config.input.controlFunctions[entry[2]]
              if func then
                for _, actionId in ipairs(func.actions or {}) do
                  local t = actionIdToPages[actionId]
                  if not t then t = {}; actionIdToPages[actionId] = t end
                  t[pageName] = true
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Returns the set of page names (e.g. {space=true, menus=true}) that conflict
-- with a given slot's registered area. Empty table if slot has no record.
local function GetSlotAffectedPages(slot)
  local record = boundHotkeys[slot]
  if not record or not record.area then return {} end
  local pages = {}
  for area in pairs(record.area) do
    if AREA_PAGES[area] then
      for pageName in pairs(AREA_PAGES[area]) do
        pages[pageName] = true
      end
    end
  end
  return pages
end

-- Own submenu (not appended to "General Controls" anymore): routed through
-- menu.displayControls (proper remap/add/remove/reset buttons, same as
-- ADDON_DETAILMONITOR_I/etc.) via the new generic
-- menu.uix_callbacks["submenuHandler_isControlsPage"][optionParameter] hook
-- added to gameoptions.xpl's menu.submenuHandler. menu.controlsorder starts
-- empty for any optionParameter not one of the 3 vanilla keyboard pages, so
-- this hook is the only thing populating it - no stale-row removal needed
-- the way the old "appended to keyboard_space" version required.
function hotkeyApi.OnDisplayControlsOrder(optionParameter, controlsorder, config)
  -- Build controlFunctions entries and register our page in
  -- config.input.controlsorder unconditionally (not only when our own page is
  -- rendered) so that vanilla's checkForConflicts(checkall=true) in
  -- gameoptions.xpl - which does pairs(config.input.controlsorder) - finds
  -- our bindings when the player remaps on any controls page, not just ours.
  -- displayControls_modifyControlsOrder fires for every controls page render
  -- (space/menus/firstperson as well as our own), so config is always current.
  local groupRow = {
    id = "hotkey_api_group",
    title = ReadText(PAGE_ID, 1100),
    mappable = true,
  }
  local rowCount = 0
  if config and config.input and config.input.controlFunctions then
    for _, slot in ipairs(POOL) do
      local record = boundHotkeys[slot]
      local numericId = POOL_NUMERIC_IDS[slot]
      if record and numericId then
        local functionKey = FUNCTION_KEY_BASE + numericId
        config.input.controlFunctions[functionKey] = {
          name = record.name,
          definingcontrol = { "actions", numericId },
          actions = { numericId },
          states = {},
          ranges = {},
          contexts = { 1, 2 },
        }
        rowCount = rowCount + 1
        groupRow[rowCount] = { "functions", functionKey }
      end
    end
    if config.input.controlsorder then
      BuildActionIdToPages(config)
      config.input.controlsorder["hotkey_api"] = { groupRow }
    end
  end

  if optionParameter ~= CONTROLS_PAGE_ID then
    return controlsorder
  end

  debugLog("OnDisplayControlsOrder: rendering %d bound row(s) on own page", rowCount)

  table.insert(controlsorder, groupRow)

  return controlsorder
end

-- Predicate callback for gameoptions.xpl's "submenuHandler_isControlsPage"
-- hook, registered via the normal registerCallback id-keyed mechanism (not a
-- flat presence-table) so any number of mods can each register their own
-- predicate independently. Called with the page/option being checked
-- (optionParameter in menu.submenuHandler/menu.checkInputSource/the title-
-- building code in menu.displayControls) - must return false for any other
-- page, and for our own page either true or (as here) a string, which
-- displayControls treats as a custom title override instead of its own
-- firstpart/secondpart construction (a non-empty string is still truthy
-- everywhere else this same callback is just used as a yes/no check).
function hotkeyApi.IsControlsPage(optionParameter)
  if optionParameter ~= CONTROLS_PAGE_ID then
    return false
  end
  return ReadText(PAGE_ID, 1100)
end

-- Callback for gameoptions.xpl's "remapInput_enrichConflicts" hook.
-- Appends conflict entries into the conflicts table using page-level area
-- filtering so only genuinely overlapping controls appear in the popup:
-- (a) Vanilla control being remapped to a key one of our slots uses: adds our
--     slot only when the current vanilla page is in the slot's affected pages.
-- (b) One of our controls being remapped to a key a vanilla action uses: adds
--     that action only when it belongs to a page in the slot's affected pages.
function hotkeyApi.EnrichRemapConflicts(conflicts, controltype, controlcode, newinputtype, newinputcode, newinputsgn, currentOption)
  if type(newinputtype) ~= "number" then return end
  local ok, actions = pcall(GetInputActionMap)
  if not ok or type(actions) ~= "table" then return end
  local cmpSgn = newinputsgn or 0
  local ourFunctionCode = (controltype == "functions")
      and (controlcode >= (FUNCTION_KEY_BASE + 23))
      and (controlcode <= (FUNCTION_KEY_BASE + 70))
  if ourFunctionCode then
    -- Case (b): our slot is being remapped - check vanilla actions on relevant pages
    local slot = POOL_NUMERIC_IDS_REVERSE[controlcode - FUNCTION_KEY_BASE]
    local slotPages = GetSlotAffectedPages(slot)
    for actionId, inputs in pairs(actions) do
      local inOurPool = (actionId >= 23) and (actionId <= 70)
      if not inOurPool and type(inputs) == "table" then
        local actionPages = actionIdToPages[actionId]
        if actionPages then
          local pageMatch = false
          for pageName in pairs(slotPages) do
            if actionPages[pageName] then pageMatch = true; break end
          end
          if pageMatch then
            for _, input in ipairs(inputs) do
              if input[1] == newinputtype and input[2] == newinputcode and (input[3] or 0) == cmpSgn then
                table.insert(conflicts, { control = { "actions", actionId }, mappable = true })
                break
              end
            end
          end
        end
      end
    end
  else
    -- Case (a): vanilla control being remapped - add our slots that overlap this page
    local vanillaPage = OPTION_TO_PAGE[currentOption]
    for _, slot in ipairs(POOL) do
      if usedSlots[slot] ~= nil then
        local slotPages = GetSlotAffectedPages(slot)
        if not vanillaPage or slotPages[vanillaPage] then
          local numericId = POOL_NUMERIC_IDS[slot]
          local inputs = actions[numericId]
          if type(inputs) == "table" then
            for _, input in ipairs(inputs) do
              if input[1] == newinputtype and input[2] == newinputcode and (input[3] or 0) == cmpSgn then
                table.insert(conflicts, { control = { "functions", FUNCTION_KEY_BASE + numericId }, mappable = true })
                break
              end
            end
          end
        end
      end
    end
  end
end

-- Callback for gameoptions.xpl's "remapInput_resolveConflicts" hook.
-- Clears the winning key from conflicting bindings using page-level filtering:
-- (a) Vanilla control being remapped to our key: directly removes the key from
--     each of our slots whose area overlaps the current vanilla page.
-- (b) Our control being remapped to a vanilla key: calls fixForPage for each
--     page in the slot's affected pages so only relevant vanilla controls are
--     cleared, not everything across all pages.
function hotkeyApi.ResolveConflicts(newinput, controltype, controlcode, currentOption, fixForPage)
  local ourFunctionCode = (controltype == "functions")
      and (controlcode >= (FUNCTION_KEY_BASE + 23))
      and (controlcode <= (FUNCTION_KEY_BASE + 70))
  if ourFunctionCode then
    -- Case (b): our slot being remapped - clear relevant vanilla pages only
    local slot = POOL_NUMERIC_IDS_REVERSE[controlcode - FUNCTION_KEY_BASE]
    for pageName in pairs(GetSlotAffectedPages(slot)) do
      fixForPage(pageName)
    end
  else
    -- Case (a): vanilla control being remapped - clear our slots that overlap
    local vanillaPage = OPTION_TO_PAGE[currentOption]
    local ok, actions = pcall(GetInputActionMap)
    if not ok or type(actions) ~= "table" then return end
    local nt, nc, ns = newinput[1], newinput[2], newinput[3] or 0
    for _, slot in ipairs(POOL) do
      if usedSlots[slot] ~= nil then
        local slotPages = GetSlotAffectedPages(slot)
        if not vanillaPage or slotPages[vanillaPage] then
          local inputs = actions[POOL_NUMERIC_IDS[slot]]
          if type(inputs) == "table" then
            for i = #inputs, 1, -1 do
              local inp = inputs[i]
              if inp[1] == nt and inp[2] == nc and ((inp[3] == 0) or (ns == 0) or (inp[3] == ns)) then
                table.remove(inputs, i)
              end
            end
          end
        end
      end
    end
  end
end

-- Injects a navigation row into the vanilla "main" page (the top-level
-- Options menu - Continue/Load/Save/.../Settings/Credits/...), right before
-- the "Settings" row itself, pointing at our own MANAGEMENT_PAGE_ID.
-- config.optionDefinitions["main"] is the same persistent table every
-- render - check before inserting so repeated views don't duplicate the row.
function hotkeyApi.OnDisplayOptions(options, config)
  if not (optionsMenu and (optionsMenu.currentOption == "main")) then
    return options
  end
  if type(options) ~= "table" then
    return options
  end

  -- Lazily create our own "Hotkey Management" page once - a plain nav page
  -- (Hotkey Bindings / Hotkey Requests / debug-logging toggle), entirely
  -- within the generic config.optionDefinitions/menu.displayOptions
  -- mechanism, no gameoptions.xpl patch needed for this page itself. The
  -- toggle is a "button" row (Enabled/Disabled text) rather than a real
  -- checkbox - menu.displayOption's generic renderer has no checkbox
  -- valuetype, only the custom-rendered pages (e.g. Hotkey Requests) can use
  -- actual createCheckBox widgets.
  if config and config.optionDefinitions and (not config.optionDefinitions[MANAGEMENT_PAGE_ID]) then
    config.optionDefinitions[MANAGEMENT_PAGE_ID] = {
      name = function() return ReadText(PAGE_ID, 1000) end,
      [1] = {
        id = "hotkey_api_bindings_nav",
        name = function() return ReadText(PAGE_ID, 1100) end,
        submenu = CONTROLS_PAGE_ID,
      },
      [2] = {
        id = "hotkey_api_requests_nav",
        name = function() return ReadText(PAGE_ID, 1200) end,
        submenu = REQUESTS_PAGE_ID,
      },
      [3] = {
        id = "hotkey_api_debug_toggle",
        name = function() return ReadText(PAGE_ID, 1900) end,
        value = function() return debugEnabled and ReadText(PAGE_ID, 1901) or ReadText(PAGE_ID, 1902) end,
        valuetype = "confirmation",
        callback = function() return hotkeyApi.OnToggleDebugEnabled(not debugEnabled) end,
      },
    }
    debugLog("OnDisplayOptions: created config.optionDefinitions['%s']", MANAGEMENT_PAGE_ID)
  end

  local insertAt = nil
  for i, row in ipairs(options) do
    if (type(row) == "table") and (row.id == "hotkey_api_management_nav") then
      -- Already inserted on a previous render.
      return options
    end
    if (type(row) == "table") and (row.id == "credits") and (not insertAt) then
      insertAt = i
    end
  end

  table.insert(options, insertAt or (#options + 1), {
    id = "hotkey_api_management_nav",
    name = function() return ReadText(PAGE_ID, 1000) end,
    submenu = MANAGEMENT_PAGE_ID,
  })
  debugLog("OnDisplayOptions: inserted hotkey_api_management_nav row at position %d", insertAt or (#options + 1))

  return options
end

-- Toggled from a checkbox row on the requests-management page. Unchecking
-- (checked=false) blocks the id immediately: persisted, and if it currently
-- holds a slot, that slot's record and physical key binding are both
-- cleared right away (matching ClearSlotBinding's "first claim" clearing
-- elsewhere). Checking only unblocks - it does not itself reclaim a slot;
-- that only happens via Refresh re-running the normal registration cycle,
-- so the new claim goes through FindFreeSlot like any other registration.
function hotkeyApi.OnToggleRequestEnabled(id, checked)
  if checked then
    blockedIds[id] = nil
    debugLog("OnToggleRequestEnabled: unblocked id '%s' (will attempt to claim a slot on next Refresh)", id)
  else
    blockedIds[id] = true
    local slot = FindSlotById(id)
    if slot then
      boundHotkeys[slot] = nil
      usedSlots[slot] = nil
      ClearSlotBinding(slot)
      debugLog("OnToggleRequestEnabled: blocked id '%s', freed slot %s", id, slot)
    else
      debugLog("OnToggleRequestEnabled: blocked id '%s' (was not currently bound)", id)
    end
  end
  hotkeyApi.ClearUnconfirmed()
  if optionsMenu and (optionsMenu.currentOption == REQUESTS_PAGE_ID) then
    optionsMenu.refresh()
  end
end

-- Toggled from its own checkbox row on the requests-management page (not
-- tied to any single request). Gates debugLog() here and, via the same
-- BLACKBOARD_DEBUG_ENABLED var, the debug_text calls in hotkey_api.xml/
-- hotkey_api_test.xml - logged unconditionally so there's always a record of
-- when logging was switched off.
function hotkeyApi.OnToggleDebugEnabled(checked)
  debugEnabled = checked
  __NATIVE_HOTKEY_API_DATA.debugEnabled = checked
  SaveDebugEnabled()
  DebugError("Hotkey API: debug logging " .. (checked and "enabled" or "disabled"))

  if optionsMenu and (optionsMenu.currentOption == REQUESTS_PAGE_ID) then
    optionsMenu.refresh()
  end
end

-- Shared by Init() (Lua's own reload) and the requests page's Refresh
-- button: clears allRequests (session-only by design, see its declaration)
-- and re-broadcasts Reloaded so every consumer re-sends Register_Action,
-- giving newly-unblocked ids a chance to claim a slot via the normal
-- registration path.
local function BroadcastReloaded()
  allRequestNames = {}
  allRequests = {}
  AddUITriggeredEvent("HotkeyApi", "reloaded")
  debugLog("BroadcastReloaded: cleared allRequests and raised HotkeyApi/reloaded")
end

-- Closes the page after refreshing - its row set is about to change, so
-- showing it again means reopening rather than looking at stale data.
function hotkeyApi.RequestsPageRefresh()
  debugLog("RequestsPageRefresh: re-broadcasting Reloaded and closing the page")
  BroadcastReloaded()
  if optionsMenu then
    optionsMenu.onCloseElement("back")
  end
end

-- Whole-page custom renderer for the requests-management page, registered
-- under gameoptions.xpl's "submenuHandler_customPage" hook (a generic,
-- multi-consumer-safe "render yourself, signal handled" callback list - same
-- pattern as the other hooks, but for full pages rather than option rows).
-- Needed instead of the generic config.optionDefinitions/menu.displayOptions
-- path because the row list isn't fixed-size: it's a paginated, scrollable
-- checkbox table, and a table can only have fixed (non-scrolling) rows
-- *before* non-fixed ones - the Prev/Next/Refresh buttons need to render
-- *after* the scrollable area, which requires a second, separate table
-- positioned below it via getVisibleHeight(), not just more option rows.
function hotkeyApi.DisplayRequestsManagement(optionParameter, config)
  debugLog("DisplayRequestsManagement: called with optionParameter='%s'", tostring(optionParameter))
  if optionParameter ~= REQUESTS_PAGE_ID then
    return false
  end

  Helper.clearDataForRefresh(optionsMenu, config.optionsLayer)
  optionsMenu.selectedOption = nil
  optionsMenu.currentOption = optionParameter
  debugLog("DisplayRequestsManagement: cleared old data, currentOption set")

  local frame = optionsMenu.createOptionsFrame()
  debugLog("DisplayRequestsManagement: frame created")

  local rowHeight = Helper.scaleY(config.standardTextHeight) + Helper.borderSize
  local footerHeight = rowHeight + Helper.borderSize
  -- Budget for the scrollable table (header row + checkbox rows); rowsPerPage
  -- is derived from this, not a fixed guess, so it adapts to resolution/UI
  -- scale like every other page in this menu.
  local contentBudget = optionsMenu.table.height - footerHeight
  local rowsPerPage = math.max(1, math.floor((contentBudget - rowHeight) / rowHeight))

  local totalPages = math.max(1, math.ceil(#allRequests / rowsPerPage))
  if requestsPage > totalPages then
    requestsPage = totalPages
  end
  local hasFreeSlot = HasFreeSlot()
  debugLog("DisplayRequestsManagement: %d request(s), %d row(s)/page, page %d/%d, hasFreeSlot=%s",
    #allRequests, rowsPerPage, requestsPage, totalPages, tostring(hasFreeSlot))

  local ftable = frame:addTable(4,
    { tabOrder = 1, x = optionsMenu.table.x, y = optionsMenu.table.y, width = optionsMenu.table.width, maxVisibleHeight = contentBudget })
  ftable:setColWidth(1, optionsMenu.table.arrowColumnWidth, false)
  ftable:setColWidth(2, 50)
  ftable:setColWidthPercent(4, 25)
  debugLog("DisplayRequestsManagement: ftable created")

  local headerRow = ftable:addRow(true, { fixed = true })
  headerRow[1]:setBackgroundColSpan(3)
  headerRow[1]:createButton({ height = config.headerTextHeight }):setIcon(config.backarrow, { x = config.backarrowOffsetX })
  headerRow[1].handlers.onClick = function() return optionsMenu.onCloseElement("back") end
  headerRow[2]:setColSpan(3):createText(ReadText(PAGE_ID, 1200), config.headerTextProperties)
  debugLog("DisplayRequestsManagement: header row built")

  -- Static column-title row, fixed (allowed to precede the scrollable
  -- checkbox rows, same as the back-arrow/title row above it).
  local columnHeaderRow = ftable:addRow(false, { fixed = true })
  columnHeaderRow[1]:setColSpan(2):createText(ReadText(PAGE_ID, 1210), config.subHeaderTextProperties)
  columnHeaderRow[3]:createText(ReadText(PAGE_ID, 1220), config.subHeaderTextProperties)
  columnHeaderRow[4]:createText(ReadText(PAGE_ID, 1230), config.subHeaderTextProperties)

  local startIdx = (requestsPage - 1) * rowsPerPage + 1
  local endIdx = math.min(startIdx + rowsPerPage - 1, #allRequests)
  for i = startIdx, endIdx do
    local id = allRequests[i]
    local name = allRequestNames[id] or id
    local status = GetRequestStatus(id)
    local checked = not blockedIds[id]
    local checkboxActive = checked or hasFreeSlot
    local statusText
    if status == "bound" then
      local assignedKeyText = GetAssignedKeyText(FindSlotById(id))
      if assignedKeyText then
        statusText = ReadText(PAGE_ID, 1234) .. ": " .. assignedKeyText
      else
        statusText = ReadText(PAGE_ID, 1231)
      end
    elseif status == "waiting" then
      statusText = ReadText(PAGE_ID, 1232)
    else
      statusText = ReadText(PAGE_ID, 1233)
    end

    local row = ftable:addRow(true, { fixed = false })
    row[1]:createCheckBox(function() return not blockedIds[id] end, { active = checkboxActive, height = config.standardTextHeight })
    row[1].handlers.onClick = function(_, isChecked) return hotkeyApi.OnToggleRequestEnabled(id, isChecked) end
    row[3]:createText(name, checkboxActive and config.standardTextProperties or config.disabledTextProperties)
    row[4]:createText(statusText, checkboxActive and config.standardTextProperties or config.disabledTextProperties)
  end
  debugLog("DisplayRequestsManagement: built rows %d..%d", startIdx, endIdx)

  local offsety = ftable.properties.y + ftable:getVisibleHeight() + Helper.borderSize
  local footertable = frame:addTable(4, { tabOrder = 2, x = optionsMenu.table.x, y = offsety, width = optionsMenu.table.width, skipTabChange = true })
  debugLog("DisplayRequestsManagement: footertable created at offsety=%s", tostring(offsety))
  local footerRow = footertable:addRow(true, { fixed = true })
  footerRow[1]:createButton({ active = requestsPage > 1 }):setText(ReadText(PAGE_ID, 1291), { halign = "center" })
  footerRow[1].handlers.onClick = function()
    if requestsPage > 1 then
      requestsPage = requestsPage - 1
      optionsMenu.refresh()
    end
  end
  footerRow[2]:createText(string.format("%d / %d", requestsPage, totalPages), { halign = "center" })
  footerRow[3]:createButton({ active = requestsPage < totalPages }):setText(ReadText(PAGE_ID, 1292), { halign = "center" })
  footerRow[3].handlers.onClick = function()
    if requestsPage < totalPages then
      requestsPage = requestsPage + 1
      optionsMenu.refresh()
    end
  end
  footerRow[4]:createButton({}):setText(ReadText(PAGE_ID, 1293), { halign = "center" })
  footerRow[4].handlers.onClick = function() return hotkeyApi.RequestsPageRefresh() end

  frame:display()

  debugLog("DisplayRequestsManagement: rendered page %d/%d (%d row(s)/page, %d total request(s))", requestsPage, totalPages, rowsPerPage, #allRequests)

  return true
end

function hotkeyApi.OnRegisterRequest()
  Helper.addDelayedOneTimeCallbackOnUpdate(
    function()
      debugLog("OnRegisterRequest: Registration is finished. Clearing unconfirmed (stale) used slots.")
      hotkeyApi.ClearUnconfirmed()
    end, false, getElapsedTime() + 3)
end

local function Init()
  playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  -- Loaded first so the persisted preference applies to every debugLog call
  -- below, including this function's own. Saved right back so the
  -- blackboard var MD's debug_text calls read is never left unset (which
  -- MD treats as falsy) while Lua's own default is true - keeps both sides
  -- in sync from the very first load, not just after the player toggles it.
  __NATIVE_HOTKEY_API_DATA.debugEnabled = __NATIVE_HOTKEY_API_DATA.debugEnabled or false
  debugEnabled = __NATIVE_HOTKEY_API_DATA.debugEnabled
  SaveDebugEnabled()
  debugLog("Initializing Native Hotkey API.")

  MigrateFromBlackboardIfNeeded()

  mapMenu = Helper.getMenu("MapMenu")
  debugLog("Init: MapMenu %s", mapMenu and "found" or "NOT found")
  optionsMenu = Helper.getMenu("OptionsMenu")
  debugLog("Init: OptionsMenu %s", optionsMenu and "found" or "NOT found")
  if optionsMenu and (type(optionsMenu.registerCallback) == "function") then
    optionsMenu.registerCallback("displayControls_modifyControlsOrder", hotkeyApi.OnDisplayControlsOrder)
    optionsMenu.registerCallback("displayOptions_modifyOptions", hotkeyApi.OnDisplayOptions)
    debugLog("Init: registered displayControls_modifyControlsOrder/displayOptions_modifyOptions callbacks")

    -- Declare our own page to menu.submenuHandler's/menu.checkInputSource's
    -- generic hook, so it routes through menu.displayControls (proper remap
    -- buttons) and accepts keyboard input while remapping, instead of falling
    -- through to the plain option-row renderer / rejecting all input.
    optionsMenu.registerCallback("submenuHandler_isControlsPage", hotkeyApi.IsControlsPage)
    debugLog("Init: declared '%s' as a controls page", CONTROLS_PAGE_ID)

    -- The requests-management page renders itself entirely (paginated
    -- scrollable table + a separate fixed footer table), so it goes through
    -- the whole-page "submenuHandler_customPage" hook rather than the
    -- per-row config.optionDefinitions/menu.displayOptions mechanism used by
    -- the "Hotkey Management" nav page itself.
    optionsMenu.registerCallback("submenuHandler_customPage", hotkeyApi.DisplayRequestsManagement)
    debugLog("Init: declared '%s' as a custom-rendered page", REQUESTS_PAGE_ID)

    -- Direct conflict enrichment: our callback appends entries into the
    -- vanilla conflicts table rather than triggering a separate cross-page
    -- scan. Covers both directions: vanilla control remapped to one of our
    -- keys (case a), and one of our controls remapped to a vanilla key (case b).
    optionsMenu.registerCallback("remapInput_enrichConflicts", hotkeyApi.EnrichRemapConflicts)
    debugLog("Init: registered remapInput_enrichConflicts callback")

    -- Conflict resolution: clears the winning binding's cross-page duplicates
    -- after the player confirms a remap. For our controls, triggers checkall to
    -- clear vanilla pages; vanilla-to-our-key direction is handled directly in
    -- gameoptions.xpl without needing a callback.
    optionsMenu.registerCallback("remapInput_resolveConflicts", hotkeyApi.ResolveConflicts)
    debugLog("Init: registered remapInput_resolveConflicts callback")
  end

  SetScript("onHotkey", hotkeyApi.onHotKey)
  debugLog("Init: SetScript(onHotkey, ...) registered")

  RegisterEvent("HotkeyApi.Register_Action", hotkeyApi.OnRegisterAction)
  debugLog("Init: RegisterEvent(HotkeyApi.Register_Action, ...) registered")

  -- One-time-only: the very first time this mod ever runs on this profile,
  -- sweep every pool slot not already claimed (per the userdata-persisted
  -- state just loaded above) and clear its key binding, so stale bindings
  -- predating this mod's ownership of these slots never linger. Gated by
  -- __NATIVE_HOTKEY_API_DATA (userdata storage, survives across new
  -- games/different saves) rather than running on every single load/start -
  -- after this first sweep, normal slot-claim/free bookkeeping (ProcessRegistration,
  -- ClearUnconfirmed, OnToggleRequestEnabled) already keeps unused slots clean.
  if not __NATIVE_HOTKEY_API_DATA.initiallyCleared then
    debugLog("Init: first run on this profile - running the one-time ClearAllUnboundSlots sweep")
    ClearAllUnboundSlots()
    __NATIVE_HOTKEY_API_DATA.initiallyCleared = true
  else
    debugLog("Init: one-time sweep already done on a previous run - skipping ClearAllUnboundSlots")
  end

  RegisterEvent("HotkeyApi.Register_Request", hotkeyApi.OnRegisterRequest)

  -- Notify MD that lua (re)loaded - consumers listen for md.HotkeyApi.Reloaded
  -- and (re-)send their registration in response.
  Helper.addDelayedOneTimeCallbackOnUpdate(
    function()
      BroadcastReloaded()
    end, false, getElapsedTime() + 3)
end

-- Replaces sn_mod_support_apis' Register_OnLoad_Init (dropping that
-- dependency entirely): md.HotkeyApi.GameLoaded only fires once an actual
-- game is loaded/started (event_game_loaded/event_game_started never fire
-- just sitting at the main menu), and md.HotkeyApi.LuaReadyRelay lets this
-- re-fire after a /reloadui mid-session (when those native events won't
-- recur, since the game itself didn't reload) - mirrors lua_loader.lua's
-- own Send_Priority_Ready/Send_Ready round trip, simplified to one stage
-- since nothing here needs the priority-ordering sn_mod_support_apis
-- supports for other mods' sake.
local initialized = false
local function OnGameLoaded()
  debugLog("OnGameLoaded: game loaded cue received, initialized=%s", tostring(initialized))
  if initialized then
    return
  end
  debugLog("OnGameLoaded: first load, calling Init()")
  initialized = true
  Init()
end

RegisterEvent("HotkeyApi.GameLoaded", OnGameLoaded)
-- Proactively ask md to relay back, in case its GameLoaded cue instance
-- already exists from an earlier game-load and just needs telling lua
-- itself just reloaded - a no-op if md isn't listening yet (i.e. still at
-- the main menu, no game loaded, same as lua_loader.lua's own comment on
-- this exact pattern).
AddUITriggeredEvent("HotkeyApi", "lua_ready")
