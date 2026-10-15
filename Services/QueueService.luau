--!strict

-- // About //
-- Made By: JackaBoi
-- Last Updated: 10/14/2026
-- Requires PlayerTeleportService (see Libs).
--
-- Queue pads: BaseParts tagged "QueueUp". Players join by standing on the pad (PlayerHitboxService
-- calls :AttemptAddPlayer / :RemovePlayer from the QueueUp interaction module) or from code.
--
-- Attributes you set on the pad:
--   PlaceId     number   (required) place the group is teleported to
--   Timer       number   seconds of countdown once enough players are queued (default 15)
--   MinPlayers  number   players needed for the countdown to run (default 1)
--   MaxPlayers  number   queue size; extra players on the pad wait for a free slot (default 8)
--   Reserved    boolean  send each group to its own private server (default true)
--
-- Attributes this service writes on the pad (for UI / BillboardGuis):
--   TimeLeft    number   whole seconds left on the countdown
--   PlayerCount number
--   Status      string   "Waiting" | "Starting" | "Teleporting" | "Disabled" (no valid PlaceId)
--
-- The interaction module for PlayerHitboxService (ModuleScript "QueueUp" under it):
--
-- local QueueService = require(ServerScriptService.Services.QueueService)
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

-- // Types //

export type QueueStatus = "Waiting" | "Starting" | "Teleporting" | "Disabled"

type QueueConfig = {
	PlaceId: number?,
	Timer: number,
	MinPlayers: number,
	MaxPlayers: number,
	Reserved: boolean,
}

type Queue = {
	Part: BasePart,
	Players: {Player}, -- in join order
	Occupants: {[Player]: boolean}, -- standing on the pad, queued or not; used to fill free slots
	Status: QueueStatus,
	EndsAt: number?, -- os.clock() time the countdown ends, nil while not counting down
	Round: number,
	ReservedRound: number?, -- round a reservation was already attempted for, so failures don't retry every tick
	AccessCode: string?, -- preloaded reserved server, unused so far
	AccessPlaceId: number?, -- place the access code belongs to
}

-- // Services //

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- // Libs //

local PlayerTeleportService = require(ServerScriptService.Services.PlayerTeleportService)

-- // Config //

local QUEUE_TAG = "QueueUp"
local TICK_RATE = 0.25
local PRELOAD_AT = 5 -- seconds left when a reserved server is requested ahead of the teleport

local DEFAULT_TIMER = 15
local DEFAULT_MIN_PLAYERS = 1
local DEFAULT_MAX_PLAYERS = 8

-- // Local //

local Queues: {[BasePart]: Queue} = {}
local PlayerQueues: {[Player]: Queue} = {}
local initialized = false

-- // Functions //

local function readNumber(part: BasePart, name: string, default: number): number
	local value = part:GetAttribute(name)
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

-- Read every time it's needed, so pad attributes can be changed while the game runs
local function getConfig(part: BasePart): QueueConfig
	local placeId = part:GetAttribute("PlaceId")
	local reserved = part:GetAttribute("Reserved")

	local minPlayers = math.max(1, math.floor(readNumber(part, "MinPlayers", DEFAULT_MIN_PLAYERS)))
	local maxPlayers = math.max(minPlayers, math.floor(readNumber(part, "MaxPlayers", DEFAULT_MAX_PLAYERS)))

	return {
		PlaceId = if type(placeId) == "number" and placeId > 0 and placeId % 1 == 0 then placeId else nil,
		Timer = math.max(0, readNumber(part, "Timer", DEFAULT_TIMER)),
		MinPlayers = minPlayers,
		MaxPlayers = maxPlayers,
		Reserved = if type(reserved) == "boolean" then reserved else true,
	}
end

