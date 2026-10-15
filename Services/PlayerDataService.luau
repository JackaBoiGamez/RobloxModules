--!strict

-- // About //
-- Made By: JackaBoi
-- Last Updated: 10/14/2026
-- Requires ProfileStore (see Libs) and a "ProfileTemplate" ModuleScript placed under this one.
-- private.profileVersion is required (used by Migrations below).
--
-- return {
-- 	private = {
-- 		profileVersion = 0,
-- 		warnings = 0,
-- 	},
-- 	public = {
-- 		xp = 0,
-- 		pocketchange = 0,
-- 		rank = "",
-- 	},
-- }
--
-- public  -> attributes on Player.PublicData (Configuration, replicated, read only for clients)
-- private -> attributes on ServerStorage.PlayerPrivateData[player.Name] (Configuration, server only)
-- Setting one of those attributes on the server writes it into the profile.
-- Nested tables are saved but not mirrored as attributes; use :GetDataTableRef for those.
--
-- Cross server (ProfileStore:MessageAsync + Profile:MessageHandler):
-- :SetDataRemote / :IncrementDataRemote / :SendMessage reach the player on whichever server holds their
-- session, or are queued in the profile and applied when their next session starts if they're offline.
-- Register :OnMessage handlers BEFORE :Init so queued messages always have a handler waiting.

-- // Types //

export type Section = "public" | "private"
export type MessageHandler = (player: Player, payload: any) -> ()

-- // Services //

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

-- // Libs //

local ProfileStore = require(ServerScriptService.Libraries.ProfileStore)
local ProfileTemplate = require(script.ProfileTemplate)

-- // Config //

local DEBUG = false -- prints profile data on load / save / end
local STORE_NAME = "PlayerStore"
local PUBLIC_FOLDER_NAME = "PublicData"
local PRIVATE_FOLDER_NAME = "PlayerPrivateData"
local LOADED_TAG = "DataLoaded"
local WAIT_TIMEOUT = 30 -- seconds :PlayerDataAdded waits before giving up

-- Keys that only this module may write (never through attributes, :SetData or messages)
local PROTECTED_KEYS = {
	profileVersion = true,
}

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

-- Lives here rather than in Types because it's derived from PlayerStore
type Profile = typeof(PlayerStore:StartSessionAsync(""))

local PlayerProfiles: {[Player]: Profile} = {}
local LoadingPlayers: {[Player]: boolean} = {}
local PublicFolders: {[Player]: Configuration} = {}
local PrivateFolders: {[Player]: Configuration} = {}
local LoadWaiters: {[Player]: {thread}} = {}
local TopicHandlers: {[string]: MessageHandler} = {}
local initialized = false

-- // Functions //

local function debugPrint(...: any)
	if DEBUG then
		print("[PlayerDataService]:", ...)
	end
end

local function deepCopy(original: any): any
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
	return root :: Instance
end

local function getDataSection(profile: any, section: string): {[string]: any}?
	local data = profile.Data[section]
	return if type(data) == "table" then data else nil
end

-- Returns the template's value for a saved (non table) key, or nil if the key isn't profile data
local function getTemplateValue(section: string, key: string): any
	local templateSection = (ProfileTemplate :: any)[section]
	if type(templateSection) ~= "table" then return nil end

	local value = templateSection[key]
	return if type(value) == "table" then nil else value
end

-- Checks a write against the template. Returns false and a reason if it would corrupt the save.
local function validateWrite(section: any, key: any, value: any): (boolean, string?)
	if section ~= "public" and section ~= "private" then
		return false, `unknown section "{tostring(section)}"`
	end
	if type(key) ~= "string" then
		return false, "key must be a string"
	end
	if PROTECTED_KEYS[key] then
		return false, `"{key}" is protected`
	end

	local templateValue = getTemplateValue(section, key)
	if templateValue == nil then
		return false, `"{section}.{key}" is not in the template`
	end
	if typeof(value) ~= typeof(templateValue) then
		return false, `"{section}.{key}" expects {typeof(templateValue)}, got {typeof(value)}`
	end
	-- NaN and inf can't be encoded by DataStores, so they would make every save fail
	if type(value) == "number" and (value ~= value or math.abs(value) == math.huge) then
		return false, `"{section}.{key}" must be a finite number`
	end

	return true
end

-- Writes the profile first, then the attribute; the attribute handler then sees no change.
-- Writing the profile directly (instead of only setting the attribute) matters under deferred
-- signals: the session could end before a deferred AttributeChanged handler ever runs.
local function writeValue(player: Player, profile: any, section: Section, key: string, value: any)
	local data = getDataSection(profile, section)
	if not data then return end
	data[key] = value

	local holder = if section == "public" then PublicFolders[player] else PrivateFolders[player]
	if holder then
		holder:SetAttribute(key, value)
	end
end

