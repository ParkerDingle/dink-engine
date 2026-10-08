--!nonstrict
-- On-screen interface: scoreboard, shot-call panel, grades, banners, drill card and menu.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Hud = {}
Hud.__index = Hud

local SHOTS = {
	{ key = "dink", name = "Dink" }, { key = "drop", name = "Drop" }, { key = "drive", name = "Drive" },
	{ key = "speedup", name = "Speed-up" }, { key = "lob", name = "Lob" }, { key = "putaway", name = "Put-away" },
}
Hud.SHOTS = SHOTS
local GRADE_COLORS = {
	best = Color3.fromRGB(70, 210, 125), good = Color3.fromRGB(150, 210, 90), inacc = Color3.fromRGB(235, 200, 70),
	mistake = Color3.fromRGB(240, 140, 60), blunder = Color3.fromRGB(235, 75, 75),
}
Hud.GRADE_COLORS = GRADE_COLORS
local TEAM_COLORS = { [0] = Color3.fromRGB(240, 120, 60), [1] = Color3.fromRGB(225, 232, 240) }
local PANEL = Color3.fromRGB(14, 18, 24)
local TEXT = Color3.fromRGB(236, 240, 245)
local MUTED = Color3.fromRGB(150, 160, 172)
local ACCENT = Color3.fromRGB(255, 176, 72)

type Props = { [string]: any }
local function new(class: string, props: Props, parent: Instance?): any
	local o = Instance.new(class)
	for k, v in props do (o :: any)[k] = v end
	if parent then o.Parent = parent end
	return o
end
local function round(o: Instance, r: number?)
	new("UICorner", { CornerRadius = UDim.new(0, r or 10) }, o)
