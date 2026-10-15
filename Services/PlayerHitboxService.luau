--!strict

-- // About //
-- Made By: JackaBoi
-- Last Updated: 10/14/2026
-- Requires ConnectionHelper (see Libs).
--
-- Server side hitbox for every player's character that is harder to exploit than .Touched and
-- the same size for every avatar (small avatars get no advantage). The box is computed from the
-- HumanoidRootPart each update instead of being a welded part, so there is nothing physical for
-- a client to delete, resize or move.
--
-- Parts need the "Interactable" tag, plus a tag matching the name of an interaction module.
-- Interaction modules are ModuleScripts placed under this one (named after their tag), or
-- registered from code with :RegisterInteraction. Hit and HitEnd are both optional.
--
-- local QueueUp = {}
--
-- function QueueUp:Hit(player: Player, hitPart: BasePart)
-- 	QueueService:AttemptAddPlayer(player, hitPart)
-- end
--
-- function QueueUp:HitEnd(player: Player, hitPart: BasePart)
-- 	QueueService:RemovePlayer(player, hitPart)
-- end
--
-- return QueueUp
--
-- Every Hit is followed by exactly one HitEnd for the same player and part: when they step off,
-- when the part loses its tag or is destroyed, on death, respawn, leaving or :SetEnabled(false).
-- Handlers run in their own thread. If Hit yields for longer than UPDATE_INTERVAL, the matching
-- HitEnd can start before Hit has finished.

-- // Types //

export type InteractModule = {
	Hit: ((self: any, player: Player, hitPart: BasePart) -> ())?,
	HitEnd: ((self: any, player: Player, hitPart: BasePart) -> ())?,
}

type PlayerState = {
	Character: Model,
	RootPart: BasePart,
	Humanoid: Humanoid,
	Touching: {[BasePart]: {string}}, -- part -> interaction names its Hit went to, so HitEnd goes to the same ones
	DebugPart: Part?,
}

type PendingCall = {
	Method: "Hit" | "HitEnd",
	Name: string,
	Player: Player,
	Part: BasePart,
}

-- // Services //

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- // Libs //

local ConnectionHelper = require(ServerScriptService.Libraries.ConnectionHelper)

-- // Config //

local INTERACTABLE_TAG = "Interactable"
local HITBOX_SIZE = Vector3.new(2.5, 5.5, 1.25)
local UPDATE_INTERVAL = 0.05
local CHARACTER_LOAD_TIMEOUT = 10
local R6_LEG_HEIGHT = 2
local END_ON_DEATH = true -- dead players stop triggering and get HitEnd for everything they touch

local DEBUG_SHOW_HITBOXES = false
local DEBUG_FOLDER_NAME = "DebugHitboxes"

-- // Local //

local PlayerStates: {[Player]: PlayerState} = {}
local TrackedPlayers: {[Player]: boolean} = {}
local DisabledPlayers: {[Player]: boolean} = {} -- kept across respawns
local Interactions: {[string]: InteractModule} = {}

local QueryParams = OverlapParams.new()
QueryParams.FilterType = Enum.RaycastFilterType.Include

local filterDirty = true
local initialized = false
local debugFolder: Folder? = nil

-- // Functions //

-- Only tagged parts are ever queried, so the check costs the same however busy the map is
local function rebuildFilter()
	filterDirty = false

	local parts = {}
	for _, instance in CollectionService:GetTagged(INTERACTABLE_TAG) do
		if instance:IsA("BasePart") then
			table.insert(parts, instance)
		end
	end
	QueryParams.FilterDescendantsInstances = parts
end

local function markFilterDirty()
	filterDirty = true
end

-- Bottom of the box sits on the floor, so its height doesn't depend on avatar scale
local function getHitboxCFrame(state: PlayerState): CFrame
	local root = state.RootPart
	local humanoid = state.Humanoid
	local legHeight = if humanoid.RigType == Enum.HumanoidRigType.R6 then R6_LEG_HEIGHT else humanoid.HipHeight
	local floorOffset = root.Size.Y / 2 + legHeight

	return root.CFrame * CFrame.new(0, HITBOX_SIZE.Y / 2 - floorOffset, 0)
end

