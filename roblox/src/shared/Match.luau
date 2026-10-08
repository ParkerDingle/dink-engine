--!nocheck
-- Match simulation (port of game/src/sim/match.ts), server-authoritative and free of Roblox APIs so it
-- also runs headless in tests. Any mix of humans and AI can fill the four slots. Human slots get their
-- positions from their characters every tick (setHuman); AI slots are moved by the simulation.
local function req(name) if script then return require(script.Parent[name]) else return require("./" .. name) end end
local C = req("Config")
local R = req("Rules")
local F = req("Features")
local P = req("Physics")
local D = req("Drills")
local S = req("Scorer")

local Match = {}
Match.__index = Match
local TAU = { pro = 0.012, club = 0.045 }

function Match.new(rng)
	local self = setmetatable({}, Match)
	self.rng = rng or math.random
	self.mode = "match" -- match | drill | selfplay
	self.level = "pro"
	self.useModel = true
	self.human = { false, false, false, false }
	self.players = {}
	for i = 1, 4 do
		local team = C.teamOf(i)
		self.players[i] = { i = i, team = team, x = 0, z = 0, vx = 0, vz = 0, rot = if team == 0 then math.pi else 0,
			speed = 15, react = 0.15, reactLeft = 0, depthGoal = 22.8, forced = false, swingT = -1, swingKind = 1, prep = 0, prepKind = 1 }
	end
	self.ball = { p = { x = 0, y = 2, z = 20 }, v = { x = 0, y = 0, z = 0 }, netted = false, rolling = false, live = false,
		bounces = 0, shotNo = 0, lastHitTeam = -1, lastHitter = 0, lastType = "", lastLabel = "", winP = 0 }
	self.rallyTime = 0
	self.timeTarget = 1
	self.score = { 0, 0 }
	self.server = 0
	self.rally = nil
	self.rallyOver = false
	self.serveWait = nil
	self.serveWaitT = 0
	self.serveDelay = 0
	self.gameOver = false
	self.pred = nil
	self.plans = {}
	self.decisions = {}
	self.pending = {}
	self.drillIdx = 1
	self.rallyCount = 0
	self.stats = {}
	self.on = {}
	self.selfplayTau = 0.05
	self.humanReach = 0 -- extra reach for human players, to absorb network lag on Roblox
	self.log = {}
	self.labels = {}
	return self
end

local function emit(self, name, ...)
	local f = self.on[name]
	if f then f(...) end
end

function Match:isAI(i) return self.mode == "selfplay" or not self.human[i] end
function Match:humanCount()
	local n = 0
	for i = 1, 4 do if self.human[i] then n += 1 end end
	return n
end
function Match:teamHasHuman(T) return self.mode ~= "selfplay" and (self.human[T * 2 + 1] or self.human[T * 2 + 2]) end
function Match:rand(a, b) return a + self.rng() * (b - a) end

-- Called by the server every tick for human slots, with the character's court position and velocity.
function Match:setHuman(i, x, z, vx, vz)
	local p = self.players[i]
	p.x, p.z, p.vx, p.vz = x, z, vx, vz
end

---------------------------------------------------------------- state helpers
function Match:engineState(idx, bp, bv)
	local sp = math.sqrt(bv.x * bv.x + bv.y * bv.y + bv.z * bv.z)
	local players = {}
	for i, p in self.players do players[i] = { x = p.x + 10, y = p.z + 22 } end
	return {
		hitTeam = C.teamOf(idx), hitter = idx, players = players, ball = { x = bp.x + 10, y = bp.z + 22 },
		height = if bp.y < 2.3 then 0 elseif bp.y < 4.0 then 1 else 2,
		pace = if sp < 27 then 0 elseif sp < 42 then 1 else 2,
		shotNo = self.ball.shotNo + 1, contactHeightFt = bp.y, incomingSpeed = sp,
	}
end
function Match:evaluate(state)
	if self.useModel then return S.evaluate(state) end
	return R.evaluate(state), false
end
function Match.worldTarget(o) return { x = o.target.x - 10, z = o.target.y - 22 } end
function Match.zoneOf(t)
	local c = C.clamp(math.floor((t.x + 10) / (20 / 3)), 0, 2)
	local d = math.abs(t.z)
	return c, if d < 7 then 0 elseif d < 14.5 then 1 else 2
