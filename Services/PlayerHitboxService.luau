-- // About //
-- Made By: JackaBoi
-- Last Updated: 3/19/2026
-- Check Libs for Required Libraries
--
-- Made to Add a Hitbox to each player that is less exploitable
-- than .Touched and Small Avatars.
-- Allows you to add tags to parts and a reusable Module Script that will
-- execute logic for said part.
--
-- // Example Interact Module //
-- Must be placed under this ModuleScript!
-- Must have same name as the Tag on Part!
-- Part must also have Interactable tag!
--
-- local QueueUp = {}
--
-- function QueueUp:Hit(player: Player, hitPart: Part)
-- 	QueueService:AttemptAddPlayer(player, hitPart)
-- end
--
-- function QueueUp:HitEnd(player: Player, hitPart: Part)
-- 	QueueService:RemovePlayer(player, hitPart)
-- end
--
-- return QueueUp

-- // Services //

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

-- // Libs //

local ConnectionHelper = require(ServerScriptService.Libraries.ConnectionHelper)

-- // Local //

type HitBoxState = {
	HitBox: Part,
	TouchingState: {[Part]: boolean}
}
local AllHitBoxes: {[Instance]: HitBoxState} = {}

local InteractModules: {[string]: any} = {}

local HitBox = Instance.new("Part")
HitBox.Name = "HitBox"
HitBox.Size = Vector3.new(2.5,5.5,1.25)
HitBox.BrickColor = BrickColor.Red()
HitBox.Material = Enum.Material.Neon
HitBox.Transparency = 1
HitBox.CanCollide = false
HitBox:AddTag("HitBox")

-- // Functions //

local function setupCollisionGroup(character)
	
	for _,descendant in character:GetDescendants() do
		if not descendant:IsA("BasePart") then continue end 
		descendant.CollisionGroup = "Players"
	end
	
end

local function updateHitBox(player)
	
	local hitboxState = AllHitBoxes[player]
	
	if not hitboxState or not hitboxState.HitBox or not hitboxState.HitBox.Parent then
		AllHitBoxes[player] = nil 
		return
	end
	
	local partsToCheck = workspace:GetPartBoundsInBox(hitboxState.HitBox.CFrame, hitboxState.HitBox.Size)
	
	local currentlyTouching: {[Part]: boolean} = {}
	
	for _,hitPart in ipairs(partsToCheck) do
		if not hitPart:HasTag("Interactable") then continue end
		currentlyTouching[hitPart] = true
		if hitboxState.TouchingState[hitPart] then 
			hitboxState.TouchingState[hitPart] = nil
			continue
		end
		print("Hit")
		for moduleName,module in InteractModules do
			if not hitPart:HasTag(moduleName) then continue end
			if not player:IsA("Player") then continue end
			module:Hit(player, hitPart)
		end
	end
	
	for part,_ in pairs(hitboxState.TouchingState) do
		print("HitEnd")
		for moduleName,module in InteractModules do
			if not part:HasTag(moduleName) then continue end
			if not player:IsA("Player") then continue end
			module:HitEnd(player, part)
		end
	end
	
	hitboxState.TouchingState = currentlyTouching
end

local function setupHitBox(player: Player, character)
	
	local humanoid: Humanoid = character:WaitForChild("Humanoid")
	local hRootPart = humanoid.RootPart
	
	local pHitbox = HitBox:Clone()
	pHitbox.Parent = character
	
	local weld = Instance.new("Weld")
	weld.Name = "HitBoxWeld"
	weld.C0 = CFrame.new(0,hRootPart.Size.Y-humanoid.HipHeight-0.5,0)
	weld.C1 = pHitbox.CFrame
	weld.Part0 = hRootPart
	weld.Part1 = pHitbox
	weld.Parent = pHitbox
	
	-- Dictionary for faster lookup
	AllHitBoxes[player] = {HitBox = pHitbox, TouchingState = {}}
	
end

local function testHitbox()
	
	local hRootPart = Instance.new("Part")
	hRootPart.CFrame = CFrame.new(0,50,0)
	hRootPart.Parent = workspace
	local pHitbox = HitBox:Clone()
	pHitbox.Transparency = 0.6
	pHitbox.Parent = hRootPart
	
	local weld = Instance.new("Weld")
	weld.Name = "HitBoxWeld"
	weld.C0 = CFrame.new(0,hRootPart.Size.Y-1.738,0)
	weld.C1 = pHitbox.CFrame
	weld.Part0 = hRootPart
	weld.Part1 = pHitbox
	weld.Parent = pHitbox
	
	AllHitBoxes[hRootPart] = {HitBox = pHitbox, TouchingState = {}}
	
end

local function playerAdded(player: Player)
	
	local charAdded = player.CharacterAdded:Connect(function(character)
		repeat task.wait() until player.CharacterAppearanceLoaded
		
		--task.spawn(setupCollisionGroup,character)
		setupHitBox(player, character)
	end)
	
	local charRemoved = player.CharacterRemoving:Connect(function(character)
		AllHitBoxes[player] = nil
	end)
	
	ConnectionHelper:AddPlayerConnections(player, script.Name, {charAdded, charRemoved})
	
end

-- // Module //

local PlayerHitboxService = {}

function PlayerHitboxService:Init()
	
	Players.PlayerAdded:Connect(playerAdded)
	
	if not workspace:FindFirstChild("Ragdolls") then
		local ragFolder = Instance.new("Folder")
		ragFolder.Name = "Ragdolls"
		ragFolder.Parent = workspace
	end
	
	for _,player in Players:GetPlayers() do
		task.spawn(playerAdded,player)
	end
	
	for _,module in script:GetChildren() do
		InteractModules[module.Name] = require(module)
	end
	
	--task.spawn(function()
		
	--	--Intentional to simulate the lag of more players
		
	--	for i=1,100 do
	--		testHitbox()
	--	end
		
	--end)
	
	task.spawn(function()
		while true do
			for player,_ in pairs(AllHitBoxes) do
				updateHitBox(player)
			end
			task.wait(0.05)
		end
	end)
	
end

return PlayerHitboxService