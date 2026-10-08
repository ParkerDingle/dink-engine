--!nonstrict
-- Things drawn on the court for the local player only: the ball (with trail and ground shadow),
-- the aim reticle, where to stand, the predicted bounce and the eval map (win chance per zone).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local C = require(ReplicatedStorage:WaitForChild("Dink"):WaitForChild("Config"))

local M = {}

local Y = C.SURFACE_Y
local BALL_VIS_R = 0.24 -- drawn a bit larger than a real ball so it reads on screen
local FLAT = CFrame.Angles(0, 0, math.pi / 2)

local folder: Folder
local ball: Part
local shadow: Part
local reticle: Part
local stand: Part
local bounce: Part
local tiles: { [string]: { part: Part, label: TextLabel, gui: BillboardGui } } = {}
local bounceUntil = 0

local function disc(name: string, d: number, color: Color3, transparency: number, neon: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.04, d, d)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Color = color
	p.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	p.Transparency = transparency
	p.CFrame = CFrame.new(0, -50, 0)
	p.Parent = folder
	return p
end

local function hide(p: BasePart) p.CFrame = CFrame.new(0, -50, 0) end
local function onCourt(p: BasePart, x: number, z: number, lift: number)
	p.CFrame = CFrame.new(x, Y + lift, z) * FLAT
end

function M.init(parent: Instance)
	folder = Instance.new("Folder")
	folder.Name = "Markers"
	folder.Parent = parent

	ball = Instance.new("Part")
	ball.Name = "Ball"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * BALL_VIS_R * 2
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Color = Color3.fromRGB(226, 255, 70)
	ball.Material = Enum.Material.Neon
	ball.CFrame = CFrame.new(0, -50, 0)
	ball.Parent = folder
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.12, 0)
	a0.Parent = ball
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.12, 0)
	a1.Parent = ball
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.14
	trail.MinLength = 0.05
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(Color3.fromRGB(226, 255, 70))
	trail.Transparency = NumberSequence.new(0.35, 1)
	trail.LightEmission = 0.6
	trail.Parent = ball

	shadow = disc("BallShadow", 0.55, Color3.new(0, 0, 0), 0.55)
	reticle = disc("Aim", 1.8, Color3.fromRGB(255, 176, 72), 0.25, true)
	stand = disc("StandHere", 1.7, Color3.fromRGB(255, 255, 255), 0.45, true)
	bounce = disc("Bounce", 1.0, Color3.fromRGB(226, 255, 70), 0.35, true)

	-- eval map: 3 x 3 zones on each side
	local bins = { { 0, 7 }, { 7, 14.5 }, { 14.5, 22 } }
	for side = 0, 1 do
		local sg = C.sideSign(side)
		for col = 0, 2 do
			for depth = 0, 2 do
				local lo, hi = bins[depth + 1][1], bins[depth + 1][2]
				local p = Instance.new("Part")
				p.Name = "Zone"
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.CastShadow = false
				p.Material = Enum.Material.Neon
				p.Size = Vector3.new(20 / 3 - 0.3, 0.03, hi - lo - 0.3)
				p.CFrame = CFrame.new(-10 + (col + 0.5) * 20 / 3, Y + 0.03, sg * (lo + hi) / 2)
				p.Transparency = 1
				p.Parent = folder
				local gui = Instance.new("BillboardGui")
				gui.Size = UDim2.fromOffset(70, 30)
				gui.AlwaysOnTop = true
				gui.Enabled = false
				gui.Adornee = p
				local t = Instance.new("TextLabel")
				t.BackgroundTransparency = 1
				t.Size = UDim2.fromScale(1, 1)
				t.Font = Enum.Font.GothamBlack
				t.TextScaled = true
				t.TextColor3 = Color3.new(1, 1, 1)
				t.TextStrokeTransparency = 0.3
				t.Parent = gui
				gui.Parent = p
				tiles[side .. ":" .. col .. ":" .. depth] = { part = p, label = t, gui = gui }
			end
		end
	end
end

function M.setBall(x: number, y: number, z: number, visible: boolean)
	if not visible then hide(ball); hide(shadow); return end
	ball.CFrame = CFrame.new(x, Y + y + (BALL_VIS_R - C.BALL_R), z)
	if math.abs(x) < 20 and math.abs(z) < 36 then
		local h = math.clamp(y / 12, 0, 1)
		shadow.Size = Vector3.new(0.04, 0.55 + h * 0.4, 0.55 + h * 0.4)
		shadow.Transparency = 0.5 + h * 0.4
		onCourt(shadow, x, z, 0.02)
	else
		hide(shadow)
	end
end

function M.ballPosition(): Vector3
	return ball.Position
end

function M.setReticle(x: number?, z: number?, color: Color3?)
	if not x or not z then hide(reticle); return end
	if color then reticle.Color = color end
	onCourt(reticle, x, z, 0.05)
end

function M.setStand(x: number?, z: number?)
	if not x or not z then hide(stand); return end
	onCourt(stand, x, z, 0.04)
end

function M.showBounce(x: number, z: number, seconds: number)
	onCourt(bounce, x, z, 0.045)
	bounceUntil = os.clock() + seconds
end

function M.tick()
	if os.clock() > bounceUntil then hide(bounce) end
end

-- values[side:col:depth] = win chance; nil hides the map. best/worst set the color range.
function M.setEval(values: { [string]: number }?, best: number?, worst: number?)
	for key, t in tiles do
		local v = values and values[key]
		if not v or not best or not worst then
			t.part.Transparency = 1
			t.gui.Enabled = false
			continue
		end
		local f = if best - worst > 1e-6 then (v - worst) / (best - worst) else 1
		t.part.Color = Color3.fromRGB(230, 70, 60):Lerp(Color3.fromRGB(250, 210, 70), math.clamp(f * 2, 0, 1)):Lerp(Color3.fromRGB(70, 215, 120), math.clamp(f * 2 - 1, 0, 1))
		t.part.Transparency = 0.62 - 0.12 * f
		t.gui.Enabled = true
		t.label.Text = string.format("%d%%", math.floor(v * 100 + 0.5))
		t.label.TextColor3 = if f > 0.999 then Color3.fromRGB(120, 255, 160) else Color3.new(1, 1, 1)
	end
end

-- Built-in engine sounds (rbxasset://) so the place works without uploading audio.
local sounds: { [string]: Sound } = {}
local SOUND_IDS = { pop = "rbxasset://sounds/clickfast.wav", bounce = "rbxasset://sounds/clickfast.wav", point = "rbxasset://sounds/electronicpingshort.wav" }
function M.play(name: string, volume: number?, pitch: number?)
	local s = sounds[name]
	if not s then
		s = Instance.new("Sound")
		s.SoundId = SOUND_IDS[name] or ""
		s.Parent = SoundService
		sounds[name] = s
	end
	s.Volume = volume or 0.5
	s.PlaybackSpeed = pitch or 1
	SoundService:PlayLocalSound(s)
end

return M
