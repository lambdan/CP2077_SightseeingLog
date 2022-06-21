local HiddenPackagesMetadata = {
	title = "Sightseeing Log",
	version = "0.1",
	date = "2022-06-21"
}

local GameSession = require("Modules/GameSession.lua")
local GameHUD = require("Modules/GameHUD.lua")
local GameUI = require("Modules/GameUI.lua")
local LEX = require("Modules/LuaEX.lua")

local MAPS_FOLDER = "Maps/" -- should end with a /
local MAP_DEFAULT = "Maps/A Realm Reborn.json" -- full path to default map

local SETTINGS_FILE = "settings-1.0.json"
local MOD_SETTINGS = { -- saved in SETTINGS_FILE (separate from game save)
	MapPath = MAP_DEFAULT,
	Range = 0.3
}

local SESSION_DATA = { -- will persist with game saves
	collectedPackageIDs = {}
}

local LOADED_MAP = nil

local HUDMessage_Current = ""
local HUDMessage_Last = 0

-- inits
local isInGame = false
local isPaused = true
local modActive = true
local NEED_TO_REFRESH = false

local AT_LOCATION = false
local SCANNER_OPEN = nil

registerHotkey("sslog_whereami", "Where Am I?", function()
	local pos = Game.GetPlayer():GetWorldPosition()
	showCustomShardPopup("Where Am I?", "You are standing here:\nX:  " .. string.format("%.3f",pos["x"]) .. "\nY:  " .. string.format("%.3f",pos["y"]) .. "\nZ:  " .. string.format("%.3f",pos["z"]) .. "\nW:  " .. pos["w"])
end)

registerHotkey("sslog_saveloc", "Save location to json", function()
	local pos = Game.GetPlayer():GetWorldPosition()
	local filename = "location_" .. tostring(os.date("%Y-%m-%d_%H.%M.%S")) .. ".json"
	dumpLocation(pos.x, pos.y, pos.z, pos.w, "name", "desc", "identifier", filename)
	HUDMessage("Saved location to " .. filename)
end)

registerForEvent('onShutdown', function() -- mod reload, game shutdown etc
    GameSession.TrySave()
    reset()
end)

registerForEvent('onInit', function()
	loadSettings()

	LOADED_MAP = readMap(MOD_SETTINGS.MapPath)

	-- scan Maps folder and generate table suitable for nativeSettings
	local mapsPaths = {[1] = false}
	local nsMapsDisplayNames = {[1] = "None"}
	local nsDefaultMap = 1
	local nsCurrentMap = 1
	for k,v in pairs( listFilesInFolder(MAPS_FOLDER, ".json") ) do
		local map_path = MAPS_FOLDER .. v
		local read_map = readMap(map_path)

		if read_map ~= nil then
			local i = LEX.tableLen(mapsPaths) + 1
			nsMapsDisplayNames[i] = read_map.title
			mapsPaths[i] = map_path
			if map_path == MAP_DEFAULT then
				nsDefaultMap = i
			end
			if map_path == MOD_SETTINGS.MapPath then
				nsCurrentMap = i
			end
		end
	end

	-- generate NativeSettings (if available)
	nativeSettings = GetMod("nativeSettings")
	if nativeSettings ~= nil then

		nativeSettings.addTab("/SightseeingLog", "Sightseeing Log")

		-- maps

		nativeSettings.addSubcategory("/SightseeingLog/Settings", "Settings")

		nativeSettings.addSelectorString("/SightseeingLog/Settings", "Map", "Maps are stored in \'.../mods/SightseeingLog/Maps\''. If set to None the mod is disabled.", nsMapsDisplayNames, nsCurrentMap, nsDefaultMap, function(value)
			MOD_SETTINGS.MapPath = mapsPaths[value]
			saveSettings()
			NEED_TO_REFRESH = true
		end)

		-- Parameters: path, label, desc, min, max, step, format, currentValue, defaultValue, callback, optionalIndex
		nativeSettings.addRangeFloat("/SightseeingLog/Settings", "Range", "Increase this to make it easier to be in the right spot. In FFXIV it's usually very tight.", 0.1, 10, 0.1, "%.2f", MOD_SETTINGS.Range, 0.3, function(value)
			MOD_SETTINGS.Range = value
			saveSettings()
		end)

		nativeSettings.addRangeFloat("/SightseeingLog/Settings", "Reset progress", "Touch me to reset progress", 1, 10, 1, "%.2f", 1, 1, function(value)
			SESSION_DATA = {
				collectedPackageIDs = {}
			}
		end)

		nativeSettings.addSubcategory("/SightseeingLog/Version", HiddenPackagesMetadata.title .. " version " .. HiddenPackagesMetadata.version .. " (" .. HiddenPackagesMetadata.date .. ")")

	end
	-- end NativeSettings

	GameSession.StoreInDir('Sessions')
	GameSession.Persist(SESSION_DATA)
	isInGame = Game.GetPlayer() and Game.GetPlayer():IsAttached() and not Game.GetSystemRequestsHandler():IsPreGame()

    GameSession.OnStart(function()
        isInGame = true
        isPaused = false
        
        if NEED_TO_REFRESH then
        	changeMap(MOD_SETTINGS.MapPath)
        	NEED_TO_REFRESH = false
        end
    end)

    GameSession.OnEnd(function()
        isInGame = false
        reset()
    end)

	GameSession.OnPause(function()
		isPaused = true
	end)

	GameSession.OnResume(function()
		isPaused = false

        if NEED_TO_REFRESH then
        	changeMap(MOD_SETTINGS.MapPath)
        	NEED_TO_REFRESH = false
        end

	end)

	Observe('PlayerPuppet', 'OnAction', function(action)
		checkIfPlayerNearAnyPackage()
	end)

	GameUI.Listen('ScannerOpen', function()
		SCANNER_OPEN = true
	end)

	GameUI.Listen('ScannerClose', function()
		SCANNER_OPEN = false
	end)

	GameSession.TryLoad()
	NEED_TO_REFRESH = true

end)


