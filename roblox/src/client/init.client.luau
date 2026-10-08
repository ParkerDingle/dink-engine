--!nonstrict
-- Dink Engine client: draws the ball and AI players from the server's simulation, runs the shot-call
-- interface (pick a shot with 1–6, aim with the mouse, click to hit), the eval map and the camera.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Dink = ReplicatedStorage:WaitForChild("Dink")
local C = require(Dink:WaitForChild("Config"))
local P = require(Dink:WaitForChild("Physics"))
local Remotes = ReplicatedStorage:WaitForChild("DinkRemotes")
local Hud = require(script:WaitForChild("Hud"))
local Rigs = require(script:WaitForChild("Rigs"))
local Markers = require(script:WaitForChild("Markers"))

local me = Players.LocalPlayer
local camera = workspace.CurrentCamera

task.spawn(function()
	-- number keys pick shots, so hide the (empty) backpack hotbar
	for _ = 1, 10 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false) then break end
		task.wait(0.5)
	end
end)

local localFolder = Instance.new("Folder")
localFolder.Name = "DinkLocal"
localFolder.Parent = workspace
Rigs.init(localFolder)
Markers.init(localFolder)

-- state -----------------------------------------------------------------------------------------
local info = nil
local mySlot: number? = nil
local myTeam: number? = nil
local scale = 1
local ball = { p = { x = 0, y = -50, z = 0 }, v = { x = 0, y = 0, z = 0 }, netted = false, rolling = false, live = false, team = -1 }
local held: { number }? = nil
local decision = nil
local selected: string? = nil
local called: string? = nil
local serving = nil
local plan = nil
local evalOn, assistOn, camMode = true, true, "court"
local lastMoveTo, lastMoveAt = nil, 0
local isTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local touchAim: { number }? = nil

local controls = nil
task.spawn(function()
	local ok, pm = pcall(function()
		return require(me:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript)
	end)
	if ok and pm then controls = pm:GetControls() end
end)

local function myCharacter()
	local char = me.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, root
end

local hud
local function canCommit(): boolean
	return mySlot ~= nil and ball.live and ball.team >= 0 and ball.team ~= myTeam
end

