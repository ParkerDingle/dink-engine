--!strict
-- Builds the venue: a regulation 20 x 44 ft pickleball court (1 stud = 1 ft) with kitchen, lines,
-- net, fence, light poles, bleachers, scoreboards and lighting. It runs when the server starts and
-- skips building if Workspace already has a "Court" model, so you can copy the generated court into
-- the place in Studio and customize it.
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local C = require(ReplicatedStorage:WaitForChild("Dink"):WaitForChild("Config"))

local B = {}

local Y = C.SURFACE_Y
local COLORS = {
	grass = Color3.fromRGB(86, 135, 72),
	surround = Color3.fromRGB(46, 96, 78),
	court = Color3.fromRGB(38, 92, 158),
	kitchen = Color3.fromRGB(44, 128, 140),
	line = Color3.fromRGB(245, 247, 250),
	fence = Color3.fromRGB(28, 52, 44),
	post = Color3.fromRGB(32, 36, 40),
	net = Color3.fromRGB(26, 28, 32),
	bleacher = Color3.fromRGB(150, 156, 164),
}

type Props = { [string]: any }

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, props: Props?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	if props then
		for k, v in props do (p :: any)[k] = v end
	end
	p.Parent = parent
	return p
end

-- A flat slab whose top face sits at height `top`.
local function slab(parent: Instance, name: string, x: number, z: number, w: number, l: number, top: number, thick: number, color: Color3, props: Props?): Part
	local p = part(parent, name, Vector3.new(w, thick, l), CFrame.new(x, top - thick / 2, z), props)
	p.Color = color
	return p
end

local function label(face: Enum.NormalId, parent: BasePart, text: string, size: number, color: Color3?)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 40
	g.LightInfluence = 0.4
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color or Color3.fromRGB(235, 240, 245)
	t.Parent = g
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(size, 0)
	pad.PaddingBottom = UDim.new(size, 0)
	pad.Parent = t
	g.Parent = parent
end

local function buildLines(court: Model)
	local lines = Instance.new("Folder")
	lines.Name = "Lines"
	lines.Parent = court
	local w = 2 / 12 -- 2 inch lines
	local top = Y + 0.012
	local function line(name: string, x: number, z: number, sx: number, sz: number)
		slab(lines, name, x, z, sx, sz, top, 0.02, COLORS.line, { CanCollide = false, CanQuery = false, CastShadow = false })
	end
	-- outside edges of the lines are on the court boundary
	line("Baseline", 0, C.L - w / 2, C.W * 2, w)
	line("Baseline", 0, -C.L + w / 2, C.W * 2, w)
	line("Sideline", C.W - w / 2, 0, w, C.L * 2)
	line("Sideline", -C.W + w / 2, 0, w, C.L * 2)
	line("KitchenLine", 0, C.K, C.W * 2, w)
	line("KitchenLine", 0, -C.K, C.W * 2, w)
	local len = C.L - C.K
	line("Centerline", 0, C.K + len / 2, w, len)
	line("Centerline", 0, -C.K - len / 2, w, len)
end

