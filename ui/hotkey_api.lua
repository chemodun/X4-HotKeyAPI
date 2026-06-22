-- Hotkey API (POC)
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
]]

local PAGE_ID = 1972092431
local CONTROLS_PAGE_ID = "hotkey_api_controls"
local MANAGEMENT_PAGE_ID = "hotkey_api_management"
local REQUESTS_PAGE_ID = "hotkey_api_requests"

-- Must be declared before debugLog() below so debugLog can see it as an
-- upvalue - default true (matches the always-on behaviour this mod has had
-- so far) until LoadDebugEnabled() restores the player's actual choice.
local debugEnabled = true

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

local BLACKBOARD_BOUND = "$hotkey_api_bound"
local BLACKBOARD_SELECTED = "$hotkey_api_selected"
local BLACKBOARD_REQUESTS = "$hotkey_api_requests"
local BLACKBOARD_BLOCKED = "$hotkey_api_blocked"
-- Same name MD's debug_text calls check directly (player.entity.$hotkey_api_debug_enabled)
-- to gate their own output, so toggling this from the Requests page silences
-- both Lua's debugLog() and MD's debug_text in lockstep.
local BLACKBOARD_DEBUG_ENABLED = "$hotkey_api_debug_enabled"

local hotkeyApi = {}

local mapMenu = nil
local optionsMenu = nil
local playerId = nil

-- boundHotkeys: keyed by slot (a POOL action-id string) ->
-- {id, area, isObjectRequired, name, actionCue, actionLua}. This is the one
-- registry - mirrored verbatim to the player blackboard var so it survives
-- Lua's own reload (slot assignments are sticky; area/name/actionCue/
-- actionLua get refreshed by re-registration after every Reloaded).
local boundHotkeys = {}

-- blockedIds: keyed by request id -> true. Persisted (the player's decision
-- to block an id must survive reload/restart) - ids in here are skipped by
-- OnRegisterAction's slot-claiming, freeing/keeping their slot free for
-- other ids. Managed entirely from the "Hotkey Requests" management page.
local blockedIds = {}

-- allRequests: keyed by request id -> display name, for every id seen via
-- Register_Action this session, whether or not it currently holds a slot
-- (unlike boundHotkeys, which only knows about ids that got one). Session-
-- only by design - cleared and rebuilt from scratch every time the Reloaded
-- broadcast goes out, so a consumer that stops registering disappears from
-- the management page after the next refresh instead of lingering forever.
local allRequests = {}

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

local function SaveBoundHotkeys()
  SetNPCBlackboard(playerId, BLACKBOARD_BOUND, boundHotkeys)
end

local function LoadBoundHotkeys()
  local ok, stored = pcall(GetNPCBlackboard, playerId, BLACKBOARD_BOUND)
  if ok and (type(stored) == "table") then
    boundHotkeys = stored
    debugLog("LoadBoundHotkeys: restored %d bound slot(s) from blackboard", select("#", next(stored) and 1 or 0))
  end
end

local function SaveBlockedIds()
  SetNPCBlackboard(playerId, BLACKBOARD_BLOCKED, blockedIds)
end

local function LoadBlockedIds()
  local ok, stored = pcall(GetNPCBlackboard, playerId, BLACKBOARD_BLOCKED)
  if ok and (type(stored) == "table") then
    blockedIds = stored
    debugLog("LoadBlockedIds: restored blocked id list from blackboard")
  end
end

local function SaveDebugEnabled()
  SetNPCBlackboard(playerId, BLACKBOARD_DEBUG_ENABLED, debugEnabled)
end

local function LoadDebugEnabled()
  local ok, stored = pcall(GetNPCBlackboard, playerId, BLACKBOARD_DEBUG_ENABLED)
  if ok and (type(stored) == "boolean") then
    debugEnabled = stored
  end
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
  for slot, record in pairs(boundHotkeys) do
    if record.id == id then
      return slot
    end
  end
  return nil
end

local function FindFreeSlot()
  for _, slot in ipairs(POOL) do
    if not boundHotkeys[slot] then
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