end
local function stroke(o: Instance, t: number?)
	new("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Transparency = t or 0.88, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end
local function panel(props: Props, parent: Instance): Frame
	local f = new("Frame", props, parent)
	if props.BackgroundTransparency == nil then f.BackgroundTransparency = 0.18 end
	f.BackgroundColor3 = PANEL
	f.BorderSizePixel = 0
	round(f)
	stroke(f)
	return f
end
local function text(props: Props, parent: Instance): TextLabel
	local t = new("TextLabel", props, parent)
	t.BackgroundTransparency = 1
	if not props.Font then t.Font = Enum.Font.GothamMedium end
	if not props.TextColor3 then t.TextColor3 = TEXT end
	return t
end

export type Callbacks = {
	select: (string) -> (),
	leave: () -> (),
	command: (string, any) -> (),
	toggle: (string) -> (),
}

function Hud.new(cb: Callbacks)
	local self = setmetatable({}, Hud) :: any
	self.cb = cb
	local gui = new("ScreenGui", { Name = "DinkHud", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = false },
		Players.LocalPlayer:WaitForChild("PlayerGui"))
	self.gui = gui

	-- scoreboard
	local sb = panel({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(440, 58) }, gui)
	self.teamA = text({ Position = UDim2.fromOffset(14, 6), Size = UDim2.new(0.5, -60, 0, 22), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Font = Enum.Font.GothamBold, TextColor3 = TEAM_COLORS[0], Text = "Orange" }, sb)
	self.teamB = text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 6), Size = UDim2.new(0.5, -60, 0, 22), TextXAlignment = Enum.TextXAlignment.Right, TextScaled = true, Font = Enum.Font.GothamBold, TextColor3 = TEAM_COLORS[1], Text = "White" }, sb)
	self.score = text({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 2), Size = UDim2.fromOffset(110, 36), TextScaled = true, Font = Enum.Font.GothamBlack, Text = "0 – 0" }, sb)
	self.status = text({ Position = UDim2.fromOffset(14, 34), Size = UDim2.new(1, -28, 0, 18), TextScaled = true, TextColor3 = MUTED, Text = "" }, sb)


	-- right column: stats and menu (mid-height, clear of Roblox's chat at top left and player list at top right)
	local menu = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(200, 380), BackgroundTransparency = 1 }, gui)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center }, menu)
	local st = panel({ LayoutOrder = 0, Size = UDim2.fromOffset(200, 52) }, menu)
	self.stats = text({ Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 20), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Font = Enum.Font.GothamBold, Text = "Accuracy –" }, st)
	self.model = text({ Position = UDim2.fromOffset(12, 28), Size = UDim2.new(1, -24, 0, 16), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, TextColor3 = MUTED, Text = "" }, st)
	self.buttons = {}
	local function button(id: string, label: string, order: number, onClick: () -> ())
		local b = new("TextButton", { Name = id, LayoutOrder = order, Size = UDim2.fromOffset(200, 32), BackgroundColor3 = PANEL, BackgroundTransparency = 0.18, AutoButtonColor = true,
			Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = TEXT, Text = label }, menu)
		round(b, 8)
		stroke(b)
		b.Activated:Connect(onClick)
		self.buttons[id] = b
		return b
	end
	button("match", "New match", 1, function() cb.command("match", nil) end)
	button("drills", "Drills", 2, function() cb.command("drill", 1) end)
	button("repeat", "Repeat drill", 3, function() cb.command("drill", self.drillIdx or 1) end)
	button("next", "Next drill", 4, function() cb.command("nextDrill", nil) end)
	button("level", "Opponents: Pro", 5, function() cb.toggle("level") end)
	button("eval", "Eval map: On  (E)", 6, function() cb.toggle("eval") end)
	button("assist", "Footwork assist: On  (F)", 7, function() cb.toggle("assist") end)
	button("camera", "Camera: Court  (C)", 8, function() cb.toggle("camera") end)

	-- drill card (left)
	local dc = panel({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.45, 0), Size = UDim2.fromOffset(290, 150), Visible = false }, gui)
	self.drillPhase = text({ Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 16), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Font = Enum.Font.GothamBold, TextColor3 = ACCENT, Text = "" }, dc)
	self.drillTitle = text({ Position = UDim2.fromOffset(14, 30), Size = UDim2.new(1, -28, 0, 22), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Font = Enum.Font.GothamBold, Text = "" }, dc)
	self.drillText = text({ Position = UDim2.fromOffset(14, 58), Size = UDim2.new(1, -28, 1, -68), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, TextSize = 14, TextColor3 = MUTED, Text = "" }, dc)
	self.drillCard = dc

	-- shot-call panel (bottom)
	local dp = panel({ AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -14), Size = UDim2.fromOffset(700, 124), Visible = false }, gui)
	self.decTitle = text({ Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -32, 0, 18), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Font = Enum.Font.GothamBold, TextColor3 = ACCENT, Text = "YOUR SHOT" }, dp)
	self.decHint = text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 9), Size = UDim2.new(0.6, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Right, TextScaled = true, TextColor3 = MUTED, Text = "" }, dp)
	local bar = new("Frame", { Position = UDim2.new(0, 16, 0, 30), Size = UDim2.new(1, -32, 0, 4), BackgroundColor3 = Color3.fromRGB(60, 66, 74), BorderSizePixel = 0 }, dp)
	round(bar, 2)
	self.timer = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, bar)
	round(self.timer, 2)
	local row = new("Frame", { Position = UDim2.fromOffset(16, 42), Size = UDim2.new(1, -32, 0, 70), BackgroundTransparency = 1 }, dp)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, row)
	self.chips = {}
	for i, s in SHOTS do
		local b = new("TextButton", { Name = s.key, LayoutOrder = i, Size = UDim2.fromOffset(88, 70), BackgroundColor3 = Color3.fromRGB(32, 38, 46), AutoButtonColor = true, Text = "" }, row)
		round(b, 8)
		local stk = new("UIStroke", { Color = ACCENT, Thickness = 2, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
		text({ Position = UDim2.fromOffset(8, 5), Size = UDim2.fromOffset(16, 14), TextScaled = true, TextColor3 = MUTED, Font = Enum.Font.GothamBold, Text = tostring(i), TextXAlignment = Enum.TextXAlignment.Left }, b)
		local name = text({ Position = UDim2.fromOffset(6, 20), Size = UDim2.new(1, -12, 0, 20), TextScaled = true, Font = Enum.Font.GothamBold, Text = s.name }, b)
		local sub = text({ Position = UDim2.fromOffset(5, 42), Size = UDim2.new(1, -10, 0, 24), TextScaled = true, TextWrapped = true, TextColor3 = MUTED, Text = "" }, b)
		b.Activated:Connect(function() cb.select(s.key) end)
		self.chips[s.key] = { button = b, stroke = stk, name = name, sub = sub }
	end
	local leave = new("TextButton", { Name = "leave", LayoutOrder = 7, Size = UDim2.fromOffset(88, 70), BackgroundColor3 = Color3.fromRGB(32, 38, 46), AutoButtonColor = true, Text = "" }, row)
	round(leave, 8)
	text({ Position = UDim2.fromOffset(8, 5), Size = UDim2.fromOffset(16, 14), TextScaled = true, TextColor3 = MUTED, Font = Enum.Font.GothamBold, Text = "L", TextXAlignment = Enum.TextXAlignment.Left }, leave)
	text({ Position = UDim2.fromOffset(6, 20), Size = UDim2.new(1, -12, 0, 20), TextScaled = true, Font = Enum.Font.GothamBold, Text = "Leave it" }, leave)
	text({ Position = UDim2.fromOffset(6, 44), Size = UDim2.new(1, -12, 0, 18), TextScaled = true, TextColor3 = MUTED, Text = "if it's out" }, leave)
	leave.Activated:Connect(function() cb.leave() end)
	self.decision = dp

	-- grade popup
	local gp = panel({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 78), Size = UDim2.fromOffset(420, 92), Visible = false }, gui)
	self.gGlyph = text({ Position = UDim2.fromOffset(12, 10), Size = UDim2.fromOffset(64, 46), TextScaled = true, Font = Enum.Font.GothamBlack, Text = "!" }, gp)
	self.gName = text({ Position = UDim2.fromOffset(84, 10), Size = UDim2.new(1, -96, 0, 26), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Font = Enum.Font.GothamBlack, Text = "" }, gp)
	self.gLine1 = text({ Position = UDim2.fromOffset(84, 40), Size = UDim2.new(1, -96, 0, 18), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Text = "" }, gp)
	self.gLine2 = text({ Position = UDim2.fromOffset(84, 62), Size = UDim2.new(1, -96, 0, 18), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, TextColor3 = MUTED, Text = "" }, gp)
	self.gradePanel = gp
	self.gradeToken = 0

	-- banner
	local bn = panel({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.36), Size = UDim2.fromOffset(520, 84), Visible = false }, gui)
	self.bTitle = text({ Position = UDim2.fromOffset(16, 10), Size = UDim2.new(1, -32, 0, 36), TextScaled = true, Font = Enum.Font.GothamBlack, Text = "" }, bn)
	self.bSub = text({ Position = UDim2.fromOffset(16, 50), Size = UDim2.new(1, -32, 0, 22), TextScaled = true, TextColor3 = MUTED, Text = "" }, bn)
	self.bannerPanel = bn
	self.bannerToken = 0

	-- prompt + hints
	self.prompt = text({ AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -150), Size = UDim2.fromOffset(600, 26), TextScaled = true, Font = Enum.Font.GothamBold, TextColor3 = ACCENT, Text = "", TextStrokeTransparency = 0.5 }, gui)
	self.hints = text({ AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -10), Size = UDim2.fromOffset(560, 16), TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, TextColor3 = MUTED, TextStrokeTransparency = 0.6,
		Text = "WASD move · 1–6 pick a shot · mouse aim · click or Space hit · L leave it · E eval map · F assist · C camera" }, gui)
	-- scale panels down on small (phone) screens
	self.scales = {}
	for _, o in { sb, menu, dc, dp, gp, bn } do table.insert(self.scales, new("UIScale", {}, o)) end
	return self