end
function Match.optionFor(evals, shotType, target)
	local col, depth = Match.zoneOf(target)
	local best, bestD = nil, math.huge
	for _, o in evals do
		if o.type == shotType and o.col == col and math.abs(o.depth - depth) < bestD then best = o; bestD = math.abs(o.depth - depth) end
	end
	if best then return best end
	for _, o in evals do if o.type == shotType then return o end end
	return evals[1]
end
function Match.convertType(shotType, avail)
	local alt = { dink = { "drop", "speedup" }, drop = { "dink", "drive" }, drive = { "speedup", "drop" }, speedup = { "drive", "dink" }, putaway = { "speedup", "drive" }, lob = { "drop" } }
	for _, t in alt[shotType] or {} do if avail[t].ok then return t end end
	for _, t in R.ORDER do if avail[t].ok then return t end end
	return "drop"
end

---------------------------------------------------------------- contact rules
function Match:contactAllowed(s, T, incomingShotNo)
	if s.netted or self.ball.lastHitTeam == T then return false end
	if T == 0 then
		if s.z < 0.4 then return false end
	elseif s.z > -0.4 then
		return false
	end
	if s.bounces == 0 then
		if incomingShotNo <= 2 then return false end         -- two-bounce rule
		if math.abs(s.z) < C.K + 0.3 then return false end   -- no volleys from the kitchen
		return s.y >= 0.6 and s.y <= C.REACH_H
	end
	if s.bounces == 1 then return s.y >= 0.2 and s.y <= 6.2 end
	return false
end
function Match:ballSample()
	local b = self.ball
	return { x = b.p.x, y = b.p.y, z = b.p.z, bounces = b.bounces, netted = b.netted }
end

---------------------------------------------------------------- movement goals
function Match:homeFor(pl)
	local T, sg = pl.team, C.sideSign(pl.team)
	local sideX = if pl.i % 2 == 1 then -4.6 else 4.6
	local depth = pl.depthGoal
	local r = self.rally
	if r and not r.drill then
		if T == r.serverTeam and self.ball.shotNo < 3 then depth = 22.8 end
		if T ~= r.serverTeam and self.ball.shotNo < 2 and pl.i == r.receiverIdx then depth = 22.8 end
	end
	local bx = C.clamp(self.ball.p.x, -8, 8)
	local x = sideX + bx * 0.3
	if self.plans[C.partner(pl.i)] then x = sideX * 0.55 + bx * 0.4 end
	return { x = x, z = sg * depth }
end
function Match:stanceFor(s, pl)
	local sg = C.sideSign(pl.team)
	local off = if pl.x - s.x >= 0 then 1.45 else -1.45
	local z = s.z + sg * 0.5
	if s.bounces == 0 then z = sg * math.max(math.abs(s.z) + 0.5, 7.6) end
	return { x = C.clamp(s.x + off, -15.5, 15.5), z = z }
end
function Match:planFor(idx, pred, now)
	local pl = self.players[idx]
	local T = pl.team
	local up = math.abs(pl.z) < 10.5
	local best, bs, near, ndist = nil, math.huge, nil, math.huge
	for _, s in pred.samples do
		if s.t < now then continue end
		if not self:contactAllowed(s, T, self.ball.shotNo) then continue end
		local st = self:stanceFor(s, pl)
		local dist = math.sqrt((st.x - pl.x) ^ 2 + (st.z - pl.z) ^ 2)
		if dist < ndist then ndist = dist; near = { s = s, st = st, t = s.t, need = dist / pl.speed } end
		local need = math.max(0, dist - 0.8) / pl.speed
		if need > s.t - now - pl.react then continue end
		local sc = if s.bounces == 0 then (if up then 0 else 1.1) else 0.5 + math.abs(s.y - 2.3) * 0.35
		if s.bounces == 0 and s.y > 5.4 then sc -= 0.5 end
		sc += need * 0.4 + (s.t - now) * 0.05
		if sc < bs then bs = sc; best = { s = s, st = st, t = s.t, need = need } end
	end
	if best then return best end
	if near then near.fail = true; return near end
	return nil
end
function Match:setPlan(i, plan)
	self.plans[i] = plan
	if self.human[i] then emit(self, "plan", i, if plan then plan.st else nil) end