-- All ids seen this session, alphabetically by display name - the order the
-- requests-management page lists them in.
local function GetSortedRequestIds()
  local ids = {}
  for id in pairs(allRequests) do
    table.insert(ids, id)
  end
  table.sort(ids, function(a, b)
    return (allRequests[a] or a) < (allRequests[b] or b)
  end)
  return ids
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
-- every slot NOT currently claimed in boundHotkeys. Run once at startup,
-- before notifying md, so unclaimed slots never carry a leftover binding
-- into a fresh session regardless of whether anything ever claims them.
local function ClearAllUnboundSlots()
	local clearedCount = 0
	for _, slot in ipairs(POOL) do
		if not boundHotkeys[slot] then
			clearedCount = clearedCount + 1
			ClearSlotBinding(slot)
		end
	end
	debugLog("ClearAllUnboundSlots: checked %d unbound slot(s) out of %d pool slot(s)", clearedCount, #POOL)
end

function hotkeyApi.OnRegisterAction(_, _)
  local request = GetNextRequest()
  debugLog("OnRegisterAction received, id: %s", (request and request.id) or "nil")
  if (type(request) ~= "table") or (type(request.id) ~= "string") then
    debugLog("Register_Action received an invalid request")
    return
  end

  -- Tracked for the requests-management page regardless of slot/block
  -- status - this is the only place that knows about every id a consumer
  -- ever tries to register, bound or not.
  allRequests[request.id] = request.name or request.id

  if blockedIds[request.id] then
    -- Deliberately disabled by the player. Defensively free+clear any slot
    -- it might still hold (shouldn't normally happen - blocking already does
    -- this - but guards against any path that skipped that step).
    local boundSlot = FindSlotById(request.id)
    if boundSlot then
      boundHotkeys[boundSlot] = nil
      SaveBoundHotkeys()
      ClearSlotBinding(boundSlot)
    end
    debugLog("OnRegisterAction: id '%s' is blocked - skipping slot claim", request.id)
    return
  end

  local slot = FindSlotById(request.id)
  if not slot then
    slot = FindFreeSlot()
    if not slot then
      debugLog("no free slot left for id '" .. request.id .. "' - pool exhausted")
      return
    end
    debugLog("OnRegisterAction: claimed new slot %s for id '%s'", slot, request.id)
    ClearSlotBinding(slot)
  else
    debugLog("OnRegisterAction: reusing existing slot %s for id '%s'", slot, request.id)
  end

  boundHotkeys[slot] = {
    id = request.id,
    area = request.area or "any",
    isObjectRequired = request.isObjectRequired or false,
    name = request.name or request.id,
    actionCue = request.actionCue,
    actionLua = request.actionLua,
  }
  SaveBoundHotkeys()

  if optionsMenu and ((optionsMenu.currentOption == CONTROLS_PAGE_ID) or (optionsMenu.currentOption == REQUESTS_PAGE_ID)) then
    optionsMenu.refresh()
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
  if currentMenu then
    if currentMenu.name == "MapMenu" then
      return "map"
    else
      return "other"
    end
  elseif IsActuallyPiloting() then
    return "pilot"
  else
    return "other"
  end
end

-- Returns the selected/targeted object component id for the given area, or
-- nil. Only "map"/"pilot" carry a notion of "selection" at all.
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
    action, tostring(record.id), tostring(record.area), tostring(record.isObjectRequired), tostring(currentArea))

  if record.area ~= "any" and record.area ~= currentArea then
    debugLog("onHotKey: area mismatch (record.area=%s, currentArea=%s) - skipping", tostring(record.area), tostring(currentArea))
    -- PlaySound("ui_target_set_fail")
    return
  end

  local selected = GetSelectedObjectForArea(currentArea)

  if record.isObjectRequired == 1 and not selected then
    debugLog("onHotKey: isObjectRequired but no selection/target for area '%s' - skipping", tostring(record.area))
    -- PlaySound("ui_target_set_fail")
    return
  elseif record.isObjectRequired == 1 and selected then
    debugLog("onHotKey: isObjectRequired and selected object/component %s for area '%s'", tostring(selected), tostring(record.area))
    SetNPCBlackboard(playerId, BLACKBOARD_SELECTED, ConvertStringToLuaID(tostring(selected)))
  else
    SetNPCBlackboard(playerId, BLACKBOARD_SELECTED, nil)
  end

  AddUITriggeredEvent("HotkeyApi", "execute_action", action)
  debugLog("onHotKey: dispatched execute_action for id '%s' (slot %s)", tostring(record.id), action)
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