local function getInteractionNames(part: BasePart): {string}
	local names = {}
	for _, tag in part:GetTags() do
		if Interactions[tag] then
			table.insert(names, tag)
		end
	end
	return names
end

local function queueCalls(pending: {PendingCall}, method: "Hit" | "HitEnd", player: Player, part: BasePart, names: {string})
	for _, name in names do
		table.insert(pending, {
			Method = method,
			Name = name,
			Player = player,
			Part = part,
		})
	end
end

-- Calls run only after all state changes are done, so a handler that re-enters this module
-- (or respawns the player) can never modify PlayerStates while it is being iterated
local function dispatch(pending: {PendingCall})
	for _, call in pending do
		local module = Interactions[call.Name] :: any
		local method = module and module[call.Method]
		if type(method) == "function" then
			task.spawn(method, module, call.Player, call.Part)
		end
	end
end

local function endAllTouching(player: Player, state: PlayerState, pending: {PendingCall})
	local touching = state.Touching
	state.Touching = {}
	for part, names in touching do
		queueCalls(pending, "HitEnd", player, part, names)
	end
end

local function removeState(player: Player)
	local state = PlayerStates[player]
	if not state then return end
	PlayerStates[player] = nil

	if state.DebugPart then
		state.DebugPart:Destroy()
	end

	local pending = {}
	endAllTouching(player, state, pending)
	dispatch(pending)
end

local function updateState(player: Player, state: PlayerState, pending: {PendingCall})
	local dead = END_ON_DEATH and state.Humanoid.Health <= 0
	if DisabledPlayers[player] or dead or not state.RootPart:IsDescendantOf(workspace) then
		endAllTouching(player, state, pending)
		return
	end

	local hitboxCFrame = getHitboxCFrame(state)
	if state.DebugPart then
		state.DebugPart.CFrame = hitboxCFrame
	end

	local previous = state.Touching
	local current: {[BasePart]: {string}} = {}

	for _, part in workspace:GetPartBoundsInBox(hitboxCFrame, HITBOX_SIZE, QueryParams) do
		-- The filter is rebuilt at most once per update, so it can still hold a part that just lost its tag
		if not part:HasTag(INTERACTABLE_TAG) then continue end

		local names = previous[part]
		if names then
			previous[part] = nil
		else
			names = getInteractionNames(part)
			queueCalls(pending, "Hit", player, part, names)
		end
		current[part] = names
	end

	-- Whatever is left was touched last update but not this one
	for part, names in previous do
		queueCalls(pending, "HitEnd", player, part, names)
	end

	state.Touching = current
end

local function step()
	if filterDirty then
		rebuildFilter()
	end

	local pending = {}
	for player, state in PlayerStates do
		updateState(player, state, pending)
	end
	dispatch(pending)
end

local function createDebugPart(player: Player): Part?
	if not debugFolder then return nil end

	local part = Instance.new("Part")
	part.Name = player.Name
	part.Size = HITBOX_SIZE
	part.Color = Color3.fromRGB(255, 0, 0)
	part.Material = Enum.Material.Neon
	part.Transparency = 0.7
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Parent = debugFolder
	return part
end

local function characterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", CHARACTER_LOAD_TIMEOUT)
	local rootPart = character:WaitForChild("HumanoidRootPart", CHARACTER_LOAD_TIMEOUT)

	-- Respawned again or left while waiting: this character is no longer the one to track
	if player.Character ~= character or not TrackedPlayers[player] then return end

	if not (humanoid and humanoid:IsA("Humanoid") and rootPart and rootPart:IsA("BasePart")) then
		warn(`[PlayerHitboxService]: {player.Name}'s character has no Humanoid / HumanoidRootPart, no hitbox created`)
		return
	end

	-- Ends anything still left over from a previous character before replacing its state
	removeState(player)

	PlayerStates[player] = {
		Character = character,
		RootPart = rootPart,
		Humanoid = humanoid,
		Touching = {},
		DebugPart = createDebugPart(player),
	}
end

local function characterRemoving(player: Player, character: Model)
	local state = PlayerStates[player]
	-- Guarded so a late CharacterRemoving for an old character can't remove the new one's state
	if state and state.Character == character then
		removeState(player)
	end
end

