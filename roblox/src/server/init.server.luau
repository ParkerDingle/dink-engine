--!nonstrict
-- Dink Engine server: runs the authoritative match simulation (ReplicatedStorage.Dink.Match) and
-- connects it to players. Up to four people play doubles; AI fills every empty slot, so one person
-- can play alone (with slow-motion shot calls) or four can play together in real time.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Dink = ReplicatedStorage:WaitForChild("Dink")
local C = require(Dink:WaitForChild("Config"))
local Match = require(Dink:WaitForChild("Match"))
local Drills = require(Dink:WaitForChild("Drills"))
local Scorer = require(Dink:WaitForChild("Scorer"))
local Court = require(script:WaitForChild("CourtBuilder"))
local Npc = require(script:WaitForChild("Npc"))
local Remotes = ReplicatedStorage:WaitForChild("DinkRemotes")

Court.build()
Npc.buildRigs()

local match = Match.new()
match.humanReach = 1.2 -- covers the delay between a player's screen and the server
-- Club opponents to start: a player who calls every shot right wins about 70% of rallies against
-- them and about 40% against Pro (measured with the headless match sim). Solo players can switch.
match.level = "club"

-- slot bookkeeping ------------------------------------------------------------------------------
local SLOT_ORDER = { 2, 3, 1, 4 } -- first player: near right; second: across the net; then partners
local slotOf: { [Player]: number } = {}
local playerAt: { [number]: Player } = {}
local holdUntil = { 0, 0, 0, 0 }
local statsOf: { [Player]: { n: number, acc: number } } = {}
local lastCommand: { [Player]: number } = {}

local scale = 1          -- current time scale (slow motion during solo shot calls)
local frozenUntil = 0    -- drill setup pause
local nextAt: number? = nil
local running = false
local lastHit = nil
local poseClock = 0

local function humanPlayers(): number
	local n = 0
	for _ in slotOf do n += 1 end
	return n
end

local function teamName(t: number): string
	local names = {}
	for s = t * 2 + 1, t * 2 + 2 do
		local p = playerAt[s]
		if p then table.insert(names, p.DisplayName) end
	end
	if #names == 0 then return if t == 0 then "Orange AI" else "White AI" end
	return table.concat(names, " & ")
end