-- Own submenu (not appended to "General Controls" anymore): routed through
-- menu.displayControls (proper remap/add/remove/reset buttons, same as
-- ADDON_DETAILMONITOR_I/etc.) via the new generic
-- menu.uix_callbacks["submenuHandler_isControlsPage"][optionParameter] hook
-- added to gameoptions.xpl's menu.submenuHandler. menu.controlsorder starts
-- empty for any optionParameter not one of the 3 vanilla keyboard pages, so
-- this hook is the only thing populating it - no stale-row removal needed
-- the way the old "appended to keyboard_space" version required.
function hotkeyApi.OnDisplayControlsOrder(optionParameter, controlsorder, config)
  if optionParameter ~= CONTROLS_PAGE_ID then
    return controlsorder
  end

  local groupRow = {
    id = "hotkey_api_group",
    title = ReadText(PAGE_ID, 14),
    mappable = true,
  }
  local rowCount = 0
  for _, slot in ipairs(POOL) do
    local record = boundHotkeys[slot]
    local numericId = POOL_NUMERIC_IDS[slot]
    if record and numericId and config and config.input and config.input.controlFunctions then
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
  return ReadText(PAGE_ID, 14)
end

local function IsOurFunctionCode(controltype, controlcode)
  return (controltype == "functions") and (controlcode >= (FUNCTION_KEY_BASE + 23)) and (controlcode <= (FUNCTION_KEY_BASE + 70))
end

