-- AnimationManagerServer.lua  (Script – ServerScriptService)

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SyncRemotes    = ReplicatedStorage:WaitForChild("SyncRemotes", 30)
local DuoAnimRequest = SyncRemotes:WaitForChild("DuoAnimRequest",   30)
local StartDuoAnim   = SyncRemotes:WaitForChild("StartDuoAnim",     30)
local StopDuoAnim    = SyncRemotes:WaitForChild("StopDuoAnim",      30)
local GetSyncPartner = SyncRemotes:WaitForChild("GetSyncPartner",   30)

local function getOrMake(parent, cls, name)
	local e = parent:FindFirstChild(name)
	if e then return e end
	local i = Instance.new(cls); i.Name = name; i.Parent = parent; return i
end

local DuoAnimTick      = getOrMake(SyncRemotes, "RemoteEvent", "DuoAnimTick")
local DuoAnimReplicate = getOrMake(SyncRemotes, "RemoteEvent", "DuoAnimReplicate")
local SyncSpeed        = getOrMake(SyncRemotes, "RemoteEvent", "SyncSpeed")
local SetPartnerSpeed  = getOrMake(SyncRemotes, "RemoteEvent", "SetPartnerSpeed")

local SeatTemplate = ServerStorage:WaitForChild("SeatTemplate", 30)

-- ── Seat spawn offset (in Dom's local space) ──────────────────────────────────
--   X : right/left     (+right,   -left)
--   Y : up/down        (+up,      -down)
--   Z : forward/back   (-forward, +back)
local SEAT_OFFSET_X = 0
local SEAT_OFFSET_Y = 0
local SEAT_OFFSET_Z = 0

local sessions = {}

local function getTorso(p)
	return p.Character and
		(p.Character:FindFirstChild("UpperTorso") or p.Character:FindFirstChild("Torso"))
end

local function getHumanoid(p)
	return p.Character and p.Character:FindFirstChildWhichIsA("Humanoid")
end

local function getHRP(p)
	return p.Character and p.Character:FindFirstChild("HumanoidRootPart")
end

local function getPartnerInSession(p)
	local s = sessions[p.UserId]; if not s then return nil end
	return s.domPlayer == p and s.subPlayer or s.domPlayer
end

local function placeModel(model, anchor, targetCF)
	local delta = targetCF * anchor.CFrame:Inverse()
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then part.CFrame = delta * part.CFrame end
	end
end

local function cleanupSession(userId)
	local s = sessions[userId]; if not s then return end
	sessions[s.domPlayer.UserId] = nil
	sessions[s.subPlayer.UserId] = nil

	for _, p in ipairs({ s.domPlayer, s.subPlayer }) do
		local hum = getHumanoid(p)
		if hum then hum.Sit = false end
	end

	task.delay(0.5, function()
		if s.seatModel and s.seatModel.Parent then s.seatModel:Destroy() end
	end)

	StopDuoAnim:FireClient(s.domPlayer)
	StopDuoAnim:FireClient(s.subPlayer)
end

DuoAnimRequest.OnServerEvent:Connect(function(initiator, category, animName)
	if animName == "" then
		if sessions[initiator.UserId] then cleanupSession(initiator.UserId) end
		return
	end

	if category ~= "Dom" and category ~= "Sub" then return end

	if sessions[initiator.UserId] then
		local s            = sessions[initiator.UserId]
		local newDomPlayer = (category == "Dom") and initiator or
			(s.domPlayer == initiator and s.subPlayer or s.domPlayer)
		local newSubPlayer = (category == "Dom") and
			(s.domPlayer == initiator and s.subPlayer or s.domPlayer) or initiator

		StopDuoAnim:FireClient(s.domPlayer)
		StopDuoAnim:FireClient(s.subPlayer)
		StartDuoAnim:FireClient(newDomPlayer, "Dom", animName, newSubPlayer.UserId)
		StartDuoAnim:FireClient(newSubPlayer, "Sub", animName, newDomPlayer.UserId)
		return
	end

	local partner = GetSyncPartner:Invoke(initiator)
	if not partner then return end

	local domPlayer = category == "Dom" and initiator or partner
	local subPlayer = category == "Dom" and partner   or initiator

	local domTorso = getTorso(domPlayer)
	if not domTorso or not SeatTemplate then return end

	local torsoCF  = domTorso.CFrame
	local lookFlat = Vector3.new(torsoCF.LookVector.X, 0, torsoCF.LookVector.Z)
	if lookFlat.Magnitude < 0.01 then lookFlat = Vector3.new(0, 0, -1) end
	local spawnCF = CFrame.lookAt(torsoCF.Position, torsoCF.Position + lookFlat.Unit)
		* CFrame.new(SEAT_OFFSET_X, SEAT_OFFSET_Y, SEAT_OFFSET_Z)

	local seatModel  = SeatTemplate:Clone()
	seatModel.Parent = workspace
	local anchor     = seatModel.PrimaryPart or seatModel:FindFirstChildWhichIsA("BasePart", true)
	if anchor then placeModel(seatModel, anchor, spawnCF) end

	local domSeat = seatModel:FindFirstChild("Dom", true)
	local subSeat = seatModel:FindFirstChild("Sub", true)
	if not domSeat or not domSeat:IsA("Seat") then
		warn("[AnimMgrServer] SeatTemplate missing Seat named 'Dom'"); return
	end
	if not subSeat or not subSeat:IsA("Seat") then
		warn("[AnimMgrServer] SeatTemplate missing Seat named 'Sub'"); return
	end

	local session = { seatModel=seatModel, domPlayer=domPlayer, subPlayer=subPlayer }
	sessions[domPlayer.UserId] = session
	sessions[subPlayer.UserId] = session

	local domHRP = getHRP(domPlayer)
	local subHRP = getHRP(subPlayer)
	if domHRP then domHRP.CFrame = domSeat.CFrame end
	if subHRP then subHRP.CFrame = subSeat.CFrame end

	task.wait(0.3)
	if sessions[domPlayer.UserId] ~= session then return end

	local domHum = getHumanoid(domPlayer)
	if domHum then domSeat:Sit(domHum) end

	task.wait(0.3)
	if sessions[domPlayer.UserId] ~= session then return end

	local subHum = getHumanoid(subPlayer)
	if subHum then subSeat:Sit(subHum) end

	task.wait(0.3)
	if sessions[domPlayer.UserId] ~= session then return end

	StartDuoAnim:FireClient(domPlayer, "Dom", animName, subPlayer.UserId)
	StartDuoAnim:FireClient(subPlayer, "Sub", animName, domPlayer.UserId)
end)

DuoAnimTick.OnServerEvent:Connect(function(sender, elapsed)
	local partner = getPartnerInSession(sender); if not partner then return end
	DuoAnimReplicate:FireClient(partner, sender.UserId, elapsed)
end)

SyncSpeed.OnServerEvent:Connect(function(sender, speed)
	local partner = getPartnerInSession(sender); if not partner then return end
	SetPartnerSpeed:FireClient(partner, speed)
end)

Players.PlayerRemoving:Connect(function(p)
	if sessions[p.UserId] then cleanupSession(p.UserId) end
end)

Players.PlayerAdded:Connect(function(p)
	p.CharacterRemoving:Connect(function()
		if sessions[p.UserId] then cleanupSession(p.UserId) end
	end)
end)
for _, p in ipairs(Players:GetPlayers()) do
	p.CharacterRemoving:Connect(function()
		if sessions[p.UserId] then cleanupSession(p.UserId) end
	end)
end