local function buildNet(court: Model)
	local net = Instance.new("Model")
	net.Name = "Net"
	net.Parent = court
	for _, sx in { -1, 1 } do
		local post = part(net, "Post", Vector3.new(3.0, 0.24, 0.24), CFrame.new(sx * 11, Y + 1.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
			{ Shape = Enum.PartType.Cylinder, Color = COLORS.post, Material = Enum.Material.Metal })
		post.CanQuery = false
		part(net, "Foot", Vector3.new(1.2, 0.12, 1.2), CFrame.new(sx * 11, Y + 0.06, 0), { Color = COLORS.post, Material = Enum.Material.Metal })
	end
	local h = C.NET_H - 0.36
	part(net, "Mesh", Vector3.new(22, h, 0.03), CFrame.new(0, Y + 0.3 + h / 2, 0),
		{ Color = COLORS.net, Material = Enum.Material.Fabric, Transparency = 0.58, CanCollide = false, CanQuery = false, CastShadow = true })
	part(net, "Tape", Vector3.new(22, 0.18, 0.06), CFrame.new(0, Y + C.NET_H - 0.09, 0),
		{ Color = COLORS.line, Material = Enum.Material.Fabric, CanCollide = false, CanQuery = false })
	part(net, "CenterStrap", Vector3.new(0.17, C.NET_H - 0.1, 0.05), CFrame.new(0, Y + (C.NET_H - 0.1) / 2, 0),
		{ Color = COLORS.line, Material = Enum.Material.Fabric, CanCollide = false, CanQuery = false })
	-- players can't cross the net plane
	part(net, "Barrier", Vector3.new(36, 14, 0.6), CFrame.new(0, Y + 7, 0),
		{ Transparency = 1, CanCollide = true, CanQuery = false, CanTouch = false, CastShadow = false })
end

local FX, FZ, FH = 18, 34, 9
local function buildFence(court: Model)
	local fence = Instance.new("Model")
	fence.Name = "Fence"
	fence.Parent = court
	local function side(x0: number, z0: number, x1: number, z1: number, face: Enum.NormalId?, text: string?)
		local dx, dz = x1 - x0, z1 - z0
		local len = math.sqrt(dx * dx + dz * dz)
		local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
		local ry = math.atan2(-dz, dx)
		local rot = CFrame.Angles(0, ry, 0)
		local screen = part(fence, "Windscreen", Vector3.new(len, 6, 0.12), CFrame.new(cx, Y + 3, cz) * rot,
			{ Color = COLORS.fence, Material = Enum.Material.Fabric })
		part(fence, "Mesh", Vector3.new(len, FH - 6, 0.06), CFrame.new(cx, Y + 6 + (FH - 6) / 2, cz) * rot,
			{ Color = COLORS.post, Material = Enum.Material.DiamondPlate, Transparency = 0.82, CanQuery = false })
		part(fence, "Rail", Vector3.new(len, 0.2, 0.2), CFrame.new(cx, Y + FH, cz) * rot, { Color = COLORS.post, Material = Enum.Material.Metal })
		local n = math.max(1, math.floor(len / 8))
		for i = 0, n do
			local t = i / n
			part(fence, "Post", Vector3.new(0.25, FH, 0.25), CFrame.new(x0 + dx * t, Y + FH / 2, z0 + dz * t), { Color = COLORS.post, Material = Enum.Material.Metal })
		end
		if face and text then label(face, screen, text, 0.18) end
	end
	-- the Back face of an unrotated part points along +z (toward the court from the far end)
	side(-FX, -FZ, FX, -FZ, Enum.NormalId.Back, "DINK ENGINE")
	side(-FX, FZ, FX, FZ, Enum.NormalId.Front, "DINK ENGINE")
	side(-FX, -FZ, -FX, FZ)
	side(FX, -FZ, FX, FZ)
end

local function buildLights(court: Model)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local x, z = sx * (FX + 1.5), sz * (FZ - 6)
			part(court, "LightPole", Vector3.new(0.5, 24, 0.5), CFrame.new(x, Y + 12, z), { Color = COLORS.post, Material = Enum.Material.Metal })
			local head = part(court, "LightHead", Vector3.new(2.4, 0.8, 1.2), CFrame.lookAt(Vector3.new(x - sx * 0.8, Y + 24, z), Vector3.new(0, 0, z * 0.3)),
				{ Color = Color3.fromRGB(230, 236, 240), Material = Enum.Material.Neon })
			local spot = Instance.new("SpotLight")
			spot.Face = Enum.NormalId.Front
			spot.Angle = 70
			spot.Range = 60
			spot.Brightness = 1.2
			spot.Shadows = false
			spot.Parent = head
		end
	end
end

local function buildBleachers(court: Model)
	local stand = Instance.new("Model")
	stand.Name = "Bleachers"
	stand.Parent = court
	for row = 0, 3 do
		local x = FX + 5 + row * 1.8
		local top = Y + 0.9 + row * 1.1
		slab(stand, "Step", x, 0, 1.8, 26, top, top - Y, COLORS.bleacher, { Material = Enum.Material.Metal })
		for k = -4, 4 do
			local seat = Instance.new("Seat")
			seat.Name = "Seat"
			seat.Anchored = true
			seat.Size = Vector3.new(1.4, 0.3, 2.4)
			seat.CFrame = CFrame.new(x, top + 0.15, k * 2.8) * CFrame.Angles(0, math.pi / 2, 0)
			seat.Color = Color3.fromRGB(220, 96, 52)
			seat.Material = Enum.Material.SmoothPlastic
			seat.TopSurface = Enum.SurfaceType.Smooth
			seat.Parent = stand
		end
	end
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = Vector3.new(3.4, 0.4, 8)
	spawn.CFrame = CFrame.new(FX + 2.6, Y + 0.2, 0)
	spawn.Color = Color3.fromRGB(220, 96, 52)
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Duration = 0
	spawn.Parent = stand
	local d = spawn:FindFirstChildOfClass("Decal")
	if d then d:Destroy() end
end

local boards: { TextLabel } = {}
local subs: { TextLabel } = {}
local function buildScoreboards(court: Model)
	for _, sz in { -1, 1 } do
		-- far enough back that the court camera (behind each baseline) sits in front of its own board
		local z = sz * (FZ + 10)
		local board = part(court, "Scoreboard", Vector3.new(16, 6, 0.6), CFrame.new(0, Y + 16, z), { Color = Color3.fromRGB(16, 20, 26), Material = Enum.Material.Metal })
		for _, px in { -6, 6 } do
			part(court, "ScoreboardPost", Vector3.new(0.4, 14, 0.4), CFrame.new(px, Y + 7, z), { Color = COLORS.post, Material = Enum.Material.Metal })
		end
		local g = Instance.new("SurfaceGui")
		g.Face = if sz < 0 then Enum.NormalId.Back else Enum.NormalId.Front
		g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		g.PixelsPerStud = 40
		g.LightInfluence = 0
		g.Brightness = 1.6
		local main = Instance.new("TextLabel")
		main.BackgroundTransparency = 1
		main.Size = UDim2.fromScale(1, 0.62)
		main.Font = Enum.Font.GothamBlack
		main.TextScaled = true
		main.TextColor3 = Color3.fromRGB(255, 196, 90)
		main.Text = "0  –  0"
		main.Parent = g
		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Position = UDim2.fromScale(0.05, 0.62)
		sub.Size = UDim2.fromScale(0.9, 0.3)
		sub.Font = Enum.Font.GothamBold
		sub.TextScaled = true
		sub.TextColor3 = Color3.fromRGB(210, 220, 230)
		sub.Text = "Dink Engine"
		sub.Parent = g
		g.Parent = board
		table.insert(boards, main)
		table.insert(subs, sub)
	end
end

function B.setBoard(main: string, sub: string)
	for _, t in boards do t.Text = main end
	for _, t in subs do t.Text = sub end
end

local function setupLighting()
	Lighting.ClockTime = 15.2
	Lighting.Brightness = 3
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 132, 140)
	Lighting.Ambient = Color3.fromRGB(60, 64, 70)
	Lighting.GlobalShadows = true
	if not Lighting:FindFirstChildOfClass("Sky") then Instance.new("Sky").Parent = Lighting end
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local a = Instance.new("Atmosphere")
		a.Density = 0.28
		a.Haze = 1.2
		a.Glare = 0.2
		a.Parent = Lighting
	end
	if not Lighting:FindFirstChildOfClass("ColorCorrectionEffect") then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Saturation = 0.12
		cc.Contrast = 0.06
		cc.Parent = Lighting
	end
	if not Lighting:FindFirstChildOfClass("BloomEffect") then
		local bl = Instance.new("BloomEffect")
		bl.Intensity = 0.35
		bl.Size = 18
		bl.Threshold = 1.6
		bl.Parent = Lighting
	end