-- aiming ---------------------------------------------------------------------------------------
local function courtPointFromRay(ray: Ray): (number?, number?)
	if math.abs(ray.Direction.Y) < 1e-4 then return nil, nil end
	local t = (C.SURFACE_Y - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then return nil, nil end
	local p = ray.Origin + ray.Direction * t
	return p.X, p.Z
end
local function aimPoint(): (number?, number?)
	if isTouch then
		if touchAim then return touchAim[1], touchAim[2] end
		return nil, nil
	end
	local m = UserInputService:GetMouseLocation()
	return courtPointFromRay(camera:ViewportPointToRay(m.X, m.Y))
end
local function defaultAim(): (number, number)
	local sg = C.sideSign(myTeam or 0)
	return 0, -sg * 10
end

local function zoneOf(x: number, z: number): (number, number)
	local col = math.clamp(math.floor((x + 10) / (20 / 3)), 0, 2)
	local d = math.abs(z)
	return col, if d < 7 then 0 elseif d < 14.5 then 1 else 2
end
local function evalRange(rows, onlyType: string?)
	local best, worst = -1, 2
	for _, r in rows do
		if onlyType and r[1] ~= onlyType then continue end
		best = math.max(best, r[4]); worst = math.min(worst, r[4])
	end
	return best, worst
end

-- shot calls ------------------------------------------------------------------------------------
local function closeDecision()
	decision = nil
	hud:hideDecision()
end

local function commit(x: number?, z: number?)
	if not mySlot then return end
	if not selected then
		hud:setPrompt("Pick a shot first: 1–6")
		return
	end
	if not x then x, z = aimPoint() end
	if not x then x, z = defaultAim() end
	Remotes.Commit:FireServer(selected, x, z)
	called = selected
	hud:setPrompt("Shot called: " .. (Hud.SHOTS[table.find({ "dink", "drop", "drive", "speedup", "lob", "putaway" }, selected) or 1].name))
	closeDecision()
end

local function serve(x: number?, z: number?)
	if not serving then return end
	if not x then x, z = aimPoint() end
	if not x then x, z = serving.box * 4, -C.sideSign(myTeam or 0) * 16 end
	Remotes.Serve:FireServer(x, z)
	serving = nil
	hud:setPrompt("")
end

local function bestByType(rows)
	local out = {}
	for _, r in rows do out[r[1]] = math.max(out[r[1]] or 0, r[4]) end
	return out
end

local function refreshDecision()
	if not decision then return end
	hud:showDecision(decision, if evalOn then bestByType(decision.evals) else nil, selected,
		if decision.slow then (if isTouch then "Pick a shot, then tap where to hit it" else "Pick a shot, aim with the mouse, click to hit") else "Quick: pick a shot!")
end

local function select(t: string)
	selected = t
	hud:setSelected(t)
	if decision then refreshDecision() end
	if not decision and canCommit() and not called then hud:setPrompt("Click to call it early, or wait for the slow-down") end
end

local function toggle(what: string)
	if what == "eval" then
		evalOn = not evalOn
		refreshDecision()
	elseif what == "assist" then
		assistOn = not assistOn
	elseif what == "camera" then
		camMode = if camMode == "court" then "free" else "court"
		if camMode == "free" then camera.CameraType = Enum.CameraType.Custom end
	elseif what == "level" and info then
		Remotes.Command:FireServer("level", if info.level == "pro" then "club" else "pro")
	end
	hud:setToggles({ eval = evalOn, assist = assistOn, camera = camMode })
end

hud = Hud.new({
	select = select,
	leave = function()
		if mySlot then Remotes.Leave:FireServer(); closeDecision(); hud:setPrompt("Leaving it") end
	end,
	command = function(cmd, arg) Remotes.Command:FireServer(cmd, arg) end,
	toggle = toggle,
})
hud:setToggles({ eval = evalOn, assist = assistOn, camera = camMode })
hud:fit(camera.ViewportSize)
camera:GetPropertyChangedSignal("ViewportSize"):Connect(function() hud:fit(camera.ViewportSize) end)
if isTouch then hud.hints.Text = "Move with the stick · tap a shot · tap the court to hit it" end

-- server events -------------------------------------------------------------------------------
local function stepBall(gdt: number)
	if not ball.live or gdt <= 0 then return end
	local n = math.max(1, math.ceil(gdt / C.SUB))
	local h = gdt / n
	for _ = 1, n do
		local ev = {}
		P.stepBall(ball, h, ev)
		for _, e in ev do
			if e.type == "bounce" and not e.roll then
				Markers.play("bounce", math.clamp(e.speed / 45, 0.05, 0.3), 0.62)
				Markers.showBounce(e.p.x, e.p.z, 0.35)
			end
		end
	end
end

Remotes.Ball.OnClientEvent:Connect(function(d)
	ball.p = { x = d.p[1], y = d.p[2], z = d.p[3] }
	ball.v = { x = d.v[1], y = d.v[2], z = d.v[3] }
	ball.netted, ball.rolling, ball.live, ball.team = d.netted, d.rolling, d.live, d.team
	if d.reset then
		plan = nil
		called = nil
		Markers.setStand(nil, nil)
		return
	end
	if d.hit then
		Markers.play("pop", 0.3 + 0.25 * (d.hit.vol or 0.75), if d.hit.type == "dink" or d.hit.type == "drop" then 1.2 else 0.95)
		if d.hit.slot == mySlot then called = nil; hud:setPrompt("") end
	end
	if d.live then
		if serving then serving = nil; hud:setPrompt("") end
		stepBall(math.clamp(workspace:GetServerTimeNow() - d.at, 0, 0.35) * scale)
		if assistOn and myTeam ~= nil and d.team ~= myTeam and d.team >= 0 then
			local fb = P.predict(ball, 0, 0).firstBounce
			if fb and fb.side == myTeam then Markers.showBounce(fb.x, fb.z, 30) end
		end
	end
end)

Remotes.Pose.OnClientEvent:Connect(function(a)
	held = if a[6] == 0 then { a[3], a[4], a[5] } else nil
	for i = 1, 4 do
		local k = 6 + (i - 1) * 5
		Rigs.pose(i, a[k + 1], a[k + 2], a[k + 3], a[k + 4], a[k + 5])
	end
end)

Remotes.Swing.OnClientEvent:Connect(function(slot, kind)
	Rigs.swing(slot, kind)
end)

Remotes.Info.OnClientEvent:Connect(function(inf)
	info = inf
	mySlot = nil
	for i, s in inf.slots do
		if s.human and s.userId == me.UserId then mySlot = i end
	end
	myTeam = if mySlot then C.teamOf(mySlot) else nil
	Rigs.setSlots(inf.slots, inf.level)
	hud:setInfo(inf, mySlot)
	if not mySlot and camera.CameraType == Enum.CameraType.Scriptable then camera.CameraType = Enum.CameraType.Custom end
end)

Remotes.Point.OnClientEvent:Connect(function(d)
	hud:setScore(d.score)
	closeDecision()
	plan = nil
	called = nil
	serving = nil
	hud:setPrompt("")
	Markers.setStand(nil, nil)
	local mine = myTeam ~= nil and d.winner == myTeam
	local color = Hud.TEAM_COLORS[d.winner]
	if d.gameOver then
		hud:banner(string.format("%s win %d–%d", d.teams[d.winner + 1], d.score[d.winner + 1], d.score[2 - d.winner]), "New game in a few seconds", color, 5.5)
		Markers.play("point", 0.5, if mine then 1.3 else 0.75)
	elseif d.mode == "drill" then
		hud:banner(if mine then "Rally won" else "Rally lost", d.reason, color, 2.6)
	else
		hud:banner(if mine then "Your point" elseif myTeam ~= nil then "Their point" else "Point " .. d.teams[d.winner + 1], d.reason, color, 2)
		Markers.play("point", 0.35, if mine then 1.2 else 0.8)
	end
end)

Remotes.Grade.OnClientEvent:Connect(function(g)
	if g.slot ~= mySlot then return end
	hud:setStats(g.acc, g.n)
	hud:grade(g, true)
end)

Remotes.Decision.OnClientEvent:Connect(function(d)
	decision = { left = d.left, total = math.max(d.left, 0.05), slow = d.slow, evals = d.evals, avail = d.avail, modelled = d.modelled }
	if d.slow then
		selected = nil -- solo play: think about every shot
	elseif selected then
		commit() -- real-time doubles: a pre-selected shot fires at the current aim
		return
	end
	hud:setPrompt("")
	refreshDecision()
end)
Remotes.DecisionEnd.OnClientEvent:Connect(closeDecision)

Remotes.ServeTurn.OnClientEvent:Connect(function(d)
	serving = { box = d.box }
	hud:setPrompt(if isTouch then "Your serve: tap the service box" else "Your serve: aim into the service box and click")
end)

Remotes.Plan.OnClientEvent:Connect(function(st)
	plan = if st then { x = st[1], z = st[2], home = st[3] == true } else nil
	if plan and not plan.home then Markers.setStand(plan.x, plan.z) else Markers.setStand(nil, nil) end
	lastMoveTo = nil
end)

-- input -------------------------------------------------------------------------------------------
local SHOT_KEYS = {
	One = "dink", Two = "drop", Three = "drive", Four = "speedup", Five = "lob", Six = "putaway",
	KeypadOne = "dink", KeypadTwo = "drop", KeypadThree = "drive", KeypadFour = "speedup", KeypadFive = "lob", KeypadSix = "putaway",
}
local keyList = {}
for name in SHOT_KEYS do table.insert(keyList, (Enum.KeyCode :: any)[name]) end

local HIGH = Enum.ContextActionPriority.High.Value
ContextActionService:BindActionAtPriority("DinkShotKeys", function(_, state, input)
	if state ~= Enum.UserInputState.Begin or not mySlot then return Enum.ContextActionResult.Pass end
	select(SHOT_KEYS[input.KeyCode.Name])
	return Enum.ContextActionResult.Sink
end, false, HIGH, table.unpack(keyList))

local function hitAction(): boolean
	if serving then serve(); return true end
	if decision or canCommit() then commit(); return true end
	return false
end
ContextActionService:BindActionAtPriority("DinkHit", function(_, state)
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	return if hitAction() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end, false, HIGH, Enum.KeyCode.Space)

ContextActionService:BindActionAtPriority("DinkToggles", function(_, state, input)
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	local k = input.KeyCode.Name
	if k == "L" then
		if mySlot and (decision or canCommit()) then Remotes.Leave:FireServer(); closeDecision(); hud:setPrompt("Leaving it") end
	elseif k == "E" then toggle("eval")
	elseif k == "F" then toggle("assist")
	elseif k == "C" then toggle("camera")
	end
	return Enum.ContextActionResult.Sink
end, false, HIGH, Enum.KeyCode.L, Enum.KeyCode.E, Enum.KeyCode.F, Enum.KeyCode.C)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then hitAction() end
end)