end
function Match:assignTeam(T, forceSlot)
	local idxs = if T == 0 then { 1, 2 } else { 3, 4 }
	for _, i in idxs do self:setPlan(i, nil) end
	if not self.pred then return end
	local fb = self.pred.firstBounce
	local willBeOut = fb ~= nil and fb.side == T and (math.abs(fb.x) > C.W + 0.35 or math.abs(fb.z) > C.L + 0.35)
	local cand = {}
	for _, i in idxs do
		local plan = self:planFor(i, self.pred, self.rallyTime)
		if plan then table.insert(cand, { i = i, plan = plan }) end
	end
	if #cand == 0 then return end
	local pick
	if forceSlot then
		for _, c in cand do if c.i == forceSlot then pick = c end end
		pick = pick or cand[1]
	else
		local pool = {}
		for _, c in cand do if not c.plan.fail then table.insert(pool, c) end end
		if #pool == 0 then pool = cand end
		pick = pool[1]
		for _, c in pool do if c.plan.need < pick.plan.need then pick = c end end
	end
	if willBeOut and self:isAI(pick.i) then
		local playIt = not self:teamHasHuman(T) and self.level == "club" and self.rng() < 0.3
		if not playIt then return end
	end
	local pl = self.players[pick.i]
	pl.forced = false
	if self:isAI(pick.i) and self.ball.winP > 0 and self.rng() < self.ball.winP then
		if self.rng() < 0.5 then return end   -- can't get there in time
		pl.forced = true                      -- gets a paddle on it but can't control it
	end
	self:setPlan(pick.i, pick.plan)
end

---------------------------------------------------------------- hitting
function Match:kindFor(pl, bp, shotType)
	if bp.y > 5.0 then return 3 end
	local right = if pl.team == 0 then 1 else -1
	local fore = (bp.x - pl.x) * right > -0.3
	if (shotType == "dink" or shotType == "drop") and bp.y < 2.8 then return if fore then 4 else 5 end
	return if fore then 1 else 2
end
function Match:skillFor(team)
	-- execution scatter and error scale: AI on a team with a human plays like a strong partner
	if self.mode == "selfplay" or self:teamHasHuman(team) then return 0.85, 0.95, TAU.pro end
	if self.level == "pro" then return 0.8, 0.85, TAU.pro end
	return 1.3, 1.35, TAU.club
end
function Match:doHit(idx, shotType, target, o)
	local pl, b = self.players[idx], self.ball
	local T = pl.team
	pl.swingT = 0; pl.prep = 0
	pl.swingKind = if shotType == "serve" then 4 else self:kindFor(pl, b.p, shotType)
	emit(self, "swing", idx, pl.swingKind)
	if shotType ~= "serve" then
		local volley = b.bounces == 0
		if volley and math.abs(pl.z) < C.K then self:point(1 - T, "Fault: volley from the kitchen"); return end
		if volley and b.shotNo <= 2 then self:point(1 - T, "Fault: two-bounce rule"); return end
	end
	local from = { x = b.p.x, y = b.p.y, z = b.p.z }
	local inSpeed = math.sqrt(b.v.x ^ 2 + b.v.y ^ 2 + b.v.z ^ 2)
	local isReturn = b.shotNo + 1 == 2
	local fault, winP = nil, 0
	if o.pErr ~= nil and not o.exact then
		local run = if self.rally then self.rally.softRun else 0
		local errP = C.clamp(o.pErr * (o.errScale or 1) * (1 + 0.09 * run), 0, 0.75)
		if self.rng() < errP then
			local soft = shotType == "dink" or shotType == "drop" or shotType == "lob"
			local r2 = self.rng()
			if soft then
				fault = if r2 < 0.6 then "net" elseif shotType == "lob" then "long" else "popup"
			else
				fault = if r2 < 0.5 then "net" elseif r2 < 0.75 and math.abs(target.x) > 3.4 then "wide" else "long"
			end
		end
		if o.forced then fault = if self.rng() < 0.6 then "net" else "long" end
		local defend = if T == 0 then (if self.level == "pro" then 0.9 else 1.35) else 1.0
		if not fault then winP = C.clamp((o.pWin or 0) * defend, 0, 0.9) end
	end
	b.v = P.launchVelocity(from, target, shotType, { T = T, mult = o.mult, q = o.q, inSpeed = inSpeed, isReturn = isReturn, serveSpeed = o.serveSpeed, fault = fault, exact = o.exact }, self.rng)
	b.p = from
	b.winP = winP
	if self.rally then
		self.rally.softRun = if shotType == "dink" then self.rally.softRun + 1 else 0
		self.rally.bounceChecked = false
	end
	b.live = true; b.rolling = false; b.netted = false; b.bounces = 0
	b.lastHitTeam = T; b.lastHitter = idx; b.shotNo += 1; b.lastType = shotType
	b.lastLabel = o.label or (if shotType == "serve" then "Serve" else R.SHOTS[shotType].name)
	if o.features and self.mode == "selfplay" then table.insert(self.log, { features = o.features, team = T, rally = self.rallyCount }) end
	emit(self, "hit", idx, shotType, if shotType == "drive" or shotType == "speedup" or shotType == "putaway" then 1.2 else 0.75)
	emit(self, "ball")
	for _, i in (if T == 0 then { 1, 2 } else { 3, 4 }) do
		if shotType == "serve" then break end
		local p = self.players[i]
		if b.shotNo == 2 then
			if i == idx then p.depthGoal = 7.9 end
		elseif shotType == "dink" or shotType == "drop" or shotType == "lob" then
			p.depthGoal = 7.9
		else
			p.depthGoal = math.max(7.9, math.abs(p.z) - 6.5)
		end
	end
	for i = 1, 4 do self:setPlan(i, nil) end
	self.pred = P.predict(b, 0, self.rallyTime)
	self:assignTeam(1 - T)
	for _, i in (if T == 0 then { 3, 4 } else { 1, 2 }) do self.players[i].reactLeft = self.players[i].react end
	if self.rally then table.insert(self.rally.shots, { t = self.rallyTime, idx = idx, type = shotType, label = b.lastLabel }) end
