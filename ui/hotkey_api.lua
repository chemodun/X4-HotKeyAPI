-- Hotkey API (POC)
-- Defines INPUT_ACTION_HOTKEY_API_TEST (map-only, no default key), lets the
-- player bind a key to it via a new Settings page entry, and reacts to the
-- action through the new "hotkey_action_selected" UIX callback added to the
-- Map menu's menu.hotkey() dispatch.

local PAGE_ID = 1972092431
local ACTION_ID = "INPUT_ACTION_DEBUG_F12"
-- Numeric id for ACTION_ID, discovered empirically in-game 2026-06-21 via
-- DumpActionsBoundToKeycode() (capture F12 through the bind button) - it is
-- NOT derivable from any string id, schema, or declaration order (verified
-- against config.input.controlFunctions: sibling actions added together show
-- inconsistent offsets, e.g. +35 then +1 - no reliable pattern to exploit).
-- This is the key that actually indexes GetInputActionMap()/SaveInputSettings;
-- ACTION_ID (the string) is only ever used for the onHotkey/menu.hotkey side.
local ACTION_NUMERIC_ID = 70

local hotkeyApi = {}

-- ##########################################################################
-- Map menu: react to the action (mirrors INPUT_ACTION_ADDON_DETAILMONITOR_I)
-- ##########################################################################

local mapMenu = nil

function hotkeyApi.OnHotkeySelected(action, selectedcomponent, _rowdata)
  if action ~= ACTION_ID then
    return
  end
  if (not mapMenu.mode) and IsInfoUnlockedForPlayer(selectedcomponent, "name") and CanViewLiveData(selectedcomponent) then
    mapMenu.openDetails(selectedcomponent)
  else
    PlaySound("ui_target_set_fail")
  end
end

-- ##########################################################################
-- Options menu: let the player bind a key to the action
-- ##########################################################################

local optionsMenu = nil
local capturing = false

local function GetBoundKeyText()
  local ok, actions = pcall(GetInputActionMap)
  if not ok or type(actions) ~= "table" or type(actions[ACTION_NUMERIC_ID]) ~= "table" then
    return ReadText(PAGE_ID, 13)
  end
  local inputs = actions[ACTION_NUMERIC_ID]
  if not inputs[1] then
    return ReadText(PAGE_ID, 13)
  end
  return "source=" .. tostring(inputs[1][1]) .. " code=" .. tostring(inputs[1][2])
end

local function ButtonLabel()
  if capturing then
    return ReadText(PAGE_ID, 12)
  end
  return ReadText(PAGE_ID, 11) .. ": " .. GetBoundKeyText()
end

-- config is only reachable as the 2nd arg of OnDisplayOptions (it's a local
-- in gameoptions.xpl, not a global) - cache it the first time we see it.
local cachedConfig = nil

-- Returns true if numeric action id `id` already appears in any of the 3
-- vanilla keyboard pages (config.input.controlsorder.space/menus/firstperson) -
-- either directly as a {"actions", id} row, or indirectly nested inside a
-- {"functions", N} row's config.input.controlFunctions[N].actions list (e.g.
-- INPUT_ACTION_ADDON_DETAILMONITOR_I is one of controlFunctions[5].actions =
-- {128, 163}, never a direct controlsorder row of its own).
local function IsKnownVanillaActionId(id)
  if not cachedConfig then
    return false
  end
  for _, pageKey in ipairs({ "space", "menus", "firstperson" }) do
    local page = cachedConfig.input.controlsorder[pageKey]
    if type(page) == "table" then
      for _, controlsgroup in ipairs(page) do
        for _, control in ipairs(controlsgroup) do
          if (control[1] == "actions") and (control[2] == id) then
            return true
          elseif (control[1] == "functions") then
            local fn = cachedConfig.input.controlFunctions[control[2]]
            if type(fn) == "table" and type(fn.actions) == "table" then
              for _, nestedId in ipairs(fn.actions) do
                if nestedId == id then
                  return true
                end
              end
            end
          end
        end
      end
    end
  end
  return false
end

-- Discovery helper: GetInputActionMap() is keyed by an internal NUMERIC id,
-- not the string action id (confirmed: menu.getControlName/menu.displayControlRow
-- index it with the same small integers used in config.input.controlsorder).
-- There is no known string->numeric lookup, so to find ACTION_ID's numeric id
-- we scan every entry for one whose bound key matches a keycode we just
-- captured via the same physical key, then filter out any candidate that is
-- already a known vanilla action (defensive - DEBUG_F12's default key, F12,
-- is not shared with any other vanilla action, unlike "1"/weapon-group-1).
local function DumpActionsBoundToKeycode(keycode)
  local ok, actions = pcall(GetInputActionMap)
  if not ok or type(actions) ~= "table" then
    DebugError("hotkey_api: GetInputActionMap() failed or returned non-table")
    return
  end
  for id, entry in pairs(actions) do
    if type(entry) == "table" then
      for _, tuple in ipairs(entry) do
        if type(tuple) == "table" and (tuple[2] == keycode) then
          local known = IsKnownVanillaActionId(id)
          DebugError("hotkey_api: numeric action id " .. tostring(id) .. " is bound to keycode " .. tostring(keycode)
            .. " tuple=(" .. tostring(tuple[1]) .. "," .. tostring(tuple[2]) .. "," .. tostring(tuple[3]) .. ")"
            .. (known and " [known vanilla action - NOT debug_1]" or " [NOT in controlsorder - likely DEBUG_1]"))
        end
      end
    end
  end