-- Returns false if the data could not be brought up to date (data is left untouched)
local function migrateProfile(profile: any): boolean
	local data = profile.Data
	if type(data.private) ~= "table" then
		data.private = {}
	end

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

	if type(working.private) ~= "table" then
		working.private = {}
	end
	working.private.profileVersion = CURRENT_VERSION

	table.clear(data)
	for key, value in working do
		data[key] = value
	end

	return true
end

-- Mirrors one section of the profile onto a Configuration's attributes. The connection is owned by
-- the Configuration, so destroying it on cleanup is what stops writes into an ended profile.
local function linkAttributes(holder: Configuration, section: Section, dataSection: {[string]: any})
	local templateSection = (ProfileTemplate :: any)[section]

	for name, templateValue in templateSection do
		if type(templateValue) == "table" then continue end

		-- Saved value of the wrong type (old data): fall back to the template value
		if typeof(dataSection[name]) ~= typeof(templateValue) then
			dataSection[name] = templateValue
		end

		local success, err = pcall(holder.SetAttribute, holder, name, dataSection[name])
		if not success then
			warn(`[PlayerDataService]: Could not mirror "{section}.{name}" as an attribute - {err}`)
		end
	end

	holder.AttributeChanged:Connect(function(name: string)
		local templateValue = templateSection[name]
		if templateValue == nil or type(templateValue) == "table" then return end -- not profile data

		local value = holder:GetAttribute(name)
		if value == dataSection[name] then return end

		-- Wrong type, removed (nil), NaN or protected: put the saved value back
		local valid, reason = validateWrite(section, name, value)
		if not valid then
			warn(`[PlayerDataService]: Rejected attribute change on {holder:GetFullName()} - {reason}`)
			holder:SetAttribute(name, dataSection[name])
			return
		end

		dataSection[name] = value
	end)
end

local function setupAttributes(player: Player, profile: any)
	local publicData = Instance.new("Configuration")
	publicData.Name = PUBLIC_FOLDER_NAME
	linkAttributes(publicData, "public", profile.Data.public)
	PublicFolders[player] = publicData

	local privateData = Instance.new("Configuration")
	privateData.Name = player.Name
	linkAttributes(privateData, "private", profile.Data.private)
	PrivateFolders[player] = privateData

	-- Parented after the attributes exist so anything waiting on the child sees full data
	publicData.Parent = player
	privateData.Parent = getPrivateRoot()
end

-- Wakes every thread waiting in :PlayerDataAdded. Each thread is removed before being resumed,
-- so a thread can never be resumed twice (by this and by its timeout).
local function resolveWaiters(player: Player, profile: Profile?)
	local waiters = LoadWaiters[player]
	if not waiters then return end
	LoadWaiters[player] = nil

	for _, thread in waiters do
		task.spawn(thread, profile)
	end
end

local function playerCleanup(player: Player, profile: any)
	-- Guarded so a cleanup that already ran (e.g. :WipeData then OnSessionEnd) does nothing
	if PlayerProfiles[player] ~= profile then return end
	PlayerProfiles[player] = nil

	player:RemoveTag(LOADED_TAG)

	local publicData = PublicFolders[player]
	PublicFolders[player] = nil
	if publicData then publicData:Destroy() end

	local privateData = PrivateFolders[player]
	PrivateFolders[player] = nil
	if privateData then privateData:Destroy() end
end

-- Returns true if the message is done with (applied, or invalid and dropped).
-- Returns false to leave it queued in the profile, so it is retried on a later delivery/session.
local function applyMessage(player: Player, profile: any, message: any): boolean
	if type(message) ~= "table" then
		warn(`[PlayerDataService]: Dropped malformed message for {player.Name}`)
		return true
	end

	local kind = message.Kind

	if kind == "Set" or kind == "Increment" then
		local section, key = message.Section, message.Key
		local value = message.Value

		if kind == "Increment" then
			local data = if type(section) == "string" then getDataSection(profile, section) else nil
			local current = if data and type(key) == "string" then data[key] else nil
			local delta = message.Delta

			if type(current) ~= "number" or type(delta) ~= "number" then
				warn(`[PlayerDataService]: Dropped Increment for {player.Name} - "{tostring(section)}.{tostring(key)}" is not a number`)
				return true
			end
			value = current + delta
		end

		local valid, reason = validateWrite(section, key, value)
		if not valid then
			warn(`[PlayerDataService]: Dropped {kind} for {player.Name} - {reason}`)
			return true
		end

		writeValue(player, profile, section, key, value)
		debugPrint(`{kind} {section}.{key} = {tostring(value)} for {player.Name} (from {tostring(message.FromJobId)})`)
		return true
	end

	if kind == "Topic" then
		local handler = TopicHandlers[message.Topic]
		if not handler then
			warn(`[PlayerDataService]: No handler for topic "{tostring(message.Topic)}", leaving it queued for {player.Name}`)
			return false
		end

		-- An erroring handler still marks the message processed, otherwise it would fail forever
		local success, err = pcall(handler, player, message.Payload)
		if not success then
			warn(`[PlayerDataService]: Handler for topic "{message.Topic}" errored - {err}`)
		end
		return true
	end

	warn(`[PlayerDataService]: Dropped message of unknown kind "{tostring(kind)}" for {player.Name}`)
	return true
