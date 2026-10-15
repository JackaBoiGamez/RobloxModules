--!strict

-- // About //
-- Made By: JackaBoi
-- Last Updated: 10/14/2026
--
-- Teleports groups of players with retries and error handling.
-- - TeleportAsync errors (throws) are retried with backoff for the whole batch.
-- - TeleportInitFailed (fires per player after TeleportAsync accepted the request) is retried
--   per player with the same TeleportOptions, so retried players still land in the same reserved server.
-- - Players are sent in batches of up to MAX_PLAYERS_PER_CALL (TeleportAsync's limit).
-- - :ReserveServer lets a caller reserve the destination early (e.g. during a countdown) so the
--   teleport itself starts instantly.
--
-- Seamless teleports: a loading screen can only be set from the client. Fire-and-forget status
-- updates go to clients through ReplicatedStorage.TeleportStatus ("Starting", placeId) / ("Failed", reason).
--
-- Example LocalScript (StarterPlayerScripts), ReplicatedStorage.TeleportLoadingScreen is a ScreenGui:
--
-- local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- local TeleportService = game:GetService("TeleportService")
-- local Players = game:GetService("Players")
--
-- local loadingScreen = ReplicatedStorage:WaitForChild("TeleportLoadingScreen"):Clone()
-- loadingScreen.Enabled = false
-- loadingScreen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
-- TeleportService:SetTeleportGui(loadingScreen) -- shown during the teleport and passed to the destination
--
-- ReplicatedStorage:WaitForChild("TeleportStatus").OnClientEvent:Connect(function(status)
-- 	loadingScreen.Enabled = status == "Starting"
-- end)
--
-- Destination place LocalScript (ReplicatedFirst), keeps the same screen up while the new place loads:
--
-- local ReplicatedFirst = game:GetService("ReplicatedFirst")
-- local TeleportService = game:GetService("TeleportService")
-- local Players = game:GetService("Players")
--
-- local arrivingGui = TeleportService:GetArrivingTeleportGui()
-- if arrivingGui then
-- 	arrivingGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
-- 	ReplicatedFirst:RemoveDefaultLoadingScreen()
-- 	if not game:IsLoaded() then game.Loaded:Wait() end
-- 	arrivingGui:Destroy()
-- end

-- // Types //

export type TeleportSettings = {
	Reserved: boolean?, -- send the group to a new private server together
	AccessCode: string?, -- a server already reserved with :ReserveServer (implies Reserved)
	TeleportData: any?, -- readable on arrival via player:GetJoinData().TeleportData (client can spoof it)
	OnFailed: ((player: Player, reason: string) -> ())?, -- called once per player that could not be teleported
}

type PendingTeleport = {
	PlaceId: number,
	Options: TeleportOptions,
	Attempts: number,
	OnFailed: ((player: Player, reason: string) -> ())?,
}

-- // Services //

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

-- // Config //

local MAX_PLAYERS_PER_CALL = 50
local MAX_ATTEMPTS = 3 -- per batch for TeleportAsync errors, and per player for TeleportInitFailed
local RETRY_DELAY = 2 -- seconds, multiplied by the attempt number
local FLOOD_DELAY = 15 -- seconds to back off when Roblox reports Flooded
local PENDING_TIMEOUT = 45 -- seconds before a teleport that never completed or failed is treated as failed
local REMOTE_NAME = "TeleportStatus"

local RETRYABLE_RESULTS = {
	[Enum.TeleportResult.Failure] = true,
	[Enum.TeleportResult.Flooded] = true,
}

-- // Local //

local PendingTeleports: {[Player]: PendingTeleport} = {}
local statusRemote: RemoteEvent? = nil
local initialized = false

-- // Functions //

local function fireStatus(player: Player, status: string, info: any)
	if statusRemote and player.Parent == Players then
		statusRemote:FireClient(player, status, info)
	end
end

-- Pending is cleared BEFORE OnFailed runs, so the callback already sees :IsTeleporting(player) == false
local function failPlayer(player: Player, pending: PendingTeleport, reason: string)
	if PendingTeleports[player] ~= pending then return end
	PendingTeleports[player] = nil

	warn(`[PlayerTeleportService]: Teleport failed for {player.Name} - {reason}`)
	fireStatus(player, "Failed", reason)

	if pending.OnFailed then
		task.spawn(pending.OnFailed, player, reason)
	end
end

local function retryPlayer(player: Player, pending: PendingTeleport, result: Enum.TeleportResult, errorMessage: string)
	if PendingTeleports[player] ~= pending then return end

	if not RETRYABLE_RESULTS[result] or pending.Attempts >= MAX_ATTEMPTS then
		failPlayer(player, pending, `{result.Name}: {errorMessage}`)
		return
	end

	pending.Attempts += 1
	local delay = if result == Enum.TeleportResult.Flooded then FLOOD_DELAY else RETRY_DELAY * pending.Attempts

	task.delay(delay, function()
		-- Left (teleported), or a newer teleport replaced this one, while waiting
		if PendingTeleports[player] ~= pending or player.Parent ~= Players then return end

		local success, err = pcall(TeleportService.TeleportAsync, TeleportService, pending.PlaceId, {player}, pending.Options)
		if not success then
			retryPlayer(player, pending, Enum.TeleportResult.Failure, tostring(err))
		end
	end)
end

local function onTeleportInitFailed(player: Player, result: Enum.TeleportResult, errorMessage: string)
	local pending = PendingTeleports[player]
	if not pending then return end -- not a teleport this module started

	-- A teleport is already underway for this player; the original one is still running
	if result == Enum.TeleportResult.IsTeleporting then return end

	retryPlayer(player, pending, result, errorMessage)
end

local function onPlayerRemoving(player: Player)
	-- Leaving while pending is almost always the teleport succeeding
	PendingTeleports[player] = nil
end

local function reserveServer(placeId: number): string?
	for attempt = 1, MAX_ATTEMPTS do
		local success, result = pcall(TeleportService.ReserveServer, TeleportService, placeId)
		if success then
			return result
		end

		warn(`[PlayerTeleportService]: ReserveServer({placeId}) attempt {attempt} failed - {result}`)
		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_DELAY * attempt)
		end
	end
	return nil