end

local function OnKeyCaptured(_, keycode)
  UnregisterEvent("keyboardInput", OnKeyCaptured)
  ListenForInput(false)
  capturing = false

  DebugError("hotkey_api: captured keycode " .. tostring(keycode) .. " for " .. ACTION_ID)
  DumpActionsBoundToKeycode(keycode)

  local ok, actions = pcall(GetInputActionMap)
  if ok and type(actions) == "table" then
    -- source 1 = keyboard, sign 0 = plain press; tuple shape mirrors
    -- {type, code, sign, toggle} seen in gameoptions.xpl's menu.controls.
    -- Must be keyed by the NUMERIC id - GetInputActionMap()/SaveInputSettings
    -- do not recognise the string action id at all.
    actions[ACTION_NUMERIC_ID] = { { 1, keycode, 0, false } }
    local saveOk, saveErr = pcall(SaveInputSettings, actions, GetInputStateMap(), GetInputRangeMap())
    if not saveOk then
      DebugError("hotkey_api: SaveInputSettings failed: " .. tostring(saveErr))
    end
  end

  if optionsMenu and (optionsMenu.currentOption == "hotkey_api_test") then
    optionsMenu.refresh()
  end
end

function hotkeyApi.StartCapture()
  if capturing then
    return
  end
  capturing = true
  RegisterEvent("keyboardInput", OnKeyCaptured)
  ListenForInput(true)
end

function hotkeyApi.OnDisplayOptions(options, config)
  DebugError("hotkey_api: OnDisplayOptions called with options = " .. tostring(options) .. ", config = " .. tostring(config))
  cachedConfig = config
  config.optionDefinitions["hotkey_api_test"] = config.optionDefinitions["hotkey_api_test"] or {
    name = function() return ReadText(PAGE_ID, 10) end,
    [1] = {
      id = "hotkey_api_bind",
      name = ButtonLabel,
      callback = hotkeyApi.StartCapture,
    },
  }

  if (type(options) == "table") and optionsMenu and (optionsMenu.currentOption == "settings") then
    DebugError("hotkey_api: Modifying options menu for settings")
    local exists = false
    for _, row in ipairs(options) do
      if (type(row) == "table") and (row.id == "hotkey_api_test_entry") then
        exists = true
        break
      end
    end
    if not exists then
      DebugError("hotkey_api: Inserting hotkey_api_test_entry into options menu")
      table.insert(options, {
        id = "hotkey_api_test_entry",
        name = function() return ReadText(PAGE_ID, 10) end,
        submenu = "hotkey_api_test",
      })
    end
  end

  return options
end

-- ADDON_DETAILMONITOR_I/etc. live in controlsorder.space ("Menu Access" group),
-- so our row goes there too, as our own new group (not editing Ego's group).
-- Once inserted, the existing remap/add/remove/reset button machinery in
-- menu.displayControlRow/menu.buttonControl/menu.remapInputInternal handles
-- everything generically by controltype+code - no further hook needed there.
function hotkeyApi.OnDisplayControlsOrder(optionParameter, controlsorder, config)
  cachedConfig = config
  if optionParameter ~= "keyboard_space" then
    return controlsorder
  end
  for _, group in ipairs(controlsorder) do
    if group.id == "hotkey_api_group" then
      return controlsorder
    end
  end
  table.insert(controlsorder, {
    id = "hotkey_api_group",
    title = ReadText(PAGE_ID, 10),
    mappable = true,
    { "actions", ACTION_NUMERIC_ID },
  })
  return controlsorder
end

local function hotkey(action)
  local currentMenu = nil
  for _, menu in ipairs(Menus) do
    if menu.shown then
      currentMenu = menu
      break
    end
  end
  DebugError("hotkey_api: hotkey() = " .. tostring(action) .. ", currentMenu = " .. tostring(currentMenu and currentMenu.name or ""))
end

local function onUpdate()
  -- DebugError("hotkey_api: onUpdate()")
  -- RegisterAddonBindings("ego_detailmonitor", "map")
end
-- ##########################################################################
-- Init
-- ##########################################################################

local function Init()
  mapMenu = Helper.getMenu("MapMenu")
  if (mapMenu == nil) or (type(mapMenu.registerCallback) ~= "function") then
    DebugError("hotkey_api: MapMenu not found - kuertee UI Extensions missing?")
    return
  end
  mapMenu.registerCallback("hotkey_action_selected", hotkeyApi.OnHotkeySelected)
  DebugError("hotkey_api: MapMenu callback registered")
  optionsMenu = Helper.getMenu("OptionsMenu")
  if (optionsMenu == nil) or (type(optionsMenu.registerCallback) ~= "function") then
    DebugError("hotkey_api: OptionsMenu not found - kuertee UI Extensions missing?")
    return
  end
  optionsMenu.registerCallback("displayOptions_modifyOptions", hotkeyApi.OnDisplayOptions)
  optionsMenu.registerCallback("displayControls_modifyControlsOrder", hotkeyApi.OnDisplayControlsOrder)
  DebugError("hotkey_api: OptionsMenu callback registered")
  SetScript("onHotkey", hotkey)
  SetScript("onUpdate", onUpdate)
  -- RegisterAddonBindings("ego_detailmonitor", "extra")
end

Register_OnLoad_Init(Init)

-- Init()