end

function B.build(): Model
	setupLighting()
	local existing = workspace:FindFirstChild("Court")
	if existing and existing:IsA("Model") then
		for _, d in existing:GetDescendants() do
			if d:IsA("TextLabel") and d.Parent and d.Parent:IsA("SurfaceGui") and d.Parent.Parent and d.Parent.Parent.Name == "Scoreboard" then
				if d.Font == Enum.Font.GothamBlack then table.insert(boards, d) else table.insert(subs, d) end
			end
		end
		return existing
	end
	local court = Instance.new("Model")
	court.Name = "Court"
	local base = workspace:FindFirstChild("Baseplate")
	if base then base:Destroy() end
	slab(court, "Ground", 0, 0, 600, 600, 0, 2, COLORS.grass, { Material = Enum.Material.Grass })
	slab(court, "Surround", 0, 0, FX * 2 + 6, FZ * 2 + 6, Y - 0.01, 0.2, COLORS.surround)
	slab(court, "Playing", 0, 0, C.W * 2, C.L * 2, Y, 0.02, COLORS.court, { CanCollide = false })
	slab(court, "Kitchen", 0, C.K / 2, C.W * 2, C.K, Y + 0.004, 0.02, COLORS.kitchen, { CanCollide = false })
	slab(court, "Kitchen", 0, -C.K / 2, C.W * 2, C.K, Y + 0.004, 0.02, COLORS.kitchen, { CanCollide = false })
	buildLines(court)
	buildNet(court)
	buildFence(court)
	buildLights(court)
	buildBleachers(court)
	buildScoreboards(court)
	court.Parent = workspace
	return court
end

return B