function collectHP(packageIndex)
	local pkg = LOADED_MAP.packages[packageIndex]

	if not LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg["identifier"]) then
		table.insert(SESSION_DATA.collectedPackageIDs, pkg["identifier"])
	end
	
	unmarkPackage(packageIndex)
	despawnPackage(packageIndex)

	local collected = countCollected(LOADED_MAP.filepath)
	nativeSettings.refresh()
	
    if collected == LOADED_MAP.amount then
    	-- got all packages
    	Game.GetAudioSystem():Play('ui_jingle_quest_success')
    	HUDMessage("ALL HIDDEN PACKAGES COLLECTED!")
    	--showCustomShardPopup("All Hidden Packages collected!", "You have collected all " .. tostring(LOADED_MAP["amount"]) .. " packages from the map \"" .. LOADED_MAP["display_name"] .. "\"!")
    else
    	-- regular package pickup
    	Game.GetAudioSystem():Play('ui_loot_rarity_legendary')
    	local msg = "Hidden Package " .. tostring(collected) .. " of " .. tostring(LOADED_MAP.amount)
    	HUDMessage(msg)
    end	

	local multiplier = 1
	if MOD_SETTINGS.PackageMultiplier > 0 then
		multiplier = MOD_SETTINGS.PackageMultiplier * collected
	end

	local money_reward = MOD_SETTINGS.MoneyPerPackage * multiplier
	if money_reward	> 0 then
		Game.AddToInventory("Items.money", money_reward)
	end

	local sc_reward = MOD_SETTINGS.StreetcredPerPackage * multiplier
	if sc_reward > 0 then
		Game.AddExp("StreetCred", sc_reward)
	end

	local xp_reward = MOD_SETTINGS.ExpPerPackage * multiplier
	if xp_reward > 0 then
		Game.AddExp("Level", xp_reward)
	end

	if MOD_SETTINGS.RandomRewardItemList then -- will be false if Disabled
		math.randomseed(os.time())
		local randomLine = RANDOM_ITEMS_POOL[math.random(1,#RANDOM_ITEMS_POOL)]
		local item = randomLine
		local amount = 1
		
		if string.find(randomLine, ",") then -- custom amount of item specified in ItemList
			item, amount = randomLine:match("([^,]+),([^,]+)") -- split line at the ","-- https://stackoverflow.com/a/19269176
			amount = tonumber(amount)
		end

		Game.AddToInventory(item, amount)
		if amount > 1 then
			HUDMessage("Got Item: " .. item .. " (" .. tostring(amount) .. ")")
		else
			HUDMessage("Got Item: " .. item)
		end
	end

end

function reset()
	activePackages = {}
	nextCheck = 0
	return true
end

function inVehicle() -- from AdaptiveGraphicsQuality (https://www.nexusmods.com/cyberpunk2077/mods/2920)
	local ws = Game.GetWorkspotSystem()
	local player = Game.GetPlayer()
	if ws and player then
		local info = ws:GetExtendedInfo(player)
		if info then
			return ws:IsActorInWorkspot(player)
				and not not Game['GetMountedVehicle;GameObject'](Game.GetPlayer())
		end
	end
end


function changeMap(path)
	if path == false then -- false == mod disabled
		reset()
		LOADED_MAP = nil
		return true
	end

	if LEX.fileExists(path) then
		reset()
		LOADED_MAP = readMap(path)
		checkIfPlayerNearAnyPackage()
		return true
	end

	return false
end

function checkIfPlayerNearAnyPackage()
	if (LOADED_MAP == nil) or (isPaused == true) or (isInGame == false) or (os.clock() < nextCheck) or (inVehicle()) then
		-- no map is loaded/game is paused/game has not loaded/not time to check yet: return and do nothing
		return
	end

	local nextDelay = 1.0 -- default check interval
	local playerPos = Game.GetPlayer():GetWorldPosition() -- get player coordinates

	for index,pkg in pairs(LOADED_MAP.packages) do -- iterate over packages in loaded map
		if not (LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg.identifier)) and (math.abs(playerPos.x - pkg.x) <= 10) and (math.abs(playerPos.y - pkg.y) <= 10) then
			local d = Vector4.Distance(playerPos, ToVector4{x=pkg.x, y=pkg.y, z=pkg.z, w=pkg.w})
			nextDelay = 0.1

			if d <= MOD_SETTINGS.Range then
				if (not LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg.identifier)) and (not AT_LOCATION) then
					HUDMessage("You have arrived at a vista")
					AT_LOCATION = true
				end
				if (SCANNER_OPEN) and (AT_LOCATION) then -- "collected"
					Game.GetAudioSystem():Play("ui_elevator_select")
					table.insert(SESSION_DATA.collectedPackageIDs, pkg.identifier)
					AT_LOCATION = false
					showCustomShardPopup("Sightseeing Log", pkg.name .. "\n\n" .. pkg.description)
				end
			elseif (AT_LOCATION) and (not LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg.identifier)) then
				HUDMessage("You strayed too far away from the vista")
				AT_LOCATION = false
			end
		end
	end

	nextCheck = os.clock() + nextDelay