local function sendInfo(target: Player?)
	local slots = {}
	for s = 1, 4 do
		local p = playerAt[s]
		slots[s] = { name = if p then p.DisplayName else "AI", userId = if p then p.UserId else 0, human = p ~= nil and match.human[s] == true }
	end
	local drill = nil
	if match.mode == "drill" then
		local d = Drills[match.drillIdx]
		drill = { idx = match.drillIdx, n = #Drills, title = d.title, text = d.text, phase = d.phase, rating = d.rating }
	end
	local info = {
		slots = slots, level = match.level, mode = match.mode, drill = drill, humans = humanPlayers(),
		model = { enabled = Scorer.enabled and match.useModel, auc = Scorer.info and Scorer.info.auc or 0, rows = Scorer.info and Scorer.info.rows or 0 },
		score = { match.score[1], match.score[2] }, teams = { teamName(0), teamName(1) },
	}
	if target then Remotes.Info:FireClient(target, info) else Remotes.Info:FireAllClients(info) end
end

local function updateBoard()
	if match.mode == "drill" then
		local d = Drills[match.drillIdx]
		Court.setBoard("DRILL " .. match.drillIdx .. "/" .. #Drills, d.phase .. " · " .. d.title)
	else
		Court.setBoard(match.score[1] .. "  –  " .. match.score[2], teamName(0) .. "  vs  " .. teamName(1))
	end
end

local function characterParts(plr: Player)
	local char = plr.Character
	if not char then return nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then return nil end
	return char, hum, root
end

-- Put a player's character on the sim position of their slot, facing the net.
local function place(slot: number)
	local plr = playerAt[slot]
	if not plr then return end
	local char, hum, root = characterParts(plr)
	if not char then return end
	local p = match.players[slot]
	local y = C.SURFACE_Y + (if hum.RigType == Enum.HumanoidRigType.R6 then 3 else hum.HipHeight + root.Size.Y / 2)
	local pos = Vector3.new(p.x, y, p.z)
	local face = if C.teamOf(slot) == 0 then Vector3.new(0, 0, -1) else Vector3.new(0, 0, 1)
	char:PivotTo(CFrame.lookAt(pos, pos + face))
	root.AssemblyLinearVelocity = Vector3.zero
	holdUntil[slot] = os.clock() + 0.4
end

local function applySlots()
	for s = 1, 4 do match.human[s] = playerAt[s] ~= nil end
end

-- match flow ------------------------------------------------------------------------------------
local function startMatch()
	applySlots()
	nextAt = nil
	match:startMatch()
	updateBoard()
	sendInfo()
end

local function soloSlot(): number?
	if humanPlayers() ~= 1 then return nil end
	for s = 1, 4 do if playerAt[s] then return s end end
	return nil
end

local function startDrill(i: number)
	local slot = soloSlot()
	if not slot or C.teamOf(slot) ~= 0 then
		startMatch()
		return
	end
	applySlots()
	nextAt = nil
	match:startDrill(i, slot)
	frozenUntil = os.clock() + 1.6
	updateBoard()
	sendInfo()
end

local function advance()
	if humanPlayers() == 0 then
		running = false
		return
	end
	if match.gameOver or (match.mode == "drill" and humanPlayers() ~= 1) then
		startMatch()
		return
	end
	if match.mode == "drill" then
		startDrill(match.drillIdx % #Drills + 1)
		return
	end
	applySlots()
	match:newRally()
	updateBoard()
end

-- simulation events → clients --------------------------------------------------------------------
local function r3(v: number): number return math.floor(v * 1000 + 0.5) / 1000 end

match.on.hit = function(idx, shotType, vol)
	lastHit = { slot = idx, type = shotType, vol = vol }
end
match.on.ball = function()
	local b = match.ball
	Remotes.Ball:FireAllClients({
		p = { b.p.x, b.p.y, b.p.z }, v = { b.v.x, b.v.y, b.v.z }, netted = b.netted, rolling = b.rolling, live = b.live,
		team = b.lastHitTeam, shotNo = b.shotNo, label = b.lastLabel, hit = lastHit, at = workspace:GetServerTimeNow(),
	})
	lastHit = nil
end
match.on.swing = function(idx, kind)
	Remotes.Swing:FireAllClients(idx, kind)
end
match.on.rallyStart = function()
	for s = 1, 4 do
		if playerAt[s] and match.human[s] then place(s) end
	end
	local b = match.ball
	Remotes.Ball:FireAllClients({ p = { b.p.x, b.p.y, b.p.z }, v = { 0, 0, 0 }, netted = false, rolling = false, live = b.live, team = -1, shotNo = 0, at = workspace:GetServerTimeNow(), reset = true })
	sendInfo()
end
match.on.serveTurn = function(slot)
	local plr = playerAt[slot]
	if plr then Remotes.ServeTurn:FireClient(plr, { box = match.rally.boxSign }) end
end
match.on.plan = function(slot, st)
	local plr = playerAt[slot]
	if not plr then return end
	if st then
		Remotes.Plan:FireClient(plr, { r3(st.x), r3(st.z), false })
	elseif match.rally and not match.rallyOver and match.ball.live then
		-- no ball to chase: send the ready position (used by footwork assist)
		local h = match:homeFor(match.players[slot])
		Remotes.Plan:FireClient(plr, { r3(h.x), r3(h.z), true })
	else
		Remotes.Plan:FireClient(plr, nil)
	end
end
match.on.decision = function(slot, d)
	local plr = playerAt[slot]
	if not plr then return end
	local evals = {}
	for k, o in d.evals do
		local t = Match.worldTarget(o)
		evals[k] = { o.type, o.col, o.depth, r3(o.P), o.label, r3(t.x), r3(t.z), o.zone }
	end
	local avail = {}
	for t, a in d.avail do avail[t] = { a.ok, a.why or "" } end
	Remotes.Decision:FireClient(plr, { left = d.contactT - match.rallyTime, slow = match:humanCount() == 1, evals = evals, avail = avail, modelled = d.modelled })
end
match.on.decisionEnd = function(slot)
	local plr = playerAt[slot]
	if plr then Remotes.DecisionEnd:FireClient(plr) end
end
match.on.userShot = function(slot, rec)
	local plr = playerAt[slot]
	local acc, n = 0, 0
	if plr then
		local st = statsOf[plr] or { n = 0, acc = 0 }
		st.n += 1
		st.acc += math.max(0, 100 - 5 * rec.loss)
		statsOf[plr] = st
		acc, n = st.acc / st.n, st.n
		local ls = plr:FindFirstChild("leaderstats")
		local a = ls and ls:FindFirstChild("Accuracy")
		if a then (a :: IntValue).Value = math.floor(acc + 0.5) end
	end
	Remotes.Grade:FireAllClients({
		slot = slot, name = if plr then plr.DisplayName else "AI", key = rec.g.key, grade = rec.g.name, glyph = rec.g.glyph,
		label = rec.opt.label, zone = rec.opt.zone, p = r3(rec.opt.P), bestLabel = rec.best.label, bestZone = rec.best.zone, bestP = r3(rec.best.P),
		loss = r3(rec.loss), auto = rec.auto, acc = acc, n = n, modelled = rec.modelled,
	})
end
match.on.point = function(winner, reason)
	Remotes.Point:FireAllClients({ winner = winner, reason = reason, score = { match.score[1], match.score[2] }, gameOver = match.gameOver, mode = match.mode, teams = { teamName(0), teamName(1) } })
	if match.gameOver then
		for s = winner * 2 + 1, winner * 2 + 2 do
			local plr = playerAt[s]
			local ls = plr and plr:FindFirstChild("leaderstats")
			local w = ls and ls:FindFirstChild("Wins")
			if w then (w :: IntValue).Value += 1 end
		end
		Court.setBoard(match.score[1] .. "  –  " .. match.score[2], teamName(winner) .. " win!")
	else
		updateBoard()
	end
	nextAt = os.clock() + (if match.gameOver then 6 elseif match.mode == "drill" then 3.2 else 2.4)
end

-- players -------------------------------------------------------------------------------------
local function assign(plr: Player)
	for _, s in SLOT_ORDER do
		if not playerAt[s] then
			playerAt[s] = plr
			slotOf[plr] = s
			return s
		end
	end
	return nil
end

-- keep a lone player in the near-right slot so drills and the default camera work for them
local function compact()
	if humanPlayers() ~= 1 then return end
	local plr, slot = next(slotOf)
	if not plr or slot == 2 then return end
	playerAt[slot] = nil
	playerAt[2] = plr
	slotOf[plr] = 2
end

Players.PlayerAdded:Connect(function(plr)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = ls
	local acc = Instance.new("IntValue")
	acc.Name = "Accuracy"
	acc.Parent = ls
	ls.Parent = plr
	local slot = assign(plr)
	plr.CharacterAdded:Connect(function(char)
		local s = slotOf[plr]
		Npc.addPaddle(char, if s then C.teamOf(s) else 0)
		task.defer(function()
			local hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
			if hum then hum.WalkSpeed = C.WALK_SPEED end
			if s and match.human[s] then
				char:WaitForChild("HumanoidRootPart", 5)
				place(s)
			end
		end)
	end)
	if slot and humanPlayers() == 1 then
		running = true
		startMatch()
	elseif slot then
		-- joins at the next rally; until then the AI keeps playing this slot
		if match.mode == "drill" then startMatch() end
		sendInfo()
		updateBoard()
	else
		sendInfo(plr) -- court is full: spectate from the stands
	end
end)

Players.PlayerRemoving:Connect(function(plr)
	local slot = slotOf[plr]
	slotOf[plr] = nil
	statsOf[plr] = nil
	lastCommand[plr] = nil
	if not slot then return end
	playerAt[slot] = nil
	-- the AI takes over from where the player was standing
	match.human[slot] = false
	match.pending[slot] = nil
	match:endDecision(slot)
	if match.serveWait == slot then
		match.serveWait = nil
		match:serve(slot, match:aiServeTarget(slot))
	end
	-- a spectator takes the open slot
	for _, p in Players:GetPlayers() do
		if p ~= plr and not slotOf[p] then
			playerAt[slot] = p
			slotOf[p] = slot
			break
		end
	end
	if humanPlayers() == 0 then running = false; return end
	local last = next(slotOf)
	if humanPlayers() == 1 and last and slotOf[last] ~= 2 then
		compact()
		startMatch()
		return
	end
	sendInfo()
	updateBoard()
end)

-- client requests -------------------------------------------------------------------------------
Remotes.Commit.OnServerEvent:Connect(function(plr, shotType, x, z)
	local slot = slotOf[plr]
	if not slot or not match.human[slot] then return end
	if typeof(shotType) ~= "string" or typeof(x) ~= "number" or typeof(z) ~= "number" then return end
	match:commit(slot, shotType, { x = x, z = z })
end)
Remotes.Leave.OnServerEvent:Connect(function(plr)
	local slot = slotOf[plr]
	if slot and match.human[slot] then match:leaveIt(slot) end
end)
Remotes.Serve.OnServerEvent:Connect(function(plr, x, z)
	local slot = slotOf[plr]
	if not slot or typeof(x) ~= "number" or typeof(z) ~= "number" or x ~= x or z ~= z then return end
	match:userServe(slot, { x = x, z = z })
end)
Remotes.Command.OnServerEvent:Connect(function(plr, cmd, arg)
	if typeof(cmd) ~= "string" or not slotOf[plr] then return end
	local now = os.clock()
	if now - (lastCommand[plr] or 0) < 0.4 then return end
	lastCommand[plr] = now
	if cmd == "info" then
		sendInfo(plr)
		return
	end
	if humanPlayers() ~= 1 then return end -- game settings are only for solo play
	if cmd == "match" then
		startMatch()
	elseif cmd == "drill" then
		startDrill(if typeof(arg) == "number" then math.clamp(math.floor(arg), 1, #Drills) else 1)
	elseif cmd == "nextDrill" then
		startDrill(match.drillIdx % #Drills + 1)
	elseif cmd == "level" then
		match.level = if arg == "club" then "club" else "pro"
		sendInfo()
	elseif cmd == "model" then
		match.useModel = arg == true
		sendInfo()
	end
end)

-- main loop -------------------------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	if not running then return end
	dt = math.min(dt, 0.1)
	local now = os.clock()
	local frozen = now < frozenUntil
	if frozen then
		scale = 0
	else
		local target = match.timeTarget
		scale += (target - scale) * math.min(1, dt * (if target < scale then 14 else 6))
		if math.abs(scale - target) < 0.004 then scale = target end
	end
	if workspace:GetAttribute("DinkTimeScale") ~= scale then workspace:SetAttribute("DinkTimeScale", scale) end

	-- human positions in, walk speed out
	for s = 1, 4 do
		local plr = playerAt[s]
		if not plr or not match.human[s] then continue end
		local _, hum, root = characterParts(plr)
		if not hum then continue end
		local ws = if match.serveWait == s then 0 else C.WALK_SPEED * math.max(scale, 0.0)
		if math.abs(hum.WalkSpeed - ws) > 0.05 then hum.WalkSpeed = ws end
		if now >= holdUntil[s] then
			local v = root.AssemblyLinearVelocity / math.max(scale, 0.05)
			match:setHuman(s, root.Position.X, root.Position.Z, v.X, v.Z)
		end
	end

	if not frozen then match:update(dt * scale) end
	if match.rallyOver and nextAt and now >= nextAt then
		nextAt = nil
		advance()
	end

	-- 20 Hz pose stream for the AI rigs, the held ball and the time scale
	poseClock += dt
	if poseClock >= 0.05 then
		poseClock = 0
		local b = match.ball
		local pose = { r3(match.rallyTime), r3(scale), r3(b.p.x), r3(b.p.y), r3(b.p.z), if b.live then 1 else 0 }
		for i = 1, 4 do
			local p = match.players[i]
			table.insert(pose, r3(p.x)); table.insert(pose, r3(p.z)); table.insert(pose, r3(p.vx)); table.insert(pose, r3(p.vz)); table.insert(pose, r3(p.rot))
		end
		Remotes.Pose:FireAllClients(pose)
	end
end)

print(string.format("[Dink] server ready · model %s", if Scorer.enabled then "loaded" else "off (rule engine)"))