UserInputService.TouchTapInWorld:Connect(function(pos, processed)
	if processed then return end
	local x, z = courtPointFromRay(camera:ScreenPointToRay(pos.X, pos.Y))
	if not x then return end
	touchAim = { x, z }
	if serving then serve(x, z)
	elseif selected and (decision or canCommit()) then commit(x, z) end
end)

-- per frame -------------------------------------------------------------------------------------
local function updateCamera(dt: number)
	if camMode ~= "court" or not mySlot then
		if camera.CameraType == Enum.CameraType.Scriptable then camera.CameraType = Enum.CameraType.Custom end
		return
	end
	local _, _, root = myCharacter()
	if not root then return end
	camera.CameraType = Enum.CameraType.Scriptable
	local sg = C.sideSign(myTeam or 0)
	local px, pz = root.Position.X, root.Position.Z
	local az = math.abs(pz)
	-- high enough behind the player to see over the net into the other kitchen
	local pos = Vector3.new(px * 0.55, 13.5 + az * 0.05, pz + sg * (12.5 + az * 0.08))
	local look = Vector3.new(px * 0.25, 0.5, pz - sg * 15)
	camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(pos, look), 1 - math.exp(-dt * 5))
end

local function updateAssist()
	if not assistOn or not plan or not mySlot then return end
	if controls and controls:GetMoveVector().Magnitude > 0.1 then lastMoveTo = nil; return end
	local _, hum, root = myCharacter()
	if not hum or not root then return end
	local dx, dz = plan.x - root.Position.X, plan.z - root.Position.Z
	if dx * dx + dz * dz < 0.25 then return end
	if lastMoveTo ~= plan or os.clock() - lastMoveAt > 1.5 then
		hum:MoveTo(Vector3.new(plan.x, root.Position.Y, plan.z))
		lastMoveTo, lastMoveAt = plan, os.clock()
	end