local function playerAdded(player: Player)
	-- PlayerAdded and the Init loop can both reach a player who joined right around Init
	if TrackedPlayers[player] then return end
	TrackedPlayers[player] = true

	ConnectionHelper:AddPlayerConnections(player, script.Name, {
		player.CharacterAdded:Connect(function(character)
			characterAdded(player, character)
		end),
		player.CharacterRemoving:Connect(function(character)
			characterRemoving(player, character)
		end),
	})

	if player.Character then
		task.spawn(characterAdded, player, player.Character)
	end
end

local function playerRemoving(player: Player)
	TrackedPlayers[player] = nil
	DisabledPlayers[player] = nil
	removeState(player)
end

local function validateInteraction(name: string, module: any): boolean
	if type(module) ~= "table" then
		warn(`[PlayerHitboxService]: Interaction "{name}" must return a table`)
		return false
	end
	if type(module.Hit) ~= "function" and type(module.HitEnd) ~= "function" then
		warn(`[PlayerHitboxService]: Interaction "{name}" has neither Hit nor HitEnd`)
		return false
	end
	return true
end

local function loadInteractionModules()
	for _, child in script:GetChildren() do
		if not child:IsA("ModuleScript") then continue end

		local success, result = pcall(require, child)
		if not success then
			warn(`[PlayerHitboxService]: Failed to require interaction "{child.Name}" - {result}`)
			continue
		end

		if validateInteraction(child.Name, result) then
			Interactions[child.Name] = result
		end
	end
end

-- // Module //

local PlayerHitboxService = {}

function PlayerHitboxService:Init()
	if initialized then return end
	initialized = true

	-- Loaded before any player is tracked so the very first update already knows every interaction
	loadInteractionModules()

	CollectionService:GetInstanceAddedSignal(INTERACTABLE_TAG):Connect(markFilterDirty)
	CollectionService:GetInstanceRemovedSignal(INTERACTABLE_TAG):Connect(markFilterDirty)

	if DEBUG_SHOW_HITBOXES then
		local folder = Instance.new("Folder")
		folder.Name = DEBUG_FOLDER_NAME
		folder.Parent = workspace
		debugFolder = folder
	end

	Players.PlayerAdded:Connect(playerAdded)
	Players.PlayerRemoving:Connect(playerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(playerAdded, player)
	end

	local elapsed = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed < UPDATE_INTERVAL then return end
		elapsed = 0 -- reset instead of subtracting so a lag spike doesn't cause a burst of catch-up updates
		step()
	end)
end

-- Adds or replaces an interaction from code instead of a child ModuleScript.
-- Parts already being touched send their HitEnd to whatever module is registered under the name at that time.
function PlayerHitboxService:RegisterInteraction(name: string, module: InteractModule)
	if not validateInteraction(name, module) then return end
	if Interactions[name] then
		warn(`[PlayerHitboxService]: Replacing interaction "{name}"`)
	end
	Interactions[name] = module
end

-- Stops (or resumes) hit detection for a player, e.g. during cutscenes. Kept across respawns.
-- Disabling sends HitEnd for everything they are touching straight away.
function PlayerHitboxService:SetEnabled(player: Player, enabled: boolean)
	DisabledPlayers[player] = if enabled then nil else true

	local state = PlayerStates[player]
	if not enabled and state then
		local pending = {}
		endAllTouching(player, state, pending)
		dispatch(pending)
	end
end

function PlayerHitboxService:IsEnabled(player: Player): boolean
	return not DisabledPlayers[player]
end

function PlayerHitboxService:IsTouching(player: Player, part: BasePart): boolean
	local state = PlayerStates[player]
	return state ~= nil and state.Touching[part] ~= nil
end

function PlayerHitboxService:GetTouching(player: Player): {BasePart}
	local parts = {}
	local state = PlayerStates[player]
	if state then
		for part in state.Touching do
			table.insert(parts, part)
		end
	end
	return parts
end

-- Where the player's hitbox currently is (nil if they have no tracked character)
function PlayerHitboxService:GetHitboxCFrame(player: Player): (CFrame?, Vector3)
	local state = PlayerStates[player]
	return (if state then getHitboxCFrame(state) else nil), HITBOX_SIZE
end

return PlayerHitboxService