end

function Hud:fit(size: Vector2)
	local k = math.clamp(math.min(size.X / 1000, size.Y / 640), 0.5, 1)
	for _, s in self.scales do s.Scale = k end
	self.hints.Visible = size.X > 900
end

function Hud:setInfo(info: any, mySlot: number?)
	self.teamA.Text = info.teams[1]
	self.teamB.Text = info.teams[2]
	self.score.Text = info.score[1] .. " – " .. info.score[2]
	local solo = info.humans == 1 and mySlot ~= nil
	for _, id in { "match", "drills", "level" } do self.buttons[id].Visible = solo end
	self.buttons.next.Visible = solo and info.mode == "drill"
	self.buttons["repeat"].Visible = solo and info.mode == "drill"
	self.buttons.level.Text = "Opponents: " .. (if info.level == "club" then "Club" else "Pro")
	if info.model.enabled then
		self.model.Text = string.format("Trained model · %d shots · AUC %.2f", info.model.rows, info.model.auc)
	else
		self.model.Text = "Rule engine"
	end
	if info.drill then
		self.drillIdx = info.drill.idx
		self.drillCard.Visible = true
		self.drillPhase.Text = string.format("DRILL %d/%d · %s", info.drill.idx, info.drill.n, string.upper(info.drill.phase))
		self.drillTitle.Text = info.drill.title
		self.drillText.Text = info.drill.text
		self.status.Text = "Drill · " .. info.drill.title
	else
		self.drillCard.Visible = false
		if mySlot then
			self.status.Text = if info.humans > 1 then "Doubles · " .. info.humans .. " players · first to 11, win by 2" else "Solo vs AI · first to 11, win by 2"
		else
			self.status.Text = "Spectating · the court is full"
		end
	end
