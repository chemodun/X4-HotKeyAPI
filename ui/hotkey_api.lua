-- Hotkey API (POC)
-- MD forwards consumer registration requests (id/area/isTargetRequired/name/
-- actionCue/actionLua) via raise_lua_event; this file owns the single
-- bound-hotkeys registry (persisted to a player blackboard var so slot
-- assignments survive Lua's own reload, since Lua state itself does not),
-- dispatches via a direct SetScript("onHotkey", ...) registration (the pool
-- lives in the always-active INPUT_CONTEXT_ADDON_DEBUGLOG context), and
-- feeds the General Controls page via OnDisplayControlsOrder.

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
	typedef uint64_t UniverseID;
	UniverseID GetPlayerID(void);
]]

local PAGE_ID = 1972092431

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

local hotkeyApi = {}

local mapMenu = nil
local optionsMenu = nil
local playerId = nil

-- boundHotkeys: keyed by slot (a POOL action-id string) ->
-- {id, area, isTargetRequired, name, actionCue, actionLua}. This is the one
-- registry - mirrored verbatim to the player blackboard var so it survives
-- Lua's own reload (slot assignments are sticky; area/name/actionCue/
-- actionLua get refreshed by re-registration after every Reloaded).
local boundHotkeys = {}

local function SaveBoundHotkeys()
	SetNPCBlackboard(playerId, BLACKBOARD_BOUND, boundHotkeys)
end

local function LoadBoundHotkeys()
	local ok, stored = pcall(GetNPCBlackboard, playerId, BLACKBOARD_BOUND)
	if ok and (type(stored) == "table") then
		boundHotkeys = stored
	end
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

function hotkeyApi.OnRegisterAction(_, request)
	if (type(request) ~= "table") or (type(request.id) ~= "string") then
		DebugError("hotkey_api: Register_Action received an invalid request")
		return
	end

	local slot = FindSlotById(request.id)
	if not slot then
		slot = FindFreeSlot()
		if not slot then
			DebugError("hotkey_api: no free slot left for id '" .. request.id .. "' - pool exhausted")
			return
		end
	end

	boundHotkeys[slot] = {
		id = request.id,
		area = request.area or "any",
		isTargetRequired = request.isTargetRequired or false,
		name = request.name or request.id,
		actionCue = request.actionCue,
		actionLua = request.actionLua,
	}
	SaveBoundHotkeys()

	if optionsMenu and (optionsMenu.currentOption == "keyboard_space") then
		optionsMenu.refresh()
	end
end

-- Returns the selected/targeted object component id for the given area, or
-- nil. Only "map"/"space" carry a notion of "selection" at all.
local function GetSelectedObjectForArea(area)
	if area == "map" then
		if not (mapMenu and next(mapMenu.selectedcomponents or {})) then
			return nil
		end
		for id, _ in pairs(mapMenu.selectedcomponents) do
			local component = ConvertStringTo64Bit(id)
			if IsValidComponent(component) then
				return component
			end
		end
		return nil
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
	local record = boundHotkeys[action]
	if not record then
		return
	end

	local selected = GetSelectedObjectForArea(record.area)

	if record.isTargetRequired and not selected then
		PlaySound("ui_target_set_fail")
		return
	end

	SetNPCBlackboard(playerId, BLACKBOARD_SELECTED, selected)
	AddUITriggeredEvent("HotkeyApi", "execute_action", action)
end

-- ADDON_DETAILMONITOR_I/etc. live in controlsorder.space ("Menu Access"
-- group), so our rows go there too, as our own group. Once inserted, the
-- existing remap/add/remove/reset button machinery in
-- menu.displayControlRow/menu.buttonControl/menu.remapInputInternal handles
-- everything generically by controltype+code - no further hook needed there.
function hotkeyApi.OnDisplayControlsOrder(optionParameter, controlsorder, _config)
	if optionParameter ~= "keyboard_space" then
		return controlsorder
	end

	-- controlsorder is the same persistent config.input.controlsorder.space
	-- table every time this page renders (not a fresh copy) - remove any
	-- stale group from a previous render before inserting a current one, so
	-- repeated page views neither duplicate nor go stale.
	for i = #controlsorder, 1, -1 do
		if controlsorder[i].id == "hotkey_api_group" then
			table.remove(controlsorder, i)
		end
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
		if record and numericId then
			rowCount = rowCount + 1
			groupRow[rowCount] = { "actions", numericId, nil, record.name }
		end
	end

	if rowCount > 0 then
		table.insert(controlsorder, groupRow)
	end

	return controlsorder
end

local function Init()
	playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))

	LoadBoundHotkeys()

	mapMenu = Helper.getMenu("MapMenu")
	optionsMenu = Helper.getMenu("OptionsMenu")
	if optionsMenu and (type(optionsMenu.registerCallback) == "function") then
		optionsMenu.registerCallback("displayControls_modifyControlsOrder", hotkeyApi.OnDisplayControlsOrder)
	end

	SetScript("onHotkey", hotkeyApi.onHotKey)

	RegisterEvent("HotkeyApi.Register_Action", hotkeyApi.OnRegisterAction)

	-- Notify MD that lua (re)loaded - consumers listen for md.HotkeyApi.Reloaded
	-- and (re-)send their registration in response.
	AddUITriggeredEvent("HotkeyApi", "reloaded")
end

Register_OnLoad_Init(Init)