end

local function attachMessageHandler(player: Player, profile: any)
	profile:MessageHandler(function(message: any, processed: () -> ())
		-- Not ours anymore: leave it queued for the player's next session
		if PlayerProfiles[player] ~= profile or not profile:IsActive() then return end

		if applyMessage(player, profile, message) then
			processed()
		end
	end)
end

-- Applies instantly when the player is loaded on this server, otherwise queues it through ProfileStore
local function deliverMessage(userId: number, message: {[string]: any}): boolean
	message.SentAt = os.time()
	message.FromJobId = game.JobId

	local player = Players:GetPlayerByUserId(userId)
	local profile = player and PlayerProfiles[player]
	if player and profile and profile:IsActive() and applyMessage(player, profile, message) then
		return true
	end

	local success, result = pcall(function()
		return PlayerStore:MessageAsync(`{userId}`, message)
	end)

	if not success then
		warn(`[PlayerDataService]: Failed to send message to {userId} - {result}`)
		return false
	end

	return result ~= false
end

local function playerProfileLoad(player: Player)
	-- LoadingPlayers stops PlayerAdded and the Init loop from both starting a session for one player
	if PlayerProfiles[player] or LoadingPlayers[player] then return end
	LoadingPlayers[player] = true

	local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	LoadingPlayers[player] = nil

	if not profile then
		resolveWaiters(player, nil)
		if player.Parent == Players then
			player:Kick("Failed To Load Profile! - Please Rejoin!")
		end
		return
	end

	profile:AddUserId(player.UserId)

	if not migrateProfile(profile) then
		profile:EndSession()
		resolveWaiters(player, nil)
		if player.Parent == Players then
			player:Kick("Failed To Update Profile! - Please Rejoin!")
		end
		return
	end

	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		debugPrint(`Profile Ended - {player.Name}`, profile.Data)
		playerCleanup(player, profile)
		if player.Parent == Players then
			player:Kick("Profile Session Ended! - Please Rejoin!")
		end
	end)

	profile.OnAfterSave:Connect(function(lastSavedData)
		debugPrint(`Profile Saved - {player.Name}`, lastSavedData)
	end)

	-- Player left, or the session was stolen, while loading
	if player.Parent ~= Players or not profile:IsActive() then
		if profile:IsActive() then
			profile:EndSession()
		end
		resolveWaiters(player, nil)
		return
	end

	PlayerProfiles[player] = profile
	setupAttributes(player, profile)

	-- After attributes exist, so queued remote changes land on the attributes too
	attachMessageHandler(player, profile)

	player:AddTag(LOADED_TAG) -- last, so attributes exist when listeners react to the tag
	resolveWaiters(player, profile)

	debugPrint(`Profile Loaded - {player.Name}`, profile.Data)
end

local function playerProfileUnload(player: Player)
	resolveWaiters(player, nil)

	local profile = PlayerProfiles[player]
	if profile then
		profile:EndSession()
	end
end

-- // Module //

local PlayerDataService = {}

function PlayerDataService:Init()
	if initialized then return end
	initialized = true

	getPrivateRoot()

	Players.PlayerAdded:Connect(playerProfileLoad)
	Players.PlayerRemoving:Connect(playerProfileUnload)

	for _, player in Players:GetPlayers() do
		task.spawn(playerProfileLoad, player)
	end
end

function PlayerDataService:IsLoaded(player: Player): boolean
	return PlayerProfiles[player] ~= nil
end

