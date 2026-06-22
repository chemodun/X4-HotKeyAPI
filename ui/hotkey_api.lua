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
]]

local PAGE_ID = 1972092431
local CONTROLS_PAGE_ID = "hotkey_api_controls"

local function debugLog(fmt, ...)
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

  if optionsMenu and (optionsMenu.currentOption == CONTROLS_PAGE_ID) then
    optionsMenu.refresh()
  end
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
  else
    return "space"
  end
end

-- Returns the selected/targeted object component id for the given area, or
-- nil. Only "map"/"space" carry a notion of "selection" at all.
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
  elseif area == "space" then
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
    title = ReadText(PAGE_ID, 10),
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
-- (optionParameter in menu.submenuHandler, menu.currentOption in
-- menu.checkInputSource) and must return true only for our own page.
function hotkeyApi.IsControlsPage(optionParameter)
  return optionParameter == CONTROLS_PAGE_ID
end

-- Injects a navigation row into the vanilla "input" page (Options > Settings
-- > Controls), right after "Menu Navigation" (id "keyboard_menus"), pointing
-- at our own CONTROLS_PAGE_ID. config.optionDefinitions["input"] is the same
-- persistent table every render - check before inserting so repeated views
-- don't duplicate the row.
function hotkeyApi.OnDisplayOptions(options, _config)
  if not (optionsMenu and (optionsMenu.currentOption == "input")) then
    return options
  end
  if type(options) ~= "table" then
    return options
  end

  local insertAt = nil
  for i, row in ipairs(options) do
    if (type(row) == "table") and (row.id == "hotkey_api_nav") then
      -- Already inserted on a previous render.
      return options
    end
    if (type(row) == "table") and (row.id == "keyboard_menus") then
      insertAt = i + 1
    end
  end

  table.insert(options, insertAt or (#options + 1), {
    id = "hotkey_api_nav",
    name = function() return ReadText(PAGE_ID, 10) end,
    submenu = CONTROLS_PAGE_ID,
  })
  debugLog("OnDisplayOptions: inserted hotkey_api_nav row at position %d", insertAt or (#options + 1))

  return options
end

local function Init()
  debugLog("Initializing Hotkey API.")
  playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))

  LoadBoundHotkeys()

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
  AddUITriggeredEvent("HotkeyApi", "reloaded")
  debugLog("Init: raised HotkeyApi/reloaded")
end

Register_OnLoad_Init(Init)