end

function HUDMessage(msg)
	--[[ if os:clock() - HUDMessage_Last <= 1 then
		HUDMessage_Current = msg .. "\n" .. HUDMessage_Current
	else
		HUDMessage_Current = msg
	end

	GameHUD.ShowMessage(HUDMessage_Current)
	HUDMessage_Last = os:clock() ]]
	GameHUD.ShowMessage(msg)
end

function countCollected(MapPath)
	-- cant just check length of collectedPackageIDs as it may include packages from other location files
	local map
	if MapPath ~= LOADED_MAP.filepath then
		map = readMap(MapPath)
	else
		-- no nead to read the map file again if its already loaded
		map = LOADED_MAP
	end

	local c = 0
	for k,v in pairs(map.packages) do
		if LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, v["identifier"]) then
			c = c + 1
		end
	end
	return c
end

function saveSettings()
	local file = io.open(SETTINGS_FILE, "w")
	local j = json.encode(MOD_SETTINGS)
	file:write(j)
	file:close()
end

function loadSettings()
	if not LEX.fileExists(SETTINGS_FILE) then
		return false
	end

	local file = io.open(SETTINGS_FILE, "r")
	local j = json.decode(file:read("*a"))
	file:close()

	MOD_SETTINGS = j

	return true
end

function listFilesInFolder(folder, ext)
	local files = {}
	for k,v in pairs(dir(folder)) do
		for a,b in pairs(v) do
			if a == "name" then
				if LEX.stringEnds(b, ext) then
					table.insert(files, b)
				end
			end
		end
	end
	return files
end

function readMap(path)
	if path == false or not LEX.fileExists(path) then
		return nil
	end

	local file = io.open(path, "r")
	local j = json.decode(file:read("*a"))
	file:close()

	local map = {
		amount = LEX.tableLen(j.locations),
		title = j.title,
		packages = j.locations,
		filename = LEX.basename(path), 
		filepath = path
	}

	return map
end

function showCustomShardPopup(titel, text) -- from #cet-snippets @ discord
    shardUIevent = NotifyShardRead.new()
    shardUIevent.title = titel
    shardUIevent.text = text
    Game.GetUISystem():QueueEvent(shardUIevent)
end

function dumpLocation(x,y,z,w,name,desc,identifier,filename)
	local loc = {
		x = x,
		y = y,
		z = z,
		w = w,
		name = name,
		desc = desc,
		identifier = identifier
	}

	local file = io.open(filename, "w")
	local j = json.encode(loc)
	file:write(j)
	file:close()
end