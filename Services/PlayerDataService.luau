-- // About //
-- Made By: JackaBoi
-- Last Updated: 3/19/2026
-- Check Libs for Required Libraries

-- // Example Module //
-- Must be placed under this ModuleScript!
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

-- // Services //

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

-- // Libs // -- Required!!!

local Table2Attribute = require(ServerScriptService.Libraries.Table2Attribute)
local ProfileStore = require(ServerScriptService.Libraries.ProfileStore) 
local ProfileTemplate = require(script.ProfileTemplate)
local ConnectionHelper = require(ServerScriptService.Libraries.ConnectionHelper)

-- // Local //

local PlayerStore = ProfileStore.New("PlayerStore",ProfileTemplate)
local PlayerProfiles: {[Player]: typeof(PlayerStore:StartSessionAsync())} = {}

-- // Functions //

local function playerSetupAttributes(player: Player)
	
	local profileData = PlayerProfiles[player].Data
	
	local privateData = Instance.new("Configuration")
	privateData.Name = player.Name
	privateData.Parent = ServerStorage.PlayerPrivateData
	
	Table2Attribute.Convert2Attribute(player,profileData.public)
	Table2Attribute.Convert2Attribute(ServerStorage.PlayerPrivateData[player.Name],profileData.private)
	
	local publicAttributeConnection = player.AttributeChanged:Connect(function(changedAttributeName)
		if not ProfileTemplate.public[changedAttributeName] then return end
		profileData.public[changedAttributeName] = player:GetAttribute(changedAttributeName)
	end)
	
	local privateAttributeConnection = privateData.AttributeChanged:Connect(function(changedAttributeName)
		if not ProfileTemplate.private[changedAttributeName] then return end
		profileData.private[changedAttributeName] = privateData:GetAttribute(changedAttributeName)
	end)
	
	ConnectionHelper:AddPlayerConnections(player, script.Name, {publicAttributeConnection, privateAttributeConnection})
	
end

local function playerProfileLoad(player: Player)
	
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
	profile:Reconcile()
	
	profile.OnSessionEnd:Connect(function()
		print(`[PlayerDataService]: Profile Removed - {player.Name}`, profile.Data)
		PlayerProfiles[player] = nil
		local privateData = ServerStorage.PlayerPrivateData:FindFirstChild(player.Name)
		if privateData then privateData:Destroy() end
		player:Kick("Profile Session Ended! - Please Rejoin!")
	end)
	
	profile.OnAfterSave:Connect(function(last_saved_data)
		print(`[PlayerDataService]: Profile Saved - {player.Name}`, last_saved_data)
	end)
	
	if player.Parent ~= Players then profile:EndSession() return end
	
	PlayerProfiles[player] = profile
	player:AddTag("DataLoaded")
	
	playerSetupAttributes(player)
	
	-- TODO: Implement profileVersion and Conversions/Updates to newer versions
	
	print(`[PlayerDataService]: Profile Added - {player.Name}`, profile.Data)
	
end

local function playerProfileUnload(player: Player)
	if not PlayerProfiles[player] then return end
	PlayerProfiles[player]:EndSession()
end

local PlayerData = {}

function PlayerData:Init()
	
	Players.PlayerAdded:Connect(playerProfileLoad)
	Players.PlayerRemoving:Connect(playerProfileUnload)
	
	-- Check for Preexisting Players
	for _,player in Players:GetPlayers() do
		task.spawn(playerProfileLoad, player)
	end
	
end

function PlayerData:PlayerDataAdded(player: Player): typeof(ProfileTemplate)
	repeat task.wait() until PlayerProfiles[player]
	return PlayerProfiles[player]
end

function PlayerData:GetDataTableRef(player: Player): typeof(ProfileTemplate)
	warn("[PlayerDataService]: Please switch to using :GetAttribute when possible!")
	return PlayerProfiles[player].Data
end

--function PlayerData:GetOfflinePlayer(userId: number): typeof(ProfileTemplate)
--	return PlayerStore:
--end

function PlayerData:WipeData(userId: number)
	
	local player = Players:GetPlayerByUserId(userId)
	
	local profile
	
	if player then
		profile = PlayerProfiles[player]
	else
		local success, err = pcall(function()profile = PlayerStore:GetAsync(`{userId}`)end)
		if not success then return false end
	end
	
	if profile and profile:IsActive() then
		local success, err = pcall(function()profile:EndSession()end)
		if not success then return false end
	end
	
	return PlayerStore:RemoveAsync(`{userId}`)

end

return PlayerData