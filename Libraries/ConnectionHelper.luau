--!strict

-- // About //
-- Made By: JackaBoi
-- Last Updated: 10/14/2026

-- // Types //

export type Cleanup = RBXScriptConnection | Instance | () -> ()
export type Scope = "Player" | "Character"

type Sections = {[string]: {Cleanup}}

export type PlayerRecord = {
	Player: Sections,
	Character: Sections,
	Watchers: {RBXScriptConnection},
}

-- // Services //

local Players = game:GetService("Players")

-- // Config //

local LOG_PREFIX = "[ConnectionHelper] >>"

-- // Local //

local PlayerRecords: {[Player]: PlayerRecord} = {}
local initialized = false

-- // Functions //

local function cleanItem(item: Cleanup)
	if type(item) == "function" then
		-- Spawned so a cleanup that yields can't stall the rest of the cleanup pass
		task.spawn(function()
			local success, err = pcall(item)
			if not success then
				warn(LOG_PREFIX, "Cleanup function errored:", err)
			end
		end)
		return
	end

	local success: boolean, err: any = true, nil
	if typeof(item) == "RBXScriptConnection" then
		success, err = pcall(item.Disconnect, item)
	elseif typeof(item) == "Instance" then
		success, err = pcall(item.Destroy, item)
	end

	if not success then
		warn(LOG_PREFIX, "Cleanup failed:", err)
	end
end

-- Lists and sections are always detached from the record BEFORE being cleaned, so cleanup code
-- that re-enters the module (a cleanup function, or a Destroying handler) can safely add/remove
-- without mutating the table being iterated or having its new items wiped
local function cleanList(list: {Cleanup})
	for _, item in list do
		cleanItem(item)
	end
end

local function cleanSections(sections: Sections)
	for _, list in sections do
		cleanList(list)
	end
end

local function resetCharacter(record: PlayerRecord)
	local old = record.Character
	record.Character = {}
	cleanSections(old)
end

local function isValidCleanup(item: any): boolean
	local kind = typeof(item)
	return kind == "RBXScriptConnection" or kind == "Instance" or kind == "function"
end

local function normalize(items: Cleanup | {Cleanup}): {Cleanup}
	if type(items) == "table" then
		return items :: {Cleanup}
	end
	return {items :: Cleanup}
end

local function getSections(record: PlayerRecord, scope: Scope): Sections
	if scope == "Player" then
		return record.Player
	end
	return record.Character
end

local function removePlayer(player: Player)
	local record = PlayerRecords[player]
	if not record then return end

	PlayerRecords[player] = nil
	for _, watcher in record.Watchers do
		watcher:Disconnect()
	end
	cleanSections(record.Character)
	cleanSections(record.Player)
end

local function init()
	if initialized then return end
	initialized = true

	Players.PlayerRemoving:Connect(removePlayer)
end

local function getRecord(player: Player, create: boolean): PlayerRecord?
	local record = PlayerRecords[player]
	if record or not create then
		return record
	end

	-- Once a player is parented out of Players nothing will fire for them again, so a record would leak
	if player.Parent ~= Players then
		return nil
	end

	init()

	local newRecord: PlayerRecord = {
		Player = {},
		Character = {},
		Watchers = {},
	}
	PlayerRecords[player] = newRecord

	table.insert(newRecord.Watchers, player.CharacterRemoving:Connect(function()
		if PlayerRecords[player] == newRecord then
			resetCharacter(newRecord)
		end
	end))

	-- Safety net for records created after this module's PlayerRemoving handler already ran
	-- (e.g. by another script's PlayerRemoving handler, or by Init connecting mid-fire)
	table.insert(newRecord.Watchers, player.AncestryChanged:Connect(function()
		if player.Parent ~= Players then
			removePlayer(player)
		end
	end))

	return newRecord
end

local function addTo(player: Player, scope: Scope, section: string, items: Cleanup | {Cleanup})
	local list = normalize(items)
	local record = getRecord(player, true)

	if not record then
		warn(LOG_PREFIX, `{player.Name} is no longer in the game, cleaning {scope} section "{section}" immediately`)
		for _, item in list do
			if isValidCleanup(item) then
				cleanItem(item)
			end
		end
		return
	end

	local sections = getSections(record, scope)
	local target = sections[section]
	if not target then
		target = {}
		sections[section] = target
	end

	for _, item in list do
		if isValidCleanup(item) then
			table.insert(target, item)
		else
			warn(LOG_PREFIX, `Ignored invalid item of type {typeof(item)} in {scope} section "{section}"`)
		end
	end
end

local function removeFrom(player: Player, scope: Scope, section: string): boolean
	local record = getRecord(player, false)
	if not record then return false end

	local sections = getSections(record, scope)
	local list = sections[section]
	if not list then
		warn(LOG_PREFIX, `No {scope} connections under section "{section}" for {player.Name}`)
		return false
	end

	sections[section] = nil
	cleanList(list)
	return true
end

local function countSections(sections: Sections): {[string]: number}
	local counts = {}
	for name, list in sections do
		counts[name] = #list
	end
	return counts
end

-- // Module //

local ConnectionHelper = {}

-- Call once at startup for the earliest cleanup on leave. Not required for correctness:
-- the first Add initializes automatically and each record also watches its own player.
function ConnectionHelper:Init()
	init()
end

function ConnectionHelper:AddPlayerConnections(player: Player, section: string, items: Cleanup | {Cleanup})
	addTo(player, "Player", section, items)
end

function ConnectionHelper:RemovePlayerConnections(player: Player, section: string): boolean
	return removeFrom(player, "Player", section)
end

function ConnectionHelper:AddCharacterConnections(player: Player, section: string, items: Cleanup | {Cleanup})
	addTo(player, "Character", section, items)
end

function ConnectionHelper:RemoveCharacterConnections(player: Player, section: string): boolean
	return removeFrom(player, "Character", section)
end

function ConnectionHelper:HasSection(player: Player, scope: Scope, section: string): boolean
	local record = getRecord(player, false)
	return record ~= nil and getSections(record, scope)[section] ~= nil
end

function ConnectionHelper:ClearCharacter(player: Player)
	local record = getRecord(player, false)
	if record then
		resetCharacter(record)
	end
end

function ConnectionHelper:ClearPlayer(player: Player)
	removePlayer(player)
end

-- Returns the live record; treat it as read-only and don't hold onto it,
-- since its Character table is replaced every time the character is cleaned
function ConnectionHelper:GetPlayerConnections(player: Player): PlayerRecord?
	return PlayerRecords[player]
end

function ConnectionHelper:Debug()
	local summary = {}
	for player, record in PlayerRecords do
		summary[player.Name] = {
			Player = countSections(record.Player),
			Character = countSections(record.Character),
		}
	end
	print(LOG_PREFIX, "DEBUG:", summary)
end

return ConnectionHelper
