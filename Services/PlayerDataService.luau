-- // About //
-- Made By: JackaBoi
-- Last Updated: 10/5/2026
-- Check Libs for Required Libraries

-- // Example Module //
-- Must be placed under this ModuleScript as "ProfileTemplate"!
-- private.profileVersion is required (used by Migrations below).
--
-- return {
-- 	private = {
-- 		profileVersion = 0,
-- 		warnings = 0
-- 	},
-- 	public = {
-- 		xp = 0,
-- 		pocketchange = 0,
-- 		rank = ""
-- 	}
-- }
--
-- public  -> attributes on the Player (replicated to clients, read only for them)
-- private -> attributes on ServerStorage.PlayerPrivateData[player.Name] (server only)
-- Setting an attribute on the server writes it into the profile.
-- Nested tables are saved but are NOT turned into attributes; use :GetDataTableRef for those.

-- // Services //

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

-- // Libs // -- Required!!!

local Table2Attribute = require(ServerScriptService.Libraries.Table2Attribute)
local ProfileStore = require(ServerScriptService.Libraries.ProfileStore)
local ProfileTemplate = require(script.ProfileTemplate)
local ConnectionHelper = require(ServerScriptService.Libraries.ConnectionHelper)

-- // Config //

local DEBUG = true -- prints profile data on load / save / release
local STORE_NAME = "PlayerStore"
local PRIVATE_FOLDER_NAME = "PlayerPrivateData"
local WAIT_TIMEOUT = 30 -- seconds :PlayerDataAdded waits before giving up

-- Migrations[n] upgrades saved data from version n-1 to version n.
-- Only ever ADD to the end of this list; never edit or reorder old entries.
-- Runs before Reconcile, so "data" is in the old shape.
--
-- Example:
-- [1] = function(data)
-- 	data.public.coins = data.public.pocketchange
-- 	data.public.pocketchange = nil
-- end,
local Migrations: {(data: any) -> ()} = {
}

local CURRENT_VERSION = #Migrations

-- // Local //

local PlayerStore = ProfileStore.New(STORE_NAME, ProfileTemplate)
local PlayerProfiles: {[Player]: typeof(PlayerStore:StartSessionAsync())} = {}
local PrivateFolders: {[Player]: Configuration} = {}

-- // Functions //

local function debugPrint(...)
	if DEBUG then print("[PlayerDataService]:", ...) end
end

local function deepCopy(original)
	local copy = {}
	for key, value in original do
		copy[key] = if type(value) == "table" then deepCopy(value) else value
	end
	return copy
end

local function getPrivateRoot(): Instance
	local root = ServerStorage:FindFirstChild(PRIVATE_FOLDER_NAME)
	if not root then
		root = Instance.new("Folder")
		root.Name = PRIVATE_FOLDER_NAME
		root.Parent = ServerStorage
	end
	return root
end

-- Returns false if the data could not be brought up to date (data is left untouched)
local function migrateProfile(profile): boolean

	local data = profile.Data
	if type(data.private) ~= "table" then data.private = {} end

	-- Brand new profile: already in the newest shape
	if profile.SessionLoadCount <= 1 then
		data.private.profileVersion = CURRENT_VERSION
		return true
	end

	local version = tonumber(data.private.profileVersion) or 0
	if version >= CURRENT_VERSION then return true end

	-- Work on a copy so a failed migration never leaves half converted data to be saved
	local working = deepCopy(data)

	for nextVersion = version + 1, CURRENT_VERSION do
		local success, err = pcall(Migrations[nextVersion], working)
		if not success then
			warn(`[PlayerDataService]: Migration to version {nextVersion} failed - {err}`)
			return false
		end
	end

	if type(working.private) ~= "table" then working.private = {} end
	working.private.profileVersion = CURRENT_VERSION

	table.clear(data)
	for key, value in working do
		data[key] = value
	end

	return true

end

-- Mirrors one section of the profile (public / private) onto an instance's attributes
local function linkAttributes(holder: Instance, dataSection: {[string]: any}, templateSection: {[string]: any}): RBXScriptConnection

	-- Saved value of the wrong type (old data): fall back to the template value
	for name, templateValue in templateSection do
		if type(templateValue) == "table" then continue end
		if typeof(dataSection[name]) ~= typeof(templateValue) then
			dataSection[name] = templateValue
		end
	end

	Table2Attribute.Convert2Attribute(holder, dataSection)

	return holder.AttributeChanged:Connect(function(name)

		local templateValue = templateSection[name]
		if templateValue == nil or type(templateValue) == "table" then return end -- not profile data

		local value = holder:GetAttribute(name)
		if value == dataSection[name] then return end

		-- Wrong type, removed (nil) or NaN would corrupt the save: put the old value back
		if typeof(value) ~= typeof(templateValue) or value ~= value then
			warn(`[PlayerDataService]: Rejected value for "{name}" on {holder:GetFullName()} - expected {typeof(templateValue)}, got {typeof(value)}`)
			holder:SetAttribute(name, dataSection[name])
			return
		end

		dataSection[name] = value

	end)