end
function Match:aiHit(idx)
	local pl = self.players[idx]
	local st = self:engineState(idx, self.ball.p, self.ball.v)
	local evals = self:evaluate(st)
	local mult, errScale, tau = self:skillFor(pl.team)
	if self.mode == "selfplay" then tau = self.selfplayTau end
	local opt = R.choose(evals, tau, self.rng)
	local zc = R.zoneCenter(1 - pl.team, opt.col, opt.depth)
	local tgt = P.clampAim(opt.type, { x = zc.x - 10 + self:rand(-1.6, 1.6), z = zc.y - 22 + self:rand(-1.1, 1.1) }, pl.team)
	local forced = pl.forced
	pl.forced = false
	local features = if self.mode == "selfplay" then F.featuresFor(st, opt.type, { x = tgt.x + 10, y = tgt.z + 22 }) else nil
	self:doHit(idx, opt.type, tgt, { mult = mult, q = 0.92, label = opt.label, pErr = opt.pErr, pWin = opt.pWin, errScale = errScale, forced = forced, features = features })
end
function Match:serve(idx, target)
	local pl, b = self.players[idx], self.ball
	b.p = { x = pl.x + (if pl.team == 0 then 0.9 else -0.9), y = 1.7, z = pl.z }
	b.v = { x = 0, y = 0, z = 0 }; b.shotNo = 0; b.bounces = 0; b.lastHitTeam = -1
	local mult = self:skillFor(pl.team)
	local sp = if self.human[idx] then 41 elseif self:teamHasHuman(pl.team) then 42 elseif self.level == "pro" then 44 else 38
	self:doHit(idx, "serve", target, { mult = mult, q = 1, label = "Serve", serveSpeed = sp })
end
function Match:userServe(slot, aim)
	if self.serveWait ~= slot or not self.rally then return false end
	self.serveWait = nil
	self:serve(slot, P.clampAim("serve", aim or { x = 0, z = -16 }, C.teamOf(slot), self.rally.boxSign))
	return true
end
function Match:aiServeTarget(idx)
	local s = -C.sideSign(C.teamOf(idx))
	return { x = self.rally.boxSign * self:rand(2.2, 6.8), z = s * self:rand(15, 19.8) }
end