-- Predicate callback for gameoptions.xpl's "remapInput_useCheckAll" hook
-- (menu.remapInput, right before menu.checkForConflicts is called). Default
-- vanilla behaviour only checks the current page's own controlsorder, so a
-- key bound here would never be flagged as conflicting with e.g. a "General
-- Controls" binding on a different page. Our pool is always-active
-- (INPUT_CONTEXT_ADDON_DEBUGLOG), so cross-page conflicts are real and worth
-- surfacing - hence asking for the full (checkall=true) scan whenever the
-- control being remapped is one of ours.
function hotkeyApi.UseCheckAllForRemap(controltype, controlcode)
  return IsOurFunctionCode(controltype, controlcode)
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
      name = function() return ReadText(PAGE_ID, 10) end,
      [1] = {
        id = "hotkey_api_bindings_nav",
        name = function() return ReadText(PAGE_ID, 14) end,
        submenu = CONTROLS_PAGE_ID,
      },
      [2] = {
        id = "hotkey_api_requests_nav",
        name = function() return ReadText(PAGE_ID, 15) end,
        submenu = REQUESTS_PAGE_ID,
      },
      [3] = {
        id = "hotkey_api_debug_toggle",
        name = function() return ReadText(PAGE_ID, 25) end,
        value = function() return debugEnabled and ReadText(PAGE_ID, 16) or ReadText(PAGE_ID, 26) end,
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
    name = function() return ReadText(PAGE_ID, 10) end,
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
      SaveBoundHotkeys()
      ClearSlotBinding(slot)
      debugLog("OnToggleRequestEnabled: blocked id '%s', freed slot %s", id, slot)
    else
      debugLog("OnToggleRequestEnabled: blocked id '%s' (was not currently bound)", id)
    end
  end
  SaveBlockedIds()

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

  local sortedIds = GetSortedRequestIds()
  local totalPages = math.max(1, math.ceil(#sortedIds / rowsPerPage))
  if requestsPage > totalPages then
    requestsPage = totalPages
  end
  local hasFreeSlot = HasFreeSlot()
  debugLog("DisplayRequestsManagement: %d request(s), %d row(s)/page, page %d/%d, hasFreeSlot=%s",
    #sortedIds, rowsPerPage, requestsPage, totalPages, tostring(hasFreeSlot))

  local ftable = frame:addTable(4, { tabOrder = 1, x = optionsMenu.table.x, y = optionsMenu.table.y, width = optionsMenu.table.width, maxVisibleHeight = contentBudget })
  ftable:setColWidth(1, optionsMenu.table.arrowColumnWidth, false)
  ftable:setColWidth(2, 50)
  ftable:setColWidthPercent(4, 25)
  debugLog("DisplayRequestsManagement: ftable created")

  local headerRow = ftable:addRow(true, { fixed = true })
  headerRow[1]:setBackgroundColSpan(3)
  headerRow[1]:createButton({ height = config.headerTextHeight }):setIcon(config.backarrow, { x = config.backarrowOffsetX })
  headerRow[1].handlers.onClick = function() return optionsMenu.onCloseElement("back") end
  headerRow[2]:setColSpan(3):createText(ReadText(PAGE_ID, 15), config.headerTextProperties)
  debugLog("DisplayRequestsManagement: header row built")

  -- Static column-title row, fixed (allowed to precede the scrollable
  -- checkbox rows, same as the back-arrow/title row above it).
  local columnHeaderRow = ftable:addRow(false, { fixed = true })
  columnHeaderRow[1]:setColSpan(2):createText(ReadText(PAGE_ID, 16), config.subHeaderTextProperties)
  columnHeaderRow[3]:createText(ReadText(PAGE_ID, 23), config.subHeaderTextProperties)
  columnHeaderRow[4]:createText(ReadText(PAGE_ID, 24), config.subHeaderTextProperties)

  local startIdx = (requestsPage - 1) * rowsPerPage + 1
  local endIdx = math.min(startIdx + rowsPerPage - 1, #sortedIds)
  for i = startIdx, endIdx do
    local id = sortedIds[i]
    local name = allRequests[id] or id
    local status = GetRequestStatus(id)
    local checked = not blockedIds[id]
    local checkboxActive = checked or hasFreeSlot
    local statusText = ReadText(PAGE_ID, (status == "bound") and 17 or (status == "waiting") and 18 or 19)

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
  footerRow[1]:createButton({ active = requestsPage > 1 }):setText(ReadText(PAGE_ID, 20), { halign = "center" })
  footerRow[1].handlers.onClick = function()
    if requestsPage > 1 then
      requestsPage = requestsPage - 1
      optionsMenu.refresh()
    end
  end
  footerRow[2]:createText(string.format("%d / %d", requestsPage, totalPages), { halign = "center" })
  footerRow[3]:createButton({ active = requestsPage < totalPages }):setText(ReadText(PAGE_ID, 21), { halign = "center" })
  footerRow[3].handlers.onClick = function()
    if requestsPage < totalPages then
      requestsPage = requestsPage + 1
      optionsMenu.refresh()
    end
  end
  footerRow[4]:createButton({}):setText(ReadText(PAGE_ID, 22), { halign = "center" })
  footerRow[4].handlers.onClick = function() return hotkeyApi.RequestsPageRefresh() end

  frame:display()

  debugLog("DisplayRequestsManagement: rendered page %d/%d (%d row(s)/page, %d total request(s))", requestsPage, totalPages, rowsPerPage, #sortedIds)

  return true
end

local function Init()
  playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  -- Loaded first so the persisted preference applies to every debugLog call
  -- below, including this function's own. Saved right back so the
  -- blackboard var MD's debug_text calls read is never left unset (which
  -- MD treats as falsy) while Lua's own default is true - keeps both sides
  -- in sync from the very first load, not just after the player toggles it.
  LoadDebugEnabled()
  SaveDebugEnabled()
  debugLog("Initializing Hotkey API.")

  LoadBoundHotkeys()
  LoadBlockedIds()

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

    -- Cross-page conflict checking for our always-active debug-pool keys -
    -- conservatively unconditional (same as "any" was) regardless of each
    -- hotkey's configured area: per-area filtering turned out unreliable
    -- (depends on per-row context numbers that were never confirmed, and
    -- testing showed it not behaving distinctly across areas), so better to
    -- over-warn than silently miss a real conflict.
    optionsMenu.registerCallback("remapInput_useCheckAll", hotkeyApi.UseCheckAllForRemap)
    debugLog("Init: registered remapInput_useCheckAll callback")
  end

  SetScript("onHotkey", hotkeyApi.onHotKey)
  debugLog("Init: SetScript(onHotkey, ...) registered")

  RegisterEvent("HotkeyApi.Register_Action", hotkeyApi.OnRegisterAction)
  debugLog("Init: RegisterEvent(HotkeyApi.Register_Action, ...) registered")

  -- Clean up before anyone re-registers: any pool slot not already claimed
  -- (per the blackboard state just loaded above) gets its key binding
  -- cleared, so stale bindings from a previous session/different mod
  -- combination never linger on a slot nothing currently uses.
  ClearAllUnboundSlots()

  -- Notify MD that lua (re)loaded - consumers listen for md.HotkeyApi.Reloaded
  -- and (re-)send their registration in response.
  BroadcastReloaded()
end

Register_OnLoad_Init(Init)