end

local function playerSetupAttributes(player: Player, profile)

	local privateData = Instance.new("Configuration")
	privateData.Name = player.Name
	privateData.Parent = getPrivateRoot()
	PrivateFolders[player] = privateData

	local publicConnection = linkAttributes(player, profile.Data.public, ProfileTemplate.public)
	local privateConnection = linkAttributes(privateData, profile.Data.private, ProfileTemplate.private)

	ConnectionHelper:AddPlayerConnections(player, script.Name, {publicConnection, privateConnection})

end

local function playerCleanup(player: Player)

	PlayerProfiles[player] = nil
	player:RemoveTag("DataLoaded")

	-- Stop attribute changes from writing into a profile that is no longer ours
	if ConnectionHelper:GetPlayerConnections(player) and ConnectionHelper:GetPlayerConnections(player).Player[script.Name] then
		ConnectionHelper:RemovePlayerConnections(player, script.Name)
	end

	local privateData = PrivateFolders[player]
	PrivateFolders[player] = nil
	if privateData then privateData:Destroy() end

end

local function playerProfileLoad(player: Player)

	if PlayerProfiles[player] then return end

	local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if not profile then
		player:Kick("Failed To Load Profile! - Please Rejoin!")
		return
	end

	profile:AddUserId(player.UserId)

	if not migrateProfile(profile) then
		profile:EndSession()
		player:Kick("Failed To Update Profile! - Please Rejoin!")
		return
	end

	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		debugPrint(`Profile Removed - {player.Name}`, profile.Data)
		playerCleanup(player)
		player:Kick("Profile Session Ended! - Please Rejoin!")
	end)

	profile.OnAfterSave:Connect(function(last_saved_data)
		debugPrint(`Profile Saved - {player.Name}`, last_saved_data)
	end)

	-- Player left while the profile was loading
	if player.Parent ~= Players then profile:EndSession() return end

	PlayerProfiles[player] = profile
	playerSetupAttributes(player, profile)
	player:AddTag("DataLoaded") -- added last so attributes exist when listeners react to the tag

	debugPrint(`Profile Added - {player.Name}`, profile.Data)

end

local function playerProfileUnload(player: Player)
	local profile = PlayerProfiles[player]
	if not profile then return end
	profile:EndSession()
end

-- // Module //

local PlayerData = {}

local initialized = false

function PlayerData:Init()

	if initialized then return end
	initialized = true

	getPrivateRoot()

	Players.PlayerAdded:Connect(playerProfileLoad)
	Players.PlayerRemoving:Connect(playerProfileUnload)

	-- Check for Preexisting Players
	for _,player in Players:GetPlayers() do
		task.spawn(playerProfileLoad, player)
	end

end

function PlayerData:IsLoaded(player: Player): boolean
	return PlayerProfiles[player] ~= nil
end

-- Yields until the player's profile is loaded and returns it.
-- Returns nil if the player leaves, fails to load or the timeout runs out.
function PlayerData:PlayerDataAdded(player: Player, timeout: number?): typeof(PlayerStore:StartSessionAsync())?

	local deadline = os.clock() + (timeout or WAIT_TIMEOUT)

	while not PlayerProfiles[player] do
		if player.Parent ~= Players or os.clock() > deadline then return nil end
		task.wait()
	end

	return PlayerProfiles[player]

end

-- Direct reference to the saved table. Needed for nested tables; prefer attributes for everything else.
-- Returns nil if the profile is not loaded.
function PlayerData:GetDataTableRef(player: Player): typeof(ProfileTemplate)?
	local profile = PlayerProfiles[player]
	return if profile then profile.Data else nil
end

-- The server only Configuration holding the player's private attributes (nil if not loaded)
function PlayerData:GetPrivateData(player: Player): Configuration?
	return PrivateFolders[player]
end

-- Read only copy of a player's saved data, online or offline. Returns nil if none exists or the read fails.
function PlayerData:GetOfflineData(userId: number): typeof(ProfileTemplate)?

	local player = Players:GetPlayerByUserId(userId)
	if player and PlayerProfiles[player] then
		return deepCopy(PlayerProfiles[player].Data)
	end

	local success, profile = pcall(function()
		return PlayerStore:GetAsync(`{userId}`)
	end)

	if not success or not profile then return nil end
	return profile.Data

end

-- Deletes all saved data for a user. An online player is kicked first. Returns true on success.
function PlayerData:WipeData(userId: number): boolean

	local player = Players:GetPlayerByUserId(userId)
	local profile = player and PlayerProfiles[player]

	if profile and profile:IsActive() then
		profile:EndSession() -- fires OnSessionEnd -> cleanup + kick
	end

	local success, result = pcall(function()
		return PlayerStore:RemoveAsync(`{userId}`)
	end)

	if not success then
		warn(`[PlayerDataService]: Failed to wipe data for {userId} - {result}`)
		return false
	end

	return result == true

end

return PlayerData