end

-- Returns true if Roblox accepted the request for this batch. Players dropped from it are failed here.
local function teleportBatch(batch: {Player}, placeId: number, options: TeleportOptions): boolean
	local lastError = "unknown error"

	for attempt = 1, MAX_ATTEMPTS do
		-- Rebuilt each attempt: players may have left or been failed meanwhile
		local stillPending = {}
		for _, player in batch do
			local pending = PendingTeleports[player]
			if pending and pending.Options == options and player.Parent == Players then
				table.insert(stillPending, player)
			end
		end
		if #stillPending == 0 then return false end

		local success, err = pcall(TeleportService.TeleportAsync, TeleportService, placeId, stillPending, options)
		if success then
			return true
		end

		lastError = tostring(err)
		warn(`[PlayerTeleportService]: TeleportAsync attempt {attempt} to {placeId} failed - {lastError}`)
		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	for _, player in batch do
		local pending = PendingTeleports[player]
		if pending and pending.Options == options then
			failPlayer(player, pending, lastError)
		end
	end
	return false
end

-- // Module //

local PlayerTeleportService = {}

function PlayerTeleportService:Init()
	if initialized then return end
	initialized = true

	local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.Parent = ReplicatedStorage
	end
	statusRemote = remote :: RemoteEvent

	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function PlayerTeleportService:IsTeleporting(player: Player): boolean
	return PendingTeleports[player] ~= nil
end

-- Reserves a private server ahead of time. Yields. Each code should be used for ONE group only.
-- Returns nil on failure (always in Studio, where teleports are unavailable).
function PlayerTeleportService:ReserveServer(placeId: number): string?
	if RunService:IsStudio() then return nil end
	return reserveServer(placeId)
end

-- Teleports players to a place. Yields until Roblox has accepted (or finally rejected) the request.
-- Returns true if at least one player's teleport was started. Players that end up not teleporting
-- (after retries) are reported through settings.OnFailed, which can happen after this returns.
function PlayerTeleportService:Teleport(players: {Player}, placeId: number, settings: TeleportSettings?): boolean
	local config: TeleportSettings = settings or {}

	if not initialized then
		self:Init()
	end

	local function failAll(list: {Player}, reason: string)
		warn(`[PlayerTeleportService]: Teleport to {placeId} failed - {reason}`)
		if config.OnFailed then
			for _, player in list do
				task.spawn(config.OnFailed, player, reason)
			end
		end
	end

	-- Players who left, or who are already being teleported, are skipped (not reported as failed)
	local group = {}
	for _, player in players do
		if player.Parent == Players and not PendingTeleports[player] and not table.find(group, player) then
			table.insert(group, player)
		end
	end
	if #group == 0 then return false end

	if RunService:IsStudio() then
		failAll(group, "teleports are not available in Studio")
		return false
	end

	local accessCode = config.AccessCode
	if not accessCode and config.Reserved then
		-- One code for the whole group (and every retry), so nobody ends up in a different server
		accessCode = reserveServer(placeId)
		if not accessCode then
			failAll(group, "could not reserve a server")
			return false
		end
	end

	local options = Instance.new("TeleportOptions")
	if accessCode then
		options.ReservedServerAccessCode = accessCode
	end
	if config.TeleportData ~= nil then
		options:SetTeleportData(config.TeleportData)
	end

	-- Re-checked: reserveServer yields, so players can have left or started another teleport
	local ready = {}
	for _, player in group do
		if player.Parent == Players and not PendingTeleports[player] then
			local pending: PendingTeleport = {
				PlaceId = placeId,
				Options = options,
				Attempts = 1,
				OnFailed = config.OnFailed,
			}
			PendingTeleports[player] = pending
			table.insert(ready, player)
			fireStatus(player, "Starting", placeId)

			task.delay(PENDING_TIMEOUT, failPlayer, player, pending, "timed out")
		end
	end

	local anyStarted = false
	for first = 1, #ready, MAX_PLAYERS_PER_CALL do
		local batch = table.move(ready, first, math.min(first + MAX_PLAYERS_PER_CALL - 1, #ready), 1, {})
		if teleportBatch(batch, placeId, options) then
			anyStarted = true
		end
	end

	return anyStarted
end

return PlayerTeleportService