---------------------------------------------------------------- rules
function Match:onBounce(e)
	emit(self, "bounce", e)
	if self.rallyOver then return end
	local b, r = self.ball, self.rally
	local T = b.lastHitTeam
	if T < 0 then return end
	if e.side == T then
		self:point(1 - T, if b.netted then b.lastLabel .. " into the net" else b.lastLabel .. " fault")
		return
	end
	b.bounces += if e.roll then 2 else 1
	if b.bounces == 1 or (e.roll and b.bounces == 2 and not r.bounceChecked) then
		r.bounceChecked = true
		local outX, outZ = math.abs(e.p.x) > C.W + C.BALL_R, math.abs(e.p.z) > C.L + C.BALL_R
		if outX or outZ then self:point(1 - T, b.lastLabel .. (if outZ then " long" else " wide")); return end
		if b.shotNo == 1 then
			if math.abs(e.p.z) <= C.K + C.BALL_R then self:point(1 - T, "Serve landed in the kitchen"); return end
			local sx = if e.p.x >= 0 then 1 else -1
			if sx ~= r.boxSign and math.abs(e.p.x) > C.BALL_R then self:point(1 - T, "Serve in the wrong box"); return end
		end
	end
	if b.bounces >= 2 then
		self:point(T, if b.shotNo == 1 then "Ace" else b.lastLabel .. " winner")
	end
end
function Match:point(winner, reason)
	if self.rallyOver or not self.rally then return end
	self.rallyOver = true
	for i = 1, 4 do self:endDecision(i); self.pending[i] = nil; self:setPlan(i, nil) end
	self.timeTarget = 1
	self.rally.result = { winner = winner, reason = reason }
	table.insert(self.labels, { rally = self.rallyCount, winner = winner })
	if self.mode == "match" or self.mode == "selfplay" then
		self.score[winner + 1] += 1
		self.server = winner
		local a, b = self.score[1], self.score[2]
		if self.mode == "match" and (a >= 11 or b >= 11) and math.abs(a - b) >= 2 then self.gameOver = true end
	end
	emit(self, "point", winner, reason)
end

---------------------------------------------------------------- rally setup
function Match:resetRally()
	self.rallyOver = false; self.rallyTime = 0; self.pred = nil; self.timeTarget = 1; self.serveWait = nil; self.serveWaitT = 0
	for i = 1, 4 do
		self:setPlan(i, nil); self:endDecision(i); self.pending[i] = nil
		local p = self.players[i]
		p.vx, p.vz, p.swingT, p.prep, p.reactLeft, p.forced = 0, 0, -1, 0, 0, false
		local opp = not self:teamHasHuman(p.team)
		p.speed = if opp and self.level == "club" then 12.5 else 15
		p.react = if opp then (if self.level == "pro" then 0.14 else 0.3) else 0.15
	end
	local b = self.ball
	b.netted = false; b.rolling = false; b.bounces = 0; b.winP = 0
	self.rallyCount += 1
end
function Match:newRally()
	self:resetRally()
	local server, receiver, pts = R.rallyStart(self.server, self.score[self.server + 1])
	for i, p in pts do
		local pl = self.players[i]
		pl.x = p.x - 10; pl.z = p.y - 22
		pl.depthGoal = if math.abs(pl.z) < 12 then 7.9 else 22.8
	end
	self.rally = { serverTeam = self.server, serverIdx = server, receiverIdx = receiver, boxSign = if self.players[receiver].x >= 0 then 1 else -1,
		drill = false, shots = {}, userShots = {}, result = nil, bounceChecked = false, softRun = 0 }
	local b = self.ball
	b.live = false; b.shotNo = 0; b.lastHitTeam = -1
	b.p = self:heldBallPos()
	emit(self, "rallyStart")
	if self.human[server] and self.mode ~= "selfplay" then
		self.serveWait = server
		emit(self, "serveTurn", server)
	else
		self.serveDelay = if self.mode == "selfplay" then 0.05 else 1.1
	end
end
function Match:startMatch()
	self.mode = "match"; self.score = { 0, 0 }; self.server = 0; self.gameOver = false; self.stats = {}
	self:newRally()
end
function Match:heldBallPos()
	local pl = self.players[if self.rally then self.rally.serverIdx else 2]
	return { x = pl.x + (if pl.team == 0 then 0.9 else -0.9), y = 2.2, z = pl.z }