local function setStatus(queue: Queue, status: QueueStatus, timeLeft: number)
	queue.Status = status
	queue.Part:SetAttribute("Status", status)
	queue.Part:SetAttribute("TimeLeft", math.ceil(timeLeft))
	queue.Part:SetAttribute("PlayerCount", #queue.Players)
end

local function resetCountdown(queue: Queue)
	queue.EndsAt = nil
	local config = getConfig(queue.Part)
	setStatus(queue, if config.PlaceId then "Waiting" else "Disabled", config.Timer)
end

local function addToQueue(queue: Queue, player: Player): boolean
	if queue.Status == "Teleporting" then return false end
	if player.Parent ~= Players or PlayerQueues[player] then return false end
	if PlayerTeleportService:IsTeleporting(player) then return false end
	if #queue.Players >= getConfig(queue.Part).MaxPlayers then return false end

	table.insert(queue.Players, player)
	PlayerQueues[player] = queue
	queue.Part:SetAttribute("PlayerCount", #queue.Players)
	return true
end

-- Gives free slots to players already standing on the pad (in no particular order)
local function fillFromOccupants(queue: Queue)
	for player in queue.Occupants do
		if not PlayerQueues[player] then
			addToQueue(queue, player)
		end
	end
end

local function removeFromQueue(queue: Queue, player: Player)
	if PlayerQueues[player] ~= queue then return end
	PlayerQueues[player] = nil

	local index = table.find(queue.Players, player)
	if index then
		table.remove(queue.Players, index)
	end
	queue.Part:SetAttribute("PlayerCount", #queue.Players)

	fillFromOccupants(queue)
end

local function onTeleportFailed(queue: Queue, player: Player)
	-- Put them back if they are still on this pad and the pad still exists
	if Queues[queue.Part] == queue and queue.Occupants[player] then
		addToQueue(queue, player)
	end
end

local function launch(queue: Queue, config: QueueConfig)
	local placeId = config.PlaceId
	if not placeId then return end

	-- Everything up to the Teleport call runs before the first yield, so the tick loop sees the
	-- queue as "Teleporting" (and empty) immediately
	local group = queue.Players
	queue.Players = {}
	for _, player in group do
		PlayerQueues[player] = nil
	end
	queue.EndsAt = nil
	setStatus(queue, "Teleporting", 0)

	local accessCode: string? = nil
	if config.Reserved and queue.AccessPlaceId == placeId then
		accessCode = queue.AccessCode
		queue.AccessCode = nil
		queue.AccessPlaceId = nil
	end

	PlayerTeleportService:Teleport(group, placeId, {
		Reserved = config.Reserved,
		AccessCode = accessCode,
		OnFailed = function(player: Player)
			onTeleportFailed(queue, player)
		end,
	})

	-- The pad may have been removed while the teleport request was yielding
	if Queues[queue.Part] ~= queue then return end

	resetCountdown(queue)
	-- Players still on the pad who weren't in this group (or whose teleport already failed) get the next round
	fillFromOccupants(queue)
end

-- Reserves the destination while the countdown is still running, so the teleport starts instantly.
-- An unused code is kept for the next round as long as PlaceId doesn't change.
local function preloadServer(queue: Queue, placeId: number)
	queue.ReservedRound = queue.Round

	task.spawn(function()
		local accessCode = PlayerTeleportService:ReserveServer(placeId)
		if accessCode and Queues[queue.Part] == queue and not queue.AccessCode then
			queue.AccessCode = accessCode
			queue.AccessPlaceId = placeId
		end
	end)
end

local function tickQueue(queue: Queue, now: number)
	if queue.Status == "Teleporting" then return end

	-- Catches every way a slot can open for someone already on the pad: MaxPlayers raised, they left
	-- another queue, or their teleport failed while this queue was busy
	fillFromOccupants(queue)

	local config = getConfig(queue.Part)
	local placeId = config.PlaceId

	if not placeId or #queue.Players < config.MinPlayers then
		local idleStatus: QueueStatus = if placeId then "Waiting" else "Disabled"
		local timerChanged = queue.Part:GetAttribute("TimeLeft") ~= math.ceil(config.Timer)
		if queue.EndsAt or queue.Status ~= idleStatus or timerChanged then
			resetCountdown(queue)
		end
		return
	end

	if not queue.EndsAt then
		queue.Round += 1
		queue.EndsAt = now + config.Timer
	end

	local endsAt = queue.EndsAt :: number
	local timeLeft = math.max(0, endsAt - now)
	if queue.Status ~= "Starting" or queue.Part:GetAttribute("TimeLeft") ~= math.ceil(timeLeft) then
		setStatus(queue, "Starting", timeLeft)
	end

	local hasCode = queue.AccessCode ~= nil and queue.AccessPlaceId == placeId
	if config.Reserved and timeLeft <= PRELOAD_AT and not hasCode and queue.ReservedRound ~= queue.Round then
		preloadServer(queue, placeId)
	end

	if timeLeft <= 0 then
		task.spawn(launch, queue, config)
	end
end

local function addQueue(instance: Instance)
	if not instance:IsA("BasePart") then
		warn(`[QueueService]: "{instance:GetFullName()}" is tagged {QUEUE_TAG} but is not a BasePart`)
		return
	end
	if Queues[instance] then return end

	local queue: Queue = {
		Part = instance,
		Players = {},
		Occupants = {},
		Status = "Waiting",
		EndsAt = nil,
		Round = 0,
		ReservedRound = nil,
		AccessCode = nil,
		AccessPlaceId = nil,
	}
	Queues[instance] = queue
	resetCountdown(queue)

	if not getConfig(instance).PlaceId then
		warn(`[QueueService]: "{instance:GetFullName()}" has no valid PlaceId attribute`)
	end
end

local function removeQueue(instance: Instance)
	local queue = Queues[instance :: BasePart]
	if not queue then return end
	Queues[instance :: BasePart] = nil

	for _, player in queue.Players do
		PlayerQueues[player] = nil
	end
	table.clear(queue.Players)
	table.clear(queue.Occupants)
end

local function playerRemoving(player: Player)
	local queue = PlayerQueues[player]
	for _, otherQueue in Queues do
		otherQueue.Occupants[player] = nil
	end
	if queue then
		removeFromQueue(queue, player)
	end
end

-- // Module //

local QueueService = {}

function QueueService:Init()
	if initialized then return end
	initialized = true

	PlayerTeleportService:Init()

	CollectionService:GetInstanceAddedSignal(QUEUE_TAG):Connect(addQueue)
	CollectionService:GetInstanceRemovedSignal(QUEUE_TAG):Connect(removeQueue)
	for _, instance in CollectionService:GetTagged(QUEUE_TAG) do
		addQueue(instance)
	end

	Players.PlayerRemoving:Connect(playerRemoving)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed < TICK_RATE then return end
		elapsed = 0

		-- Countdowns use os.clock, so tick timing only affects how often attributes update
		local now = os.clock()
		for _, queue in Queues do
			tickQueue(queue, now)
		end
	end)
end

-- Called when a player steps onto a pad (or from code). The player stays registered as standing on
-- the pad even if the queue is full or teleporting, and is added automatically when a slot frees up.
-- Returns true if they are now in the queue.
function QueueService:AttemptAddPlayer(player: Player, part: BasePart): boolean
	local queue = Queues[part]
	if not queue then
		warn(`[QueueService]: "{part:GetFullName()}" is not a queue (missing {QUEUE_TAG} tag?)`)
		return false
	end
	if player.Parent ~= Players then return false end

	queue.Occupants[player] = true
	return addToQueue(queue, player)
end

-- Called when a player steps off a pad. Without a part, removes them from whatever queue they are in
-- (e.g. a "Leave" button); they then have to step off and back on to rejoin that pad.
function QueueService:RemovePlayer(player: Player, part: BasePart?)
	local queue = if part then Queues[part] else PlayerQueues[player]
	if not queue then return end

	queue.Occupants[player] = nil
	removeFromQueue(queue, player)
end

function QueueService:GetPlayerQueue(player: Player): BasePart?
	local queue = PlayerQueues[player]
	return if queue then queue.Part else nil
end

function QueueService:GetPlayers(part: BasePart): {Player}
	local queue = Queues[part]
	return if queue then table.clone(queue.Players) else {}
end

return QueueService