-- Yields until the player's profile is loaded and returns it.
-- Returns nil if the player leaves, fails to load or the timeout runs out.
function PlayerDataService:PlayerDataAdded(player: Player, timeout: number?): Profile?
	local loaded = PlayerProfiles[player]
	if loaded then return loaded end
	if player.Parent ~= Players then return nil end

	local thread = coroutine.running()
	local waiters = LoadWaiters[player]
	if not waiters then
		waiters = {}
		LoadWaiters[player] = waiters
	end
	table.insert(waiters, thread)

	local timeoutThread = task.delay(timeout or WAIT_TIMEOUT, function()
		local current = LoadWaiters[player]
		local index = current and table.find(current, thread)
		if current and index then
			table.remove(current, index)
			task.spawn(thread, nil)
		end
	end)

	local profile = coroutine.yield()

	-- Resolved before the timeout: stop it (it's "normal", not "suspended", if it is what resumed us)
	if coroutine.status(timeoutThread) == "suspended" then
		task.cancel(timeoutThread)
	end

	return profile
end

-- Direct reference to the saved table. Needed for nested tables; prefer attributes for everything else.
-- Returns nil if the profile is not loaded.
function PlayerDataService:GetDataTableRef(player: Player): typeof(ProfileTemplate)?
	local profile = PlayerProfiles[player]
	return if profile then profile.Data else nil
end

-- The Configuration under the Player holding public attributes (nil if not loaded)
function PlayerDataService:GetPublicData(player: Player): Configuration?
	return PublicFolders[player]
end

-- The server only Configuration holding private attributes (nil if not loaded)
function PlayerDataService:GetPrivateData(player: Player): Configuration?
	return PrivateFolders[player]
end

-- Validated write for a player loaded on this server. Returns false if not loaded or the value is invalid.
function PlayerDataService:SetData(player: Player, section: Section, key: string, value: any): boolean
	local profile = PlayerProfiles[player]
	if not profile then return false end

	local valid, reason = validateWrite(section, key, value)
	if not valid then
		warn(`[PlayerDataService]: SetData rejected for {player.Name} - {reason}`)
		return false
	end

	writeValue(player, profile, section, key, value)
	return true
end

-- Sets a value for a user on any server, or on their next join if offline. Yields.
-- Returns true once the change is applied here or queued in their profile.
function PlayerDataService:SetDataRemote(userId: number, section: Section, key: string, value: any): boolean
	local valid, reason = validateWrite(section, key, value)
	if not valid then
		warn(`[PlayerDataService]: SetDataRemote rejected for {userId} - {reason}`)
		return false
	end

	return deliverMessage(userId, {
		Kind = "Set",
		Section = section,
		Key = key,
		Value = value,
	})
end

-- Adds to a number on any server, or on their next join if offline. Yields.
-- The sum is done by the server holding the session, so increments from many servers never overwrite each other.
function PlayerDataService:IncrementDataRemote(userId: number, section: Section, key: string, delta: number): boolean
	if type(getTemplateValue(section, key)) ~= "number" or PROTECTED_KEYS[key] then
		warn(`[PlayerDataService]: IncrementDataRemote rejected for {userId} - "{section}.{key}" is not a writable number`)
		return false
	end
	if type(delta) ~= "number" or delta ~= delta or math.abs(delta) == math.huge then
		warn(`[PlayerDataService]: IncrementDataRemote rejected for {userId} - delta must be a finite number`)
		return false
	end

	return deliverMessage(userId, {
		Kind = "Increment",
		Section = section,
		Key = key,
		Delta = delta,
	})
end

-- Sends a custom message to a user wherever their session is (or their next one). Yields.
-- The payload must be DataStore safe: strings, numbers, booleans and plain tables of those.
function PlayerDataService:SendMessage(userId: number, topic: string, payload: any?): boolean
	return deliverMessage(userId, {
		Kind = "Topic",
		Topic = topic,
		Payload = payload,
	})
end

-- Receives :SendMessage calls for a topic on this server. The handler runs once per message and must not yield.
function PlayerDataService:OnMessage(topic: string, handler: MessageHandler)
	if TopicHandlers[topic] then
		warn(`[PlayerDataService]: Replacing existing handler for topic "{topic}"`)
	end
	TopicHandlers[topic] = handler
end

-- Read only copy of a player's saved data, online or offline. Returns nil if none exists or the read fails.
-- For a player on another server this is their last save, so it can be a few minutes behind.
function PlayerDataService:GetOfflineData(userId: number): typeof(ProfileTemplate)?
	local player = Players:GetPlayerByUserId(userId)
	local profile = player and PlayerProfiles[player]
	if profile then
		return deepCopy(profile.Data)
	end

	local success, result = pcall(function()
		return PlayerStore:GetAsync(`{userId}`)
	end)

	if not success or not result then return nil end
	return result.Data
end

-- Deletes all saved data for a user. An online player on this server is kicked. Returns true on success.
function PlayerDataService:WipeData(userId: number): boolean
	local player = Players:GetPlayerByUserId(userId)
	local profile = player and PlayerProfiles[player]

	if player and profile and profile:IsActive() then
		-- Reset in place and let the final save write it. RemoveAsync here would race that final save,
		-- which could write the old data straight back after the removal.
		playerCleanup(player, profile)

		local fresh = deepCopy(ProfileTemplate)
		fresh.private.profileVersion = CURRENT_VERSION

		local data = profile.Data :: any
		table.clear(data)
		for key, value in fresh do
			data[key] = value
		end

		-- Kick first so this message wins over OnSessionEnd's generic one
		player:Kick("Your Data Was Reset! - Please Rejoin!")
		profile:EndSession()
		return true
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

return PlayerDataService