end
-- Drill feed to `slot` (the one human in solo play).
function Match:startDrill(i, slot)
	self.mode = "drill"
	self.drillIdx = ((i - 1) % #D) + 1
	local dr = D[self.drillIdx]
	self:resetRally()
	self.gameOver = false
	-- drills are written for the team-0 right slot; mirror the layout if the human is in slot 1
	local mirror = slot == 1
	for k, p in dr.players do
		local pl = self.players[k]
		local x = p[1] - 10
		pl.x = if mirror then -x else x
		pl.z = p[2] - 22
		pl.depthGoal = if math.abs(pl.z) < 10 then 7.9 else math.abs(pl.z)
	end
	if mirror then
		self.players[1].x, self.players[2].x = self.players[2].x, self.players[1].x
		self.players[1].z, self.players[2].z = self.players[2].z, self.players[1].z
	end
	self.rally = { serverTeam = if dr.shotNo == 2 then 1 else 0, serverIdx = 0, receiverIdx = 0, boxSign = 1, drill = true,
		shots = {}, userShots = {}, result = nil, bounceChecked = false, softRun = 0 }
	local u = self.players[slot]
	local from = { x = (if mirror then 10 - dr.from[1] else dr.from[1] - 10), y = 2.6, z = dr.from[2] - 22 }
	local Cp = { x = u.x + (if u.x >= 0 then -1.5 else 1.5), z = u.z - 0.4 }
	local needBounce = dr.shotNo <= 3 or dr.height == 0
	local v
	if not needBounce then
		local hY = ({ 1.5, 3.1, 5.3 })[dr.height + 1]
		local t = ({ 1.05, 0.72, 0.42 })[dr.pace + 1]
		for _ = 1, 30 do
			v = { x = (Cp.x - from.x) / t, z = (Cp.z - from.z) / t, y = (hY - from.y + 0.5 * C.GRAV * t * t) / t }
			local tc = -from.z / v.z
			local yc = from.y + v.y * tc - 0.5 * C.GRAV * tc * tc
			if yc > C.NET_H + 0.3 then break end
			t *= 1.07
		end
	else
		local d = if dr.pace == 0 then 2.2 else 5.5
		local B = { x = Cp.x + (from.x - Cp.x) * 0.08, z = math.max(1.0, Cp.z - d) }
		v = P.launchVelocity(from, B, if dr.pace == 0 then "dink" else "drive", { T = 1, exact = true, clearMul = 1.2, speedMul = if dr.pace == 2 then 0.95 else 0.72 }, self.rng)
	end
	local b = self.ball
	b.p = from; b.v = v; b.live = true; b.lastHitTeam = 1; b.shotNo = dr.shotNo - 1; b.lastLabel = "Feed"; b.lastType = "feed"
	b.lastHitter = if math.abs(self.players[3].x - from.x) < math.abs(self.players[4].x - from.x) then 3 else 4
	emit(self, "rallyStart")
	emit(self, "ball")
	self.pred = P.predict(b, 0, 0)
	self:assignTeam(0, slot)
end

---------------------------------------------------------------- human shot calls
function Match:startDecision(slot, s)
	local prov = self:engineState(slot, { x = s.x, y = s.y, z = s.z }, { x = s.vx, y = s.vy, z = s.vz })
	local evals, modelled = self:evaluate(prov)
	local d = { slot = slot, contactT = s.t, t0 = self.rallyTime, s = s, prov = prov, avail = R.availability(prov), evals = evals, modelled = modelled }
	self.decisions[slot] = d
	if self:humanCount() == 1 then self.timeTarget = 0.085 end
	emit(self, "decision", slot, d)
end
function Match:endDecision(slot)
	if self.decisions[slot] then
		self.decisions[slot] = nil
		emit(self, "decisionEnd", slot)
	end
	if not next(self.decisions) then self.timeTarget = 1 end
end
local VALID = { dink = true, drop = true, drive = true, speedup = true, lob = true, putaway = true }
-- A human commits a shot. Accepted any time a ball is on its way to their team (shots can be called early).
function Match:commit(slot, shotType, aim)
	if not VALID[shotType] or self.rallyOver or not self.ball.live then return false end
	if self.ball.lastHitTeam == C.teamOf(slot) then return false end
	if type(aim) ~= "table" or type(aim.x) ~= "number" or type(aim.z) ~= "number" or aim.x ~= aim.x or aim.z ~= aim.z then return false end
	self.pending[slot] = { type = shotType, aim = { x = C.clamp(aim.x, -30, 30), z = C.clamp(aim.z, -40, 40) } }
	self:endDecision(slot)
	return true
end
function Match:leaveIt(slot)
	if self.rallyOver then return false end
	self.pending[slot] = { leave = true }
	self:endDecision(slot)
	return true
end
function Match:positionQuality(pl, bp)
	local d = math.sqrt((bp.x - pl.x) ^ 2 + (bp.z - pl.z) ^ 2)
	local q = 1 - C.clamp(math.abs(d - 1.6) / 1.6, 0, 1) * 0.75
	if math.sqrt(pl.vx ^ 2 + pl.vz ^ 2) > 9 then q *= 0.85 end
	return C.clamp(q, 0.25, 1)
end
function Match:userHit(slot, auto)
	local b = self.ball
	local bp = { x = b.p.x, y = b.p.y, z = b.p.z }
	local st = self:engineState(slot, bp, b.v)
	local evals, modelled = self:evaluate(st)
	local avail = R.availability(st)
	local pend = self.pending[slot]
	local shotType
	if auto then
		shotType = if avail.drop.ok then "drop" elseif avail.dink.ok then "dink" else Match.convertType("drop", avail)
	else
		shotType = pend.type
	end
	if not avail[shotType].ok then shotType = Match.convertType(shotType, avail) end
	local T = C.teamOf(slot)
	local aim = if auto then { x = 0, z = -C.sideSign(T) * 3.5 } else pend.aim
	local target = P.clampAim(shotType, aim, T)
	-- option zones are in absolute court coordinates for both teams
	local opt = Match.optionFor(evals, shotType, target)
	local best = evals[1]
	local loss = (best.P - opt.P) * 100
	local g = R.grade(loss)
	local q = self:positionQuality(self.players[slot], bp)
	local rec = { slot = slot, t = self.rallyTime, shotNo = b.shotNo + 1, opt = opt, best = best, loss = loss, g = g, auto = auto, modelled = modelled, evals = evals, target = target }
	table.insert(self.rally.userShots, rec)
	local st2 = self.stats[slot] or { n = 0, accSum = 0, grades = {} }
	st2.n += 1; st2.accSum += R.accuracy(loss); st2.grades[g.key] = (st2.grades[g.key] or 0) + 1
	self.stats[slot] = st2
	self.pending[slot] = nil
	self:endDecision(slot)
	emit(self, "userShot", slot, rec)
	self:doHit(slot, shotType, target, { mult = if auto then 1.8 else 1.0, q = q, label = opt.label, pErr = opt.pErr, pWin = opt.pWin, errScale = 1 + 1.2 * (1 - q) + (if auto then 0.8 else 0) })
end

---------------------------------------------------------------- update loop
local function accelTo(pl, tvx, tvz, dt)
	local dvx, dvz = tvx - pl.vx, tvz - pl.vz
	local dv, a = math.sqrt(dvx * dvx + dvz * dvz), 60 * dt
	local k = if dv > a then a / dv else 1
	pl.vx += dvx * k; pl.vz += dvz * k
end
local function moveToward(pl, tgt, dt, vmax)
	local dx, dz = tgt.x - pl.x, tgt.z - pl.z
	local d = math.sqrt(dx * dx + dz * dz)
	local want = if d > 0.05 then math.min(vmax, d * 4.5) else 0
	accelTo(pl, if d > 0.05 then dx / d * want else 0, if d > 0.05 then dz / d * want else 0, dt)
end
function Match:updatePlayers(dt)
	local b = self.ball
	for _, pl in self.players do
		if pl.reactLeft > 0 then pl.reactLeft -= dt end
		local plan = self.plans[pl.i]
		if self:isAI(pl.i) then
			local hold = self.serveWait ~= nil or (not b.live and self.rally ~= nil and not self.rally.drill and not self.rallyOver)
			if hold or pl.reactLeft > 0 then accelTo(pl, 0, 0, dt)
			else moveToward(pl, if plan and not self.rallyOver then plan.st else self:homeFor(pl), dt, pl.speed) end
			pl.x = C.clamp(pl.x + pl.vx * dt, -15.4, 15.4)
			pl.z = if pl.team == 0 then C.clamp(pl.z + pl.vz * dt, 0.7, 31) else C.clamp(pl.z + pl.vz * dt, -31, -0.7)
			pl.rot = (if pl.team == 0 then math.pi else 0) + C.clamp(-pl.vx * 0.02 * C.sideSign(pl.team), -0.3, 0.3)
		end
		if pl.swingT >= 0 then
			pl.swingT += dt / 0.24
			if pl.swingT >= 1 then pl.swingT = -1 end
		end
	end
end
function Match:tryHits()
	local b = self.ball
	if not b.live or self.rallyOver then return end
	local bs = self:ballSample()
	for i = 1, 4 do
		local pl = self.players[i]
		if pl.team == b.lastHitTeam then continue end
		if not self:contactAllowed(bs, pl.team, b.shotNo) then continue end
		local reach = if self:isAI(i) then C.REACH else C.REACH + self.humanReach
		if math.sqrt((b.p.x - pl.x) ^ 2 + (b.p.z - pl.z) ^ 2) > reach then continue end
		if self:isAI(i) then
			local plan = self.plans[i]
			if not plan or self.rallyTime < plan.t - 0.03 then continue end
			self:aiHit(i)
			return
		end
		local pend = self.pending[i]
		if pend and not pend.leave then self:userHit(i, false); return end
		local d = self.decisions[i]
		if d and self.rallyTime >= d.contactT + 0.05 then self:userHit(i, true); return end
	end
end
function Match:checkDecisions()
	if self.rallyOver or not self.pred or not self.ball.live or self.mode == "selfplay" then return end
	for slot = 1, 4 do
		if not self.human[slot] or self.decisions[slot] or self.pending[slot] or not self.plans[slot] then continue end
		local T = C.teamOf(slot)
		if self.ball.lastHitTeam == T then continue end
		local pl = self.players[slot]
		for _, s in self.pred.samples do
			if s.t < self.rallyTime then continue end
			if s.t > self.rallyTime + 0.5 then break end
			if not self:contactAllowed(s, T, self.ball.shotNo) then continue end
			if math.sqrt((s.x - pl.x) ^ 2 + (s.z - pl.z) ^ 2) <= C.REACH + self.humanReach + 1.0 then
				self:startDecision(slot, s)
				break
			end
		end
	end
end
-- Advance the simulation by dt seconds of game time.
function Match:update(dt)
	local r = self.rally
	if not r then return end
	if self.serveWait then
		self.serveWaitT += dt
		self.ball.p = self:heldBallPos()
		self:updatePlayers(dt)
		if self.serveWaitT > 12 then -- don't let an idle player stall the match
			local slot = self.serveWait
			self.serveWait = nil
			self:serve(slot, self:aiServeTarget(slot))
		end
		return
	end
	if not self.ball.live and not self.rallyOver and not r.drill then
		self.serveDelay -= dt
		self.ball.p = self:heldBallPos()
		if self.serveDelay <= 0 then self:serve(r.serverIdx, self:aiServeTarget(r.serverIdx)) end
	end
	local n = math.max(1, math.ceil(dt / C.SUB))
	local h = dt / n
	for _ = 1, n do
		self.rallyTime += h
		if self.ball.live then
			local ev = {}
			local wasNetted = self.ball.netted
			P.stepBall(self.ball, h, ev)
			for _, e in ev do
				if e.type == "bounce" then self:onBounce(e) end
			end
			if self.ball.netted and not wasNetted then emit(self, "ball") end
			self:tryHits()
		end
		self:updatePlayers(h)
	end
	if not self.rallyOver then self:checkDecisions() end
	local lastShot = if #r.shots > 0 then r.shots[#r.shots].t else 0
	if self.ball.live and not self.rallyOver and self.rallyTime - lastShot > 6 then
		self:point(1 - math.max(0, self.ball.lastHitTeam), "Rally reset")
	end
end

---------------------------------------------------------------- headless self-play
function Match.runSelfPlay(nRallies, seed, tau)
	local m = Match.new(C.seeded(seed or 1))
	m.mode = "selfplay"; m.selfplayTau = tau or 0.05; m.level = "pro"
	local res = { rallies = 0, shots = 0, serverWins = 0, reasons = {}, rows = {} }
	for r = 0, nRallies - 1 do
		m.server = r % 2
		m.score = { r % 3, (r // 2) % 3 }
		m:newRally()
		local guard = 0
		while not m.rallyOver and guard < 9000 do m:update(1 / 60); guard += 1 end
		if not m.rallyOver then m:point(0, "Rally reset") end
		local rally = m.rally
		res.rallies += 1
		res.shots += #rally.shots
		if rally.result.winner == rally.serverTeam then res.serverWins += 1 end
		res.reasons[rally.result.reason] = (res.reasons[rally.result.reason] or 0) + 1
	end
	local winners = {}
	for _, l in m.labels do winners[l.rally] = l.winner end
	for _, row in m.log do
		local w = winners[row.rally]
		if w ~= nil then table.insert(res.rows, { features = row.features, won = if row.team == w then 1 else 0 }) end
	end
	return res
end

return Match