end

function Hud:setScore(score: { number })
	self.score.Text = score[1] .. " – " .. score[2]
end

function Hud:setStats(acc: number, n: number)
	self.stats.Text = if n > 0 then string.format("Accuracy %d%% · %d shots", math.floor(acc + 0.5), n) else "Accuracy –"
end

function Hud:setToggles(t: { eval: boolean, assist: boolean, camera: string })
	self.buttons.eval.Text = "Eval map: " .. (if t.eval then "On" else "Off") .. "  (E)"
	self.buttons.assist.Text = "Footwork assist: " .. (if t.assist then "On" else "Off") .. "  (F)"
	self.buttons.camera.Text = "Camera: " .. (if t.camera == "court" then "Court" else "Free") .. "  (C)"
end

-- d.avail[type] = { ok, why }, bestByType[type] = best win chance for that shot (or nil to hide)
function Hud:showDecision(d: any, bestByType: { [string]: number }?, selected: string?, hint: string)
	self.decision.Visible = true
	self.decHint.Text = hint
	for _, s in SHOTS do
		local chip = self.chips[s.key]
		local a = d.avail[s.key]
		local ok = a and a[1]
		chip.button.BackgroundTransparency = if ok then 0 else 0.55
		chip.name.TextTransparency = if ok then 0 else 0.5
		if not ok then
			chip.sub.Text = a and a[2] or ""
		elseif bestByType and bestByType[s.key] then
			chip.sub.Text = string.format("%d%%", math.floor(bestByType[s.key] * 100 + 0.5))
		else
			chip.sub.Text = ""
		end
	end
	self:setSelected(selected)
end

function Hud:setSelected(selected: string?)
	for key, chip in self.chips do
		chip.stroke.Transparency = if key == selected then 0 else 1
		chip.button.BackgroundColor3 = if key == selected then Color3.fromRGB(58, 48, 34) else Color3.fromRGB(32, 38, 46)
	end
end

function Hud:setTimer(frac: number)
	self.timer.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
end

function Hud:hideDecision()
	self.decision.Visible = false
end

function Hud:setPrompt(s: string)
	self.prompt.Text = s
end

function Hud:grade(g: any, mine: boolean)
	self.gradeToken += 1
	local token = self.gradeToken
	local col = GRADE_COLORS[g.key] or TEXT
	self.gGlyph.Text = g.glyph
	self.gGlyph.TextColor3 = col
	self.gName.Text = (if mine then "" else g.name .. ": ") .. g.grade .. (if g.auto then "  (auto shot)" else "")
	self.gName.TextColor3 = col
	self.gLine1.Text = string.format("%s to the %s · %d%% to win the rally", g.label, g.zone, math.floor(g.p * 100 + 0.5))
	if g.key == "best" then
		self.gLine2.Text = if g.modelled then "Top choice of the trained model" else "Top choice of the rule engine"
	else
		self.gLine2.Text = string.format("Best: %s to the %s · %d%%  (−%.1f)", g.bestLabel, g.bestZone, math.floor(g.bestP * 100 + 0.5), g.loss)
	end
	local gp = self.gradePanel
	gp.Visible = true
	gp.Position = UDim2.new(0.5, 0, 0, 64)
	TweenService:Create(gp, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 0, 78) }):Play()
	task.delay(if mine then 3.2 else 2.2, function()
		if self.gradeToken == token then gp.Visible = false end
	end)
end

function Hud:banner(title: string, sub: string, color: Color3?, seconds: number?)
	self.bannerToken += 1
	local token = self.bannerToken
	self.bTitle.Text = title
	self.bTitle.TextColor3 = color or TEXT
	self.bSub.Text = sub
	self.bannerPanel.Visible = true
	task.delay(seconds or 2.2, function()
		if self.bannerToken == token then self.bannerPanel.Visible = false end
	end)
end

Hud.TEAM_COLORS = TEAM_COLORS
return Hud
