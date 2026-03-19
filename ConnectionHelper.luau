-- // About //
-- Made By: JackaBoi
-- Last Updated: 11/19/2025

-- // Services //

local Players = game:GetService("Players")

-- // Local //

local PlayerConnections: {[Player]: {
	["Player"]: {string: {RBXScriptConnection}},
	["Character"]: {string: {RBXScriptConnection}}
}} = {}

local initializedRemove = false

-- // Functions //

local function playerRemove(player: Player)

	for sectionName,section in PlayerConnections[player].Character do
		for _,connection in section do
			local success = pcall(function() connection:Disconnect() end)
			if not success then warn("Multiple Disconnects Called Possible Issue!") end
		end
	end
	for sectionName,section in PlayerConnections[player].Player do
		for _,connection in section do
			local success = pcall(function() connection:Disconnect() end)
			if not success then warn("Multiple Disconnects Called Possible Issue!") end
		end
	end

	PlayerConnections[player] = nil

end

local function playerAdded(player: Player)
	if PlayerConnections[player] then warn("Attempted to add Player who already exists within connection list!") return end
	if not initializedRemove then
		initializedRemove=true
		Players.PlayerRemoving:Connect(playerRemove)
	end
	PlayerConnections[player] = {
		["Player"] = {
			["ConnectionHelper"] = {
				[1] = player.CharacterRemoving:Connect(function()
					for sectionName,section in PlayerConnections[player].Character do
						for _,connection in section do
							local success = pcall(function() connection:Disconnect() end)
							if not success then warn("Multiple Disconnects Called Possible Issue!") end
						end
					end
					PlayerConnections[player].Character = {}
				end)
			}
		},
		["Character"] = {}
	}

end

-- // Module //

local ConnectionHelper = {}

function ConnectionHelper:AddPlayerConnections(player: Player, section: string, connections: {RBXScriptConnection})
	if not PlayerConnections[player] then playerAdded(player) end
	if not PlayerConnections[player].Player[section] then PlayerConnections[player].Player[section] = {} end
	for _,connection in connections do
		table.insert(PlayerConnections[player].Player[section], connection)
	end
end

function ConnectionHelper:RemovePlayerConnections(player: Player, section: string)
	if not PlayerConnections[player] then return end
	if not PlayerConnections[player].Player[section] then 
		warn(`[ConnectionHelper] >> No Player Connections Under Section: {section} For: {player.Name}`)
		return
	end
	for _,connection in PlayerConnections[player].Player[section] do
		local success = pcall(function() connection:Disconnect() end)
		if not success then warn("Multiple Disconnects Called Possible Issue!") end
	end
	PlayerConnections[player].Player[section] = nil
end

function ConnectionHelper:AddCharacterConnections(player: Player, section: string, connections: {RBXScriptConnection})
	if not PlayerConnections[player] then playerAdded(player) end
	if not PlayerConnections[player].Character[section] then PlayerConnections[player].Character[section] = {} end
	for _,connection in connections do
		table.insert(PlayerConnections[player].Character[section], connection)
	end
end

function ConnectionHelper:RemoveCharacterConnections(player: Player, section: string)
	if not PlayerConnections[player] then return end
	if not PlayerConnections[player].Character[section] then 
		warn(`[ConnectionHelper] >> No Character Connections Under Section: {section} For: {player.Name}`)
		return
	end
	for _,connection in PlayerConnections[player].Character[section] do
		local success = pcall(function() connection:Disconnect() end)
		if not success then warn("Multiple Disconnects Called Possible Issue!") end
	end
	PlayerConnections[player].Character[section] = nil
end

function ConnectionHelper:GetPlayerConnections(player: Player)
	return PlayerConnections[player]
end

function ConnectionHelper:Debug()
	print("DEBUG: ", PlayerConnections)
end

return ConnectionHelper
