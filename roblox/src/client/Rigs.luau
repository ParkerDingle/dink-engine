--!nonstrict
-- Player visuals on the client: AI rigs (cloned from ReplicatedStorage.DinkRigs, moved from the
-- server's pose stream and animated locally) and procedural paddle swings for every player, human
-- or AI, layered over the body animation by overriding the shoulder and waist joints.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local C = require(ReplicatedStorage:WaitForChild("Dink"):WaitForChild("Config"))

local Rigs = {}

type Pose = { x: number, z: number, vx: number, vz: number, rot: number, at: number }
type Rig = {
	model: Model, root: BasePart, hum: Humanoid?, tracks: { [string]: AnimationTrack },
	x: number, z: number, yaw: number, height: number,
}
type Swing = { kind: number, t: number }

local DEFAULT_ANIMS = { idle = "rbxassetid://507766388", walk = "rbxassetid://913402848", run = "rbxassetid://913376220" }

-- shoulder (pitch, yaw, roll) and waist yaw at the start and end of each swing
local SWINGS: { [number]: { a: { number }, b: { number }, wa: number, wb: number } } = {
	[1] = { a = { -0.5, 0, 0.9 }, b = { 1.4, 0, -0.4 }, wa = -0.5, wb = 0.4 },  -- forehand
	[2] = { a = { 0.6, 0, -1.0 }, b = { 1.2, 0, 0.6 }, wa = 0.6, wb = -0.3 },   -- backhand
	[3] = { a = { 2.8, 0, 0.3 }, b = { 0.6, 0, -0.2 }, wa = -0.3, wb = 0.3 },   -- overhead
	[4] = { a = { -0.1, 0, 0.35 }, b = { 0.75, 0, 0.1 }, wa = -0.15, wb = 0.1 }, -- soft forehand (dink, drop)
	[5] = { a = { 0.3, 0, -0.5 }, b = { 0.8, 0, 0.1 }, wa = 0.2, wb = -0.05 },  -- soft backhand
}
local SWING_TIME = 0.3

local folder: Folder
local rigs: { [number]: Rig } = {}
local poses: { [number]: Pose } = {}
local swings: { [number]: Swing } = {}
local humanSlot: { [number]: Player } = {}
local anims = table.clone(DEFAULT_ANIMS)

local function readAnimIds()
	local char = Players.LocalPlayer.Character
	local animate = char and char:FindFirstChild("Animate")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not animate or not hum or hum.RigType ~= Enum.HumanoidRigType.R15 then return end
	for name in DEFAULT_ANIMS do
		local holder = animate:FindFirstChild(name)
		local a = holder and holder:FindFirstChildOfClass("Animation")
		if a and a.AnimationId ~= "" then anims[name] = a.AnimationId end
	end
end

local function makeRig(slot: number): Rig?
	local src = ReplicatedStorage:WaitForChild("DinkRigs", 10)
	local template = src and src:FindFirstChild("Slot" .. slot)
	if not template or not template:IsA("Model") then return nil end
	local model = template:Clone()
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return nil end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local tracks = {}
	if hum then
		local animator = hum:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = hum
		end
		for name, id in anims do
			local a = Instance.new("Animation")
			a.AnimationId = id
			local ok, track = pcall(function() return (animator :: Animator):LoadAnimation(a) end)
			if ok and track then
				track.Looped = true
				track.Priority = if name == "idle" then Enum.AnimationPriority.Idle else Enum.AnimationPriority.Movement
				track:Play(0.2, if name == "idle" then 1 else 0.001, 1)
				tracks[name] = track
			end
		end
	end
	local height = if hum then hum.HipHeight + root.Size.Y / 2 else 3
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(120, 22)
	tag.StudsOffset = Vector3.new(0, 3.4, 0)
	tag.AlwaysOnTop = false
	tag.MaxDistance = 90
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.TextColor3 = Color3.fromRGB(235, 240, 245)
	t.TextStrokeTransparency = 0.4
	t.Text = "AI"
	t.Parent = tag
	tag.Adornee = model:FindFirstChild("Head") or root
	tag.Parent = model
	model.Parent = folder
	return { model = model, root = root, hum = hum, tracks = tracks, x = 0, z = 0, yaw = 0, height = height }
end

function Rigs.init(parent: Instance)
	folder = Instance.new("Folder")
	folder.Name = "AIPlayers"
	folder.Parent = parent
	readAnimIds()
	RunService.PreSimulation:Connect(Rigs.applySwings)
end

-- slots[i] = { human = bool, userId = number, name = string } from the server's Info event
function Rigs.setSlots(slots: { any }, level: string)
	for i = 1, 4 do
		local s = slots[i]
		local plr = if s.human then Players:GetPlayerByUserId(s.userId) else nil
		humanSlot[i] = plr :: Player
		if plr then
			if rigs[i] then rigs[i].model:Destroy(); rigs[i] = nil end
		else
			if not rigs[i] then rigs[i] = makeRig(i) :: Rig end
			local r = rigs[i]
			if r then
				local tag = r.model:FindFirstChildOfClass("BillboardGui")
				local lbl = tag and tag:FindFirstChildOfClass("TextLabel")
				if lbl then lbl.Text = "AI · " .. (if level == "club" then "Club" else "Pro") end
			end
		end
	end
end

function Rigs.pose(i: number, x: number, z: number, vx: number, vz: number, rot: number)
	poses[i] = { x = x, z = z, vx = vx, vz = vz, rot = rot, at = os.clock() }
end

function Rigs.swing(i: number, kind: number)
	swings[i] = { kind = kind, t = 0 }
end

function Rigs.update(dt: number, scale: number)
	for i, r in rigs do
		local p = poses[i]
		if not p then continue end
		-- extrapolate the 20 Hz pose stream with the sim velocity, then smooth
		local age = math.min(os.clock() - p.at, 0.25) * scale
		local tx, tz = p.x + p.vx * age, p.z + p.vz * age
		local k = 1 - math.exp(-dt * 18)
		r.x += (tx - r.x) * k
		r.z += (tz - r.z) * k
		if math.abs(tx - r.x) > 6 or math.abs(tz - r.z) > 6 then r.x, r.z = tx, tz end
		local yaw = p.rot + math.pi
		r.yaw += (((yaw - r.yaw + math.pi) % (2 * math.pi)) - math.pi) * k
		r.root.CFrame = CFrame.new(r.x, C.SURFACE_Y + r.height, r.z) * CFrame.Angles(0, r.yaw, 0)
		local speed = math.sqrt(p.vx * p.vx + p.vz * p.vz)
		local wRun = math.clamp((speed - 8) / 4, 0, 1)
		local wWalk = math.clamp(speed / 3, 0, 1) * (1 - wRun)
		local wIdle = 1 - math.max(wRun, wWalk)
		local tr = r.tracks
		if tr.idle then tr.idle:AdjustWeight(math.max(wIdle, 0.001), 0.1); tr.idle:AdjustSpeed(scale) end
		if tr.walk then tr.walk:AdjustWeight(math.max(wWalk, 0.001), 0.1); tr.walk:AdjustSpeed(math.clamp(speed / 8, 0.5, 1.6) * scale) end
		if tr.run then tr.run:AdjustWeight(math.max(wRun, 0.001), 0.1); tr.run:AdjustSpeed(math.clamp(speed / 16, 0.7, 1.4) * scale) end
	end
	for i, s in swings do
		s.t += dt * scale / SWING_TIME
		if s.t >= 1 then swings[i] = nil end
	end
end

local function modelFor(i: number): Model?
	local plr = humanSlot[i]
	if plr then return plr.Character end
	local r = rigs[i]
	return r and r.model
end

local function ease(t: number): number return 1 - (1 - t) ^ 3 end

function Rigs.applySwings()
	for i, s in swings do
		local model = modelFor(i)
		if not model then continue end
		local arm = model:FindFirstChild("RightUpperArm")
		local torso = model:FindFirstChild("UpperTorso")
		local shoulder = arm and arm:FindFirstChild("RightShoulder")
		local waist = torso and torso:FindFirstChild("Waist")
		local S = SWINGS[s.kind] or SWINGS[1]
		-- 0–0.15 wind up to the start pose, 0.15–0.55 strike, then blend back into the body animation
		local u, w, f = s.t, 1, 0
		if u < 0.15 then w = u / 0.15; f = 0
		elseif u < 0.55 then f = ease((u - 0.15) / 0.4)
		else f = 1; w = 1 - (u - 0.55) / 0.45 end
		local a = { S.a[1] + (S.b[1] - S.a[1]) * f, S.a[2] + (S.b[2] - S.a[2]) * f, S.a[3] + (S.b[3] - S.a[3]) * f }
		if shoulder and shoulder:IsA("Motor6D") then
			shoulder.Transform = shoulder.Transform:Lerp(CFrame.Angles(a[1], a[2], a[3]), w)
		end
		if waist and waist:IsA("Motor6D") then
			waist.Transform = waist.Transform:Lerp(CFrame.Angles(0, S.wa + (S.wb - S.wa) * f, 0), w * 0.8)
		end
	end
end

-- Where a slot's player is drawn (for sounds and the camera).
function Rigs.position(i: number): Vector3?
	local m = modelFor(i)
	local root = m and m:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

return Rigs