end

local function updateAim()
	local shot = if serving then "serve" else selected
	if not mySlot or not shot or not (serving or decision or canCommit()) then
		Markers.setReticle(nil, nil)
		return
	end
	local x, z = aimPoint()
	if not x then Markers.setReticle(nil, nil); return end
	local a = P.clampAim(shot, { x = x, z = z }, myTeam, if serving then serving.box else nil)
	local color = Color3.fromRGB(255, 176, 72)
	if decision and evalOn and not serving then
		local col, depth = zoneOf(a.x, a.z)
		local best, worst = evalRange(decision.evals)
		for _, r in decision.evals do
			if r[1] == shot and r[2] == col and r[3] == depth then
				local f = if best - worst > 1e-6 then (r[4] - worst) / (best - worst) else 1
				color = Color3.fromRGB(230, 70, 60):Lerp(Color3.fromRGB(70, 215, 120), f)
				break
			end
		end
	end
	Markers.setReticle(a.x, a.z, color)
end

local function updateEval()
	if not decision or not evalOn or myTeam == nil then Markers.setEval(nil); return end
	local side = 1 - myTeam
	local values = {}
	for _, r in decision.evals do
		if selected and r[1] ~= selected then continue end
		local key = side .. ":" .. r[2] .. ":" .. r[3]
		values[key] = math.max(values[key] or 0, r[4])
	end
	local best, worst = evalRange(decision.evals, selected)
	Markers.setEval(values, best, worst)
end

RunService.RenderStepped:Connect(function(dt)
	scale = workspace:GetAttribute("DinkTimeScale") or 1
	stepBall(dt * scale)
	if ball.live then
		Markers.setBall(ball.p.x, ball.p.y, ball.p.z, true)
	elseif held then
		Markers.setBall(held[1], held[2], held[3], true)
	else
		Markers.setBall(0, 0, 0, false)
	end
	Rigs.update(dt, scale)
	Markers.tick()
	if decision then
		decision.left -= dt * scale
		hud:setTimer(decision.left / decision.total)
	end
	updateAim()
	updateEval()
	updateCamera(dt)
	updateAssist()
end)

-- ask for the current state (the first Info may have been sent before this script started)
task.delay(1, function() Remotes.Command:FireServer("info") end)
