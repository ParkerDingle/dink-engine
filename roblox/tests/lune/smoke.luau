--!nocheck
-- End-to-end smoke test of the built place file, run with Lune (https://lune-org.github.io/docs):
--
--     rojo build roblox/default.project.json -o roblox/build/dink-engine.rbxl
--     lune run roblox/tests/lune/smoke.luau roblox/build/dink-engine.rbxl
--
-- Lune loads the real .rbxl and gives us real Roblox instances and datatypes, so every property the
-- game scripts set is checked against the Roblox API. Lune has no game engine, so this file supplies
-- the missing pieces: signals, RunService steps on a virtual clock, remotes (with Roblox's argument
-- serialization rules), players and characters, input, and a simple humanoid walk. The server script
-- and the client script then run unchanged, and bot players play full games through the real UI paths.
local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Instance, Vector3, Vector2, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.Vector2, roblox.CFrame, roblox.Enum

local placePath = process.args[1] or "roblox/build/dink-engine.rbxl"
local game = roblox.deserializePlace(fs.readFile(placePath))
local workspace = game:GetService("Workspace")

local errors = {}
local function fail(msg)
	table.insert(errors, msg)
	print("ERROR " .. msg)
end

---------------------------------------------------------------- virtual clock and task scheduler
local now = 0
local timers = {}
local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then fail(debug.traceback(co, tostring(err))) end
end
local function schedule(at, co, ...)
	table.insert(timers, { at = at, co = co, args = table.pack(...) })
end
local taskLib = {
	spawn = function(f, ...)
		local co = if type(f) == "thread" then f else coroutine.create(f)
		resume(co, ...)
		return co
	end,
	defer = function(f, ...)
		local co = if type(f) == "thread" then f else coroutine.create(f)
		schedule(now, co, ...)
		return co
	end,
	delay = function(t, f, ...)
		local co = coroutine.create(f)
		schedule(now + (t or 0), co, ...)
		return co
	end,
	wait = function(t)
		local co = coroutine.running()
		local start = now
		schedule(now + (t or 0), co)
		coroutine.yield()
		return now - start
	end,
	cancel = function() end,
}
local function runTimers()
	local guard = 0
	while true do
		local due
		for i, t in timers do
			if t.at <= now then due = table.remove(timers, i); break end
		end
		if not due then return end
		resume(due.co, table.unpack(due.args, 1, due.args.n))
		guard += 1
		if guard > 10000 then fail("timer storm"); return end
	end
end

---------------------------------------------------------------- signals
local Signal = {}
Signal.__index = Signal
function Signal.new() return setmetatable({ handlers = {} }, Signal) end
function Signal:Connect(fn)
	local h = { fn = fn, on = true }
	table.insert(self.handlers, h)
	return { Connected = true, Disconnect = function() h.on = false end }
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...) c.Disconnect(); fn(...) end)
	return c
end
function Signal:Fire(...)
	for _, h in table.clone(self.handlers) do
		if h.on then resume(coroutine.create(h.fn), ...) end
	end
end
function Signal:Wait()
	local co = coroutine.running()
	self:Once(function(...) resume(co, ...) end)
	return coroutine.yield()
end

-- strong keys: Lune may drop and recreate an instance's userdata, which would clear weak entries
local signals = {}
local function sig(inst, name)
	local t = signals[inst]
	if not t then t = {}; signals[inst] = t end
	t[name] = t[name] or Signal.new()
	return t[name]
end
local store = {}
local function slot(inst)
	local t = store[inst]
	if not t then t = {}; store[inst] = t end
	return t
end

-- events and members Lune doesn't implement
local function event(class, name)
	roblox.implementProperty(class, name, function(self) return sig(self, name) end)
end
local function stored(class, name, default)
	roblox.implementProperty(class, name, function(self)
		local v = slot(self)[name]
		if v == nil then return default end
		return v
	end, function(self, v) slot(self)[name] = v end)
