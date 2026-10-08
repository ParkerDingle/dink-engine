--!strict
-- AI player rigs and paddles. The server builds one R15 rig per slot (team colors) and puts them in
-- ReplicatedStorage.DinkRigs; each client clones the rigs for the AI-controlled slots and moves and
-- animates them locally from the server's pose stream, which looks smooth at any network rate.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local C = require(ReplicatedStorage:WaitForChild("Dink"):WaitForChild("Config"))

local N = {}

local TEAM = {
	[0] = { shirt = Color3.fromRGB(222, 92, 44), shorts = Color3.fromRGB(28, 36, 46), paddle = Color3.fromRGB(24, 58, 96) },
	[1] = { shirt = Color3.fromRGB(236, 240, 244), shorts = Color3.fromRGB(34, 64, 110), paddle = Color3.fromRGB(70, 36, 86) },
}
local SKIN = { Color3.fromRGB(234, 190, 150), Color3.fromRGB(160, 110, 76), Color3.fromRGB(204, 150, 110), Color3.fromRGB(110, 74, 52) }

-- Paddle welded to the right hand, extending along the forearm with the face toward the front.
function N.addPaddle(character: Model, team: number)
	if character:FindFirstChild("Paddle") then return end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then return end
	local r6 = hand.Name == "Right Arm"
	local grip = if r6 then -1.0 else -hand.Size.Y / 2
	local model = Instance.new("Model")
	model.Name = "Paddle"
	local function piece(name: string, size: Vector3, offset: number, color: Color3, mat: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		if shape then p.Shape = shape end
		p.Color = color
		p.Material = mat
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.CFrame = hand.CFrame * CFrame.new(0, grip + offset, 0)
		local w = Instance.new("Weld")
		w.Part0 = hand
		w.Part1 = p
		w.C0 = CFrame.new(0, grip + offset, 0)
		w.Parent = p
		p.Parent = model
		return p
	end
	piece("Handle", Vector3.new(0.14, 0.5, 0.14), -0.1, Color3.fromRGB(30, 32, 36), Enum.Material.Fabric)
	piece("Face", Vector3.new(0.72, 0.95, 0.07), -0.8, TEAM[team].paddle, Enum.Material.SmoothPlastic)
	piece("Edge", Vector3.new(0.78, 1.0, 0.05), -0.8, Color3.fromRGB(16, 18, 22), Enum.Material.SmoothPlastic)
	model.Parent = character
end

local function description(slot: number): HumanoidDescription
	local team = C.teamOf(slot)
	local d = Instance.new("HumanoidDescription")
	local skin = SKIN[slot]
	d.HeadColor = skin
	d.LeftArmColor = skin
	d.RightArmColor = skin
	d.TorsoColor = TEAM[team].shirt
	d.LeftLegColor = TEAM[team].shorts
	d.RightLegColor = TEAM[team].shorts
	return d
end

local function createRig(desc: HumanoidDescription): Model?
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R15)
	end)
	if ok and rig then return rig end
	ok, rig = pcall(function()
		return (Players :: any):CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if ok and rig then return rig end
	warn("[Dink] couldn't create an avatar rig, using a simple one:", rig)
	return nil
end

-- Fallback rig built from parts (no avatar service needed). Same joint names as R15 for the parts
-- the swing code uses, so swings still play.
local function simpleRig(slot: number): Model
	local team = C.teamOf(slot)
	local m = Instance.new("Model")
	local function p(name: string, size: Vector3, color: Color3): Part
		local q = Instance.new("Part")
		q.Name = name
		q.Size = size
		q.Color = color
		q.CanCollide = false
		q.Material = Enum.Material.SmoothPlastic
		q.Parent = m
		return q
	end
	local root = p("HumanoidRootPart", Vector3.new(2, 2, 1), Color3.new())
	root.Transparency = 1
	local lower = p("LowerTorso", Vector3.new(2, 0.6, 1), TEAM[team].shorts)
	local upper = p("UpperTorso", Vector3.new(2, 1.6, 1), TEAM[team].shirt)
	local head = p("Head", Vector3.new(1.2, 1.2, 1.2), SKIN[slot])
	local arm = p("RightUpperArm", Vector3.new(0.8, 1.2, 0.8), SKIN[slot])
	local fore = p("RightLowerArm", Vector3.new(0.7, 1.1, 0.7), SKIN[slot])
	local hand = p("RightHand", Vector3.new(0.6, 0.4, 0.6), SKIN[slot])
	local larm = p("LeftUpperArm", Vector3.new(0.8, 2.2, 0.8), SKIN[slot])
	local ll = p("LeftLeg", Vector3.new(0.9, 2.1, 0.9), TEAM[team].shorts)
	local rl = p("RightLeg", Vector3.new(0.9, 2.1, 0.9), TEAM[team].shorts)
	local function joint(name: string, a: BasePart, b: BasePart, c0: CFrame, c1: CFrame)
		local j = Instance.new("Motor6D")
		j.Name = name
		j.Part0 = a
		j.Part1 = b
		j.C0 = c0
		j.C1 = c1
		j.Parent = b
	end
	joint("Root", root, lower, CFrame.new(0, -0.7, 0), CFrame.new())
	joint("Waist", lower, upper, CFrame.new(0, 0.3, 0), CFrame.new(0, -0.8, 0))
	joint("Neck", upper, head, CFrame.new(0, 0.8, 0), CFrame.new(0, -0.6, 0))
	joint("RightShoulder", upper, arm, CFrame.new(1.4, 0.6, 0), CFrame.new(0, 0.5, 0))
	joint("RightElbow", arm, fore, CFrame.new(0, -0.6, 0), CFrame.new(0, 0.5, 0))
	joint("RightWrist", fore, hand, CFrame.new(0, -0.55, 0), CFrame.new(0, 0.2, 0))
	joint("LeftShoulder", upper, larm, CFrame.new(-1.4, 0.4, 0), CFrame.new(0, 0.9, 0))
	joint("LeftHip", lower, ll, CFrame.new(-0.5, -0.3, 0), CFrame.new(0, 1.05, 0))
	joint("RightHip", lower, rl, CFrame.new(0.5, -0.3, 0), CFrame.new(0, 1.05, 0))
	local h = Instance.new("Humanoid")
	h.HipHeight = 2.1
	h.Parent = m
	m.PrimaryPart = root
	return m
end

function N.buildRigs(): Folder
	local folder = Instance.new("Folder")
	folder.Name = "DinkRigs"
	for slot = 1, 4 do
		local rig = createRig(description(slot)) or simpleRig(slot)
		rig.Name = "Slot" .. slot
		local hum = rig:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			hum.BreakJointsOnDeath = false
			if not hum:FindFirstChildOfClass("Animator") then Instance.new("Animator").Parent = hum end
		end
		local animate = rig:FindFirstChild("Animate")
		if animate then animate:Destroy() end
		for _, d in rig:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Anchored = d.Name == "HumanoidRootPart"
			end
		end
		N.addPaddle(rig, C.teamOf(slot))
		rig.Parent = folder
	end
	folder.Parent = ReplicatedStorage
	return folder
end

return N