end
for _, e in { { "TextButton", "Activated" }, { "RemoteEvent", "OnServerEvent" }, { "RemoteEvent", "OnClientEvent" },
	{ "UnreliableRemoteEvent", "OnServerEvent" }, { "UnreliableRemoteEvent", "OnClientEvent" }, { "Player", "CharacterAdded" },
	{ "Players", "PlayerAdded" }, { "Players", "PlayerRemoving" }, { "RunService", "Heartbeat" }, { "RunService", "RenderStepped" },
	{ "RunService", "PreSimulation" }, { "UserInputService", "InputBegan" }, { "UserInputService", "TouchTapInWorld" } } do
	event(e[1], e[2])
end
-- properties that exist in the API but have no default in Lune are set explicitly instead
-- (implementProperty only adds members the reflection database doesn't know)
local _ = stored
workspace.CurrentCamera.ViewportSize = Vector2.new(1280, 720)
game:GetService("UserInputService").TouchEnabled = false
game:GetService("UserInputService").MouseEnabled = true

roblox.implementMethod("Instance", "WaitForChild", function(self, name, timeout)
	local c = self:FindFirstChild(name)
	if c or not coroutine.isyieldable() then return c end
	local limit = now + (timeout or 10)
	while now < limit do
		taskLib.wait(0.05)
		c = self:FindFirstChild(name)
		if c then return c end
	end
	if not timeout then fail("infinite yield on WaitForChild(" .. name .. ") under " .. self:GetFullName()) end
	return nil
end)
roblox.implementMethod("Instance", "GetPropertyChangedSignal", function(self, name) return sig(self, "changed:" .. name) end)
roblox.implementMethod("Model", "PivotTo", function(self, cf)
	local root = self.PrimaryPart or self:FindFirstChild("HumanoidRootPart")
	if not root then error("PivotTo: model has no PrimaryPart") end
	local offset = root.CFrame:Inverse()
	for _, d in self:GetDescendants() do
		if d:IsA("BasePart") then
			-- Lune stores Position separately from CFrame, so keep both in step
			local c = cf * (offset * d.CFrame)
			d.CFrame = c
			d.Position = c.Position
		end
	end
end)
roblox.implementMethod("Workspace", "GetServerTimeNow", function() return now end)
roblox.implementMethod("Humanoid", "MoveTo", function(self, pos) slot(self).moveTo = pos end)
roblox.implementMethod("Animator", "LoadAnimation", function(self, anim)
	assert(anim:IsA("Animation") and string.find(anim.AnimationId, "^rbxassetid://%d+$"), "bad animation id " .. tostring(anim.AnimationId))
	return { Looped = false, Priority = Enum.AnimationPriority.Core, Play = function() end, Stop = function() end,
		AdjustWeight = function(_, w) assert(type(w) == "number" and w == w) end, AdjustSpeed = function(_, s) assert(type(s) == "number" and s == s) end }
end)
roblox.implementMethod("TweenService", "Create", function(_, inst, info, goal)
	assert(typeof(inst) == "Instance" and type(goal) == "table")
	return { Play = function() for k, v in goal do inst[k] = v end end }
end)
roblox.implementMethod("SoundService", "PlayLocalSound", function(_, s) assert(s:IsA("Sound") and s.SoundId ~= "") end)
roblox.implementMethod("StarterGui", "SetCoreGuiEnabled", function() end)
local mouseWorld = Vector3.new(0, 0, -10)
local function downRay() return roblox.Ray.new(Vector3.new(mouseWorld.X, 60, mouseWorld.Z), Vector3.new(0, -100, 0)) end
roblox.implementMethod("Camera", "ViewportPointToRay", function() return downRay() end)
roblox.implementMethod("Camera", "ScreenPointToRay", function() return downRay() end)
roblox.implementMethod("UserInputService", "GetMouseLocation", function() return Vector2.new(640, 360) end)
local keyHandlers = {}
roblox.implementMethod("ContextActionService", "BindActionAtPriority", function(_, name, fn, _, priority, ...)
	assert(type(name) == "string" and type(fn) == "function" and type(priority) == "number")
	for _, k in { ... } do keyHandlers[tostring(k)] = fn end -- EnumItems aren't identity-stable in Lune
end)

---------------------------------------------------------------- remotes (with serialization checks)
local function checkArg(v, path, seen)
	local t = typeof(v)
	if t == "function" or t == "thread" then error("can't send a " .. t .. " over a remote: " .. path) end
	if t == "number" and v ~= v then error("NaN sent over a remote: " .. path) end
	if t ~= "table" then return end
	if seen[v] then error("cyclic table sent over a remote: " .. path) end
	seen[v] = true
	local n, keys, strKeys = #v, 0, 0
	for k, x in v do
		keys += 1
		if type(k) == "string" then strKeys += 1
		elseif type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then error("non-array number key sent over a remote: " .. path .. "[" .. tostring(k) .. "]") end
		checkArg(x, path .. "." .. tostring(k), seen)
	end
	if strKeys > 0 and strKeys < keys then error("mixed array/dictionary table sent over a remote: " .. path) end
	if strKeys == 0 and keys ~= n then error("sparse array sent over a remote: " .. path) end
	seen[v] = nil
end
local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in v do out[k] = copy(x) end
	return out
end
local function send(name, ...)
	local args = table.pack(...)
	for i = 1, args.n do
		local ok, err = pcall(checkArg, args[i], name .. " arg " .. i, {})
		if not ok then fail(err) end
		args[i] = copy(args[i])
	end
	return args
end

local localPlayer = nil
local botInbox = {} -- [player] = list of { remote, args }
local remoteLog = {}
local function routeToClient(remote, plr, args)
	remoteLog[remote.Name] = (remoteLog[remote.Name] or 0) + 1
	if plr == localPlayer then
		sig(remote, "OnClientEvent"):Fire(table.unpack(args, 1, args.n))
	elseif botInbox[plr] then
		table.insert(botInbox[plr], { remote = remote.Name, args = args })
	end
end
for _, class in { "RemoteEvent", "UnreliableRemoteEvent" } do
	roblox.implementMethod(class, "FireAllClients", function(self, ...)
		local args = send(self.Name, ...)
		for plr in botInbox do routeToClient(self, plr, args) end
		if localPlayer then routeToClient(self, localPlayer, args) end
	end)
	roblox.implementMethod(class, "FireClient", function(self, plr, ...)
		assert(typeof(plr) == "Instance" and plr:IsA("Player"), "FireClient needs a player")
		routeToClient(self, plr, send(self.Name, ...))
	end)
	roblox.implementMethod(class, "FireServer", function(self, ...)
		local args = send(self.Name, ...)
		sig(self, "OnServerEvent"):Fire(localPlayer, table.unpack(args, 1, args.n))
	end)
end
local Remotes = game:GetService("ReplicatedStorage"):FindFirstChild("DinkRemotes")
local function botFire(plr, name, ...)
	local args = send(name, ...)
	sig(Remotes:FindFirstChild(name), "OnServerEvent"):Fire(plr, table.unpack(args, 1, args.n))
end

---------------------------------------------------------------- players
local Players = game:GetService("Players")
local playerList = {}
roblox.implementMethod("Players", "GetPlayers", function() return table.clone(playerList) end)
roblox.implementMethod("Players", "GetPlayerByUserId", function(_, id)
	for _, p in playerList do if p.UserId == id then return p end end
	return nil
end)
roblox.implementMethod("Players", "CreateHumanoidModelFromDescriptionAsync", function() error("avatar service isn't available in tests") end)
roblox.implementMethod("Players", "CreateHumanoidModelFromDescription", function() error("avatar service isn't available in tests") end)

local function makeCharacter(plr)
	local m = Instance.new("Model")
	m.Name = plr.Name
	local function part(name, size, y)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = CFrame.new(22, y, 0)
		p.Position = Vector3.new(22, y, 0)
		p.Parent = m
		return p
	end
	local root = part("HumanoidRootPart", Vector3.new(2, 2, 1), 3.1)
	root.AssemblyLinearVelocity = Vector3.zero
	local upper = part("UpperTorso", Vector3.new(2, 1.6, 1), 3.4)
	local arm = part("RightUpperArm", Vector3.new(1, 1.2, 1), 3.6)
	part("RightHand", Vector3.new(0.3, 0.3, 0.3), 2.2)
	part("Head", Vector3.new(1.2, 1.2, 1.2), 4.8)
	local sh = Instance.new("Motor6D"); sh.Name = "RightShoulder"; sh.Part0 = upper; sh.Part1 = arm; sh.Transform = CFrame.new(); sh.Parent = arm
	local w = Instance.new("Motor6D"); w.Name = "Waist"; w.Part0 = root; w.Part1 = upper; w.Transform = CFrame.new(); w.Parent = upper
	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.HipHeight = 2.0
	hum.WalkSpeed = 16
	hum.Health = 100
	hum.Parent = m
	m.PrimaryPart = root
	m.Parent = workspace
	plr.Character = m
	sig(plr, "CharacterAdded"):Fire(m)
	return m
end

local nextId = 1000
local function addPlayer(name, isLocal)
	local plr = Instance.new("Player")
	plr.Name = name
	plr.UserId = nextId
	plr.DisplayName = name
	nextId += 1
	Instance.new("PlayerGui").Parent = plr
	local ps = Instance.new("Folder"); ps.Name = "PlayerScripts"; ps.Parent = plr
	-- stand-in for Roblox's PlayerModule (the client reads the move stick to pause footwork assist)
	local pm = Instance.new("ModuleScript")
	pm.Name = "PlayerModule"
	pm.Source = "return { GetControls = function() return { GetMoveVector = function() return Vector3.zero end } end }"
	pm.Parent = ps
	plr.Parent = Players
	table.insert(playerList, plr)
	if isLocal then
		localPlayer = plr
		Players.LocalPlayer = plr
	else
		botInbox[plr] = {}
	end
	sig(Players, "PlayerAdded"):Fire(plr)
	makeCharacter(plr)
	return plr
end
local function removePlayer(plr)
	sig(Players, "PlayerRemoving"):Fire(plr)
	table.remove(playerList, table.find(playerList, plr))
	botInbox[plr] = nil
	if plr.Character then plr.Character:Destroy() end
	plr.Parent = nil
end

-- walking: humanoids move toward MoveTo targets (or bot targets) at their WalkSpeed
local function stepCharacters(dt)
	for _, plr in playerList do
		local char = plr.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not hum or not root then continue end
		local s = slot(hum)
		local target = s.moveTo
		if not target then root.AssemblyLinearVelocity = Vector3.zero; continue end
		local d = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
		local dist = d.Magnitude
		local stepLen = hum.WalkSpeed * dt
		if dist <= math.max(stepLen, 0.05) then
			char:PivotTo(CFrame.new(target.X, root.Position.Y, target.Z) * root.CFrame.Rotation)
			root.AssemblyLinearVelocity = Vector3.zero
			s.moveTo = nil
		else
			local v = d.Unit * hum.WalkSpeed
			char:PivotTo(root.CFrame + v * dt)
			root.AssemblyLinearVelocity = v
		end
	end
end

---------------------------------------------------------------- script loader
-- Lune 0.10's CFrame.lookAt points the frame away from the target; scripts get Roblox's behaviour.
local function lookAt(eye, target, up)
	up = up or Vector3.new(0, 1, 0)
	local look = (target - eye).Unit
	local right = look:Cross(up).Unit
	return CFrame.fromMatrix(eye, right, right:Cross(look))
end
local CFrameLib = setmetatable({ lookAt = lookAt }, { __index = CFrame })

local BASE = {
	math = math, string = string, table = table, coroutine = coroutine, bit32 = bit32, utf8 = utf8, buffer = buffer, debug = debug,
	pairs = pairs, ipairs = ipairs, next = next, select = select, type = type, typeof = typeof, tostring = tostring, tonumber = tonumber,
	pcall = pcall, xpcall = xpcall, error = error, assert = assert, setmetatable = setmetatable, getmetatable = getmetatable,
	rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen, print = print, unpack = table.unpack,
}
local moduleCache = {}
local TweenInfo = { new = function(...) return { ... } end }
local makeEnv
local function requireModule(m)
	assert(typeof(m) == "Instance" and m:IsA("ModuleScript"), "require expects a ModuleScript, got " .. tostring(m))
	local cached = moduleCache[m]
	if cached ~= nil then return cached end
	local fn = luau.load(m.Source, { debugName = m:GetFullName(), environment = makeEnv(m) })
	local result = fn()
	moduleCache[m] = result
	return result
end
makeEnv = function(scriptInst)
	local env = {
		script = scriptInst, game = game, workspace = workspace, require = requireModule,
		Instance = { new = function(class, parent)
			local i = Instance.new(class)
			if parent then i.Parent = parent end
			return i
		end },
		task = taskLib, os = { clock = function() return now end, time = os.time, date = os.date }, tick = function() return now end,
		warn = function(...) print("[warn]", ...) end, TweenInfo = TweenInfo,
	}
	-- Lune copies the environment table, so every global is set explicitly
	for k, v in BASE do if env[k] == nil then env[k] = v end end
	for _, k in { "Vector3", "Vector2", "CFrame", "Color3", "UDim", "UDim2", "Enum", "Ray", "NumberSequence", "ColorSequence",
		"ColorSequenceKeypoint", "NumberSequenceKeypoint", "NumberRange", "Font", "BrickColor", "Rect", "PhysicalProperties" } do
		env[k] = (roblox :: any)[k]
	end
	env.CFrame = CFrameLib
	return env
end
local function runScript(s)
	local fn = luau.load(s.Source, { debugName = s:GetFullName(), environment = makeEnv(s) })
	resume(coroutine.create(fn))
end

---------------------------------------------------------------- scene dump (for a rendered preview)
-- DINK_DUMP=path writes every visible part and the camera to JSON at the sixth shot call.
local dumpPath = process.env.DINK_DUMP
local function dumpScene()
	local serde = require("@lune/serde")
	local parts = {}
	for _, d in workspace:GetDescendants() do
		if not d:IsA("BasePart") or d.Transparency >= 0.99 then continue end
		local cf = d.CFrame
		table.insert(parts, {
			name = d.Name, shape = if d:IsA("Part") then d.Shape.Name else "Block",
			cf = { cf:GetComponents() }, size = { d.Size.X, d.Size.Y, d.Size.Z },
			color = { d.Color.R, d.Color.G, d.Color.B }, transparency = d.Transparency, material = d.Material.Name,
		})
	end
	local cam = workspace.CurrentCamera
	-- lay out the HUD the way Roblox does (UDim2 + anchor, UIListLayout, UIScale) at two screen sizes
	local function layoutGui(w, h)
		cam.ViewportSize = Vector2.new(w, h)
		sig(cam, "changed:ViewportSize"):Fire()
		local inset = 58
		local out = {}
		local function color(c) return { c.R, c.G, c.B } end
		local function place(obj, cx, cy, cw, ch, K, fixedX, fixedY)
			if not obj:IsA("GuiObject") or not obj.Visible then return end
			local sc = obj:FindFirstChildOfClass("UIScale")
			local k = K * (if sc then sc.Scale else 1)
			local sz, pos, an = obj.Size, obj.Position, obj.AnchorPoint
			local w2, h2 = sz.X.Scale * cw + sz.X.Offset * k, sz.Y.Scale * ch + sz.Y.Offset * k
			local x = fixedX or (cx + pos.X.Scale * cw + pos.X.Offset * K - an.X * w2)
			local y = fixedY or (cy + pos.Y.Scale * ch + pos.Y.Offset * K - an.Y * h2)
			if fixedX == nil and sc then x = cx + pos.X.Scale * cw + pos.X.Offset * K - an.X * w2 end
			local e = { x = x, y = y, w = w2, h = h2, class = obj.ClassName, bg = color(obj.BackgroundColor3), bgT = obj.BackgroundTransparency }
			local corner = obj:FindFirstChildOfClass("UICorner")
			if corner then e.radius = corner.CornerRadius.Offset * k end
			local stroke = obj:FindFirstChildOfClass("UIStroke")
			if stroke and stroke.Transparency < 1 then e.stroke = { color(stroke.Color), stroke.Transparency, stroke.Thickness } end
			if obj:IsA("TextLabel") or obj:IsA("TextButton") then
				e.text = obj.Text
				e.tc = color(obj.TextColor3)
				e.tT = obj.TextTransparency
				e.size = if obj.TextScaled then math.min(h2 * 0.82, 48) else obj.TextSize * k
				e.align = obj.TextXAlignment.Name
				local okF, fontName = pcall(function() return obj.Font.Name end) -- Lune can't read the legacy Font property
				e.bold = okF and (string.find(fontName, "Bold") ~= nil or string.find(fontName, "Black") ~= nil)
				e.wrap = obj.TextWrapped
			end
			table.insert(out, e)
			local list = obj:FindFirstChildOfClass("UIListLayout")
			local kids = {}
			for _, c in obj:GetChildren() do if c:IsA("GuiObject") and c.Visible then table.insert(kids, c) end end
			if list then
				table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
				local pad = list.Padding.Offset * k
				local horiz = list.FillDirection == Enum.FillDirection.Horizontal
				local total = 0
				for i, c in kids do
					local s2 = c.Size
					total += (if horiz then s2.X.Scale * w2 + s2.X.Offset * k else s2.Y.Scale * h2 + s2.Y.Offset * k) + (if i > 1 then pad else 0)
				end
				local cursor = if horiz then x else y + (if list.VerticalAlignment == Enum.VerticalAlignment.Center then (h2 - total) / 2 else 0)
				for _, c in kids do
					local s2 = c.Size
					local cw2, ch2 = s2.X.Scale * w2 + s2.X.Offset * k, s2.Y.Scale * h2 + s2.Y.Offset * k
					if horiz then
						place(c, x, y, w2, h2, k, cursor, y)
						cursor += cw2 + pad
					else
						local cx2 = if list.HorizontalAlignment == Enum.HorizontalAlignment.Right then x + w2 - cw2 else x
						place(c, x, y, w2, h2, k, cx2, cursor)
						cursor += ch2 + pad
					end
				end
			else
				for _, c in kids do place(c, x, y, w2, h2, k) end
			end
		end
		for _, c in localPlayer.PlayerGui.DinkHud:GetChildren() do place(c, 0, inset, w, h - inset, 1) end
		return { w = w, h = h, inset = inset, items = out }
	end
	local desktop = layoutGui(1280, 720)
	local phone = layoutGui(844, 390)
	layoutGui(1280, 720)
	fs.writeFile(dumpPath, serde.encode("json", { parts = parts, camera = { cf = { cam.CFrame:GetComponents() }, fov = 70 }, gui = desktop, guiPhone = phone }))
	print("        wrote scene to " .. dumpPath .. " (" .. #parts .. " parts)")
end

---------------------------------------------------------------- bots
local ORDER = { "dink", "drop", "drive", "speedup", "lob", "putaway" }
local KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six }
local stats = { grades = 0, decisions = 0, serves = 0, points = 0, infoMode = nil, minScale = 1, gradesBySlot = {}, gameOvers = 0, lastScore = nil }

local function pressKey(k)
	local fn = keyHandlers[tostring(k)]
	assert(fn, "no action bound to " .. tostring(k))
	fn("test", Enum.UserInputState.Begin, { KeyCode = k, UserInputType = Enum.UserInputType.Keyboard })
end
local function click()
	sig(game:GetService("UserInputService"), "InputBegan"):Fire({ UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown }, false)
end
local function bestRow(rows, avail)
	for _, r in rows do
		if avail[r[1]] and avail[r[1]][1] then return r end
	end
	return rows[1]
end

-- the local player plays through the real client: number key, mouse aim, click
local function hookLocalBot()
	sig(Remotes.Decision, "OnClientEvent"):Connect(function(d)
		stats.decisions += 1
		taskLib.wait(if d.slow then 0.5 else 0.02)
		local r = bestRow(d.evals, d.avail)
		pressKey(KEYS[table.find(ORDER, r[1])])
		mouseWorld = Vector3.new(r[6], 0, r[7])
		if dumpPath and stats.decisions == 6 then
			taskLib.wait(0.2)
			dumpScene()
		end
		click()
	end)
	sig(Remotes.ServeTurn, "OnClientEvent"):Connect(function(d)
		taskLib.wait(0.8)
		local team = 0
		mouseWorld = Vector3.new(d.box * 5, 0, -15)
		local c = localPlayer.Character
		if c and c:FindFirstChild("HumanoidRootPart").Position.Z < 0 then team = 1 end
		if team == 1 then mouseWorld = Vector3.new(d.box * 5, 0, 15) end
		stats.serves += 1
		click()
	end)
	sig(Remotes.Grade, "OnClientEvent"):Connect(function(g)
		stats.grades += 1
		stats.gradesBySlot[g.slot] = (stats.gradesBySlot[g.slot] or 0) + 1
	end)
	sig(Remotes.Point, "OnClientEvent"):Connect(function(p)
		stats.points += 1
		stats.lastScore = p.score
		if p.gameOver then stats.gameOvers += 1 end
	end)
	sig(Remotes.Info, "OnClientEvent"):Connect(function(i) stats.infoMode = i.mode end)
end

-- other players are headless: they answer the server directly and walk to where it tells them
local function runHeadlessBots()
	for plr, inbox in botInbox do
		local msgs = table.clone(inbox)
		table.clear(inbox)
		for _, m in msgs do
			local a = m.args
			if m.remote == "Decision" then
				local r = bestRow(a[1].evals, a[1].avail)
				botFire(plr, "Commit", r[1], r[6], r[7])
			elseif m.remote == "ServeTurn" then
				local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
				botFire(plr, "Serve", a[1].box * 5, if root and root.Position.Z < 0 then 15 else -15)
			elseif m.remote == "Plan" and a[1] then
				local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
				if hum then slot(hum).moveTo = Vector3.new(a[1][1], 0, a[1][2]) end
			elseif m.remote == "Grade" then
				stats.gradesBySlot[a[1].slot] = (stats.gradesBySlot[a[1].slot] or 0) + 1
			end
		end
	end
end

---------------------------------------------------------------- run
local RunService = game:GetService("RunService")
local function step(seconds)
	local dt = 1 / 60
	for _ = 1, math.floor(seconds / dt) do
		now += dt
		runTimers()
		stepCharacters(dt)
		sig(RunService, "PreSimulation"):Fire(dt)
		sig(RunService, "Heartbeat"):Fire(dt)
		sig(RunService, "RenderStepped"):Fire(dt)
		runHeadlessBots()
		local sc = workspace:GetAttribute("DinkTimeScale")
		if sc and sc > 0 then stats.minScale = math.min(stats.minScale, sc) end
		if #errors > 0 then return end
	end
end
local function check(cond, msg)
	if cond then print("  ok    " .. msg) else fail(msg) end
	if #errors > 0 then
		print(string.format("\n%d error(s)", #errors))
		process.exit(1)
	end
end

print("Dink Engine · place smoke test (" .. placePath .. ")")
runScript(game:GetService("ServerScriptService"):FindFirstChild("DinkServer"))
check(workspace:FindFirstChild("Court") ~= nil, "server built the court")
check(game:GetService("ReplicatedStorage"):FindFirstChild("DinkRigs") ~= nil, "server built the AI rigs (fallback rig path)")
for _, d in game:GetService("ReplicatedStorage").DinkRigs:GetDescendants() do
	if d:IsA("Motor6D") then d.Transform = CFrame.new() end -- the animator sets this in Roblox
end

local me = addPlayer("Tester", true)
local clientScript = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"):FindFirstChild("DinkClient")
hookLocalBot()
runScript(clientScript)
step(2)
check(me.PlayerGui:FindFirstChild("DinkHud") ~= nil, "client built the HUD")
local ai = workspace:FindFirstChild("DinkLocal") and workspace.DinkLocal:FindFirstChild("AIPlayers")
check(ai ~= nil and #ai:GetChildren() == 3, "client shows three AI players")
check(me.Character:FindFirstChild("Paddle") ~= nil, "player got a paddle")

-- solo match through the real client UI
step(800)
print(string.format("        solo: %d points · %d serves · %d decisions · %d grades · min time scale %.3f · score %s",
	stats.points, stats.serves, stats.decisions, stats.grades, stats.minScale, if stats.lastScore then stats.lastScore[1] .. "-" .. stats.lastScore[2] else "-"))
check(stats.points >= 15, "solo match keeps scoring points")
check(stats.decisions >= 10 and stats.grades >= 10, "shot calls reach the server and come back graded")
check(stats.serves >= 1, "player serves through the client")
check(stats.minScale < 0.2, "solo shot calls slow time down")
check(stats.gameOvers >= 1, "a full game finishes")
local ball = workspace.DinkLocal.Markers:FindFirstChild("Ball")
check(ball and ball.CFrame.Position.Y > -10, "ball is drawn on the court")

-- drills from the HUD button
local hud = me.PlayerGui.DinkHud
local drillsButton
for _, d in hud:GetDescendants() do if d:IsA("TextButton") and d.Name == "drills" then drillsButton = d end end
check(drillsButton ~= nil, "HUD has a Drills button")
local g0 = stats.grades
sig(drillsButton, "Activated"):Fire()
step(40)
check(stats.infoMode == "drill", "Drills button starts drill mode")
check(stats.grades > g0 + 3, "drills produce graded shots (" .. (stats.grades - g0) .. ")")

-- three more people join: real-time doubles, no slow motion
local bots = { addPlayer("Bot2", false), addPlayer("Bot3", false), addPlayer("Bot4", false) }
step(3)
stats.minScale = 1
table.clear(stats.gradesBySlot)
step(240)
print(string.format("        doubles: grades by slot %d/%d/%d/%d · min time scale %.3f",
	stats.gradesBySlot[1] or 0, stats.gradesBySlot[2] or 0, stats.gradesBySlot[3] or 0, stats.gradesBySlot[4] or 0, stats.minScale))
check(stats.infoMode == "match", "a second player switches drills back to a match")
check(stats.minScale > 0.99, "no slow motion with four players")
for s = 1, 4 do check((stats.gradesBySlot[s] or 0) > 0, "slot " .. s .. " player hits graded shots") end
check(#workspace.DinkLocal.AIPlayers:GetChildren() == 0, "no AI players shown when the court is full")

-- people leave mid-rally: AI takes over
for _, b in bots do removePlayer(b) end
local p0 = stats.points
step(200)
check(stats.points > p0 + 3, "AI fills the empty slots and play continues (" .. (stats.points - p0) .. " points)")
check(#workspace.DinkLocal.AIPlayers:GetChildren() == 3, "AI players are back on court")

local names = {}
for k, n in remoteLog do table.insert(names, k .. "=" .. n) end
table.sort(names)
print("        remote traffic: " .. table.concat(names, " "))
if #errors > 0 then
	print(string.format("\n%d error(s)", #errors))
	process.exit(1)
end
print("\nsmoke test passed")
