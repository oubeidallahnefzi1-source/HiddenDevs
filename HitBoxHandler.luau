-- Discord: Nezz(efsbxk) | Roblox: MOU7EB
-- Combat hitbox module: overlap hitboxes blocking perfect blocks backstabs and a posture meter.
-- ModuleScript: require it from your combat code then call Hitbox.new({...}):Start().

--// Services
local CollectionService = game:GetService("CollectionService") -- tags let ONE loop manage every combatant
local Debris = game:GetService("Debris") -- cleans up short lived effects even if my own code errors first
local RunService = game:GetService("RunService") -- Heartbeat gives a frame synced tick for detection
local TweenService = game:GetService("TweenService")

--// Configuration: every tunable value lives here so balancing never means hunting through logic
local CONFIG = {
	Debug = false, -- when true, makes the hitbox part visible so the detection area can be seen while testing
	BackstabDot = -0.25, -- a dot product below this means the attacker is behind the victim
	MaxPosture = 100, -- "guard health" blocking drains it reaching 0 breaks the guard
	PostureRegenPerSecond = 8,
	PerfectBlockStagger = 1.5,
	GuardBreakStagger = 2,
	DefaultLifetime = 0.25,
	SwingCooldown = 0.6, -- stops prompt spam from stacking hitboxes
	Colors = {
		Hit = Color3.fromRGB(255, 70, 70), -- fromRGB because Color3.new expects 0-1 values
		Block = Color3.fromRGB(255, 138, 70),
		Parry = Color3.fromRGB(255, 85, 255),
		Break = Color3.fromRGB(255, 220, 60),
	},
}

--// Documents exactly what Hitbox.new accepts
type HitboxData = {
	Character: Model, -- the attacker its HumanoidRootPart is the hitbox origin
	Size: Vector3,
	Offset: CFrame, -- hitbox position relative to the attacker's root
	Ignore: { Instance }?,
	Lifetime: number?,
	Damage: number?,
	PostureCost: number?,
	Blockable: boolean?, -- false ignores blocks and parries
	Follow: boolean?, -- true (default) keeps the hitbox on the attacker while active
	OnHit: ((humanoid: Humanoid, victim: Model) -> ())?, -- optional custom hit behaviour
}

--// Helpers -----------------------------------------------------------------

local function flatten(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function isFromBehind(attackerRoot: BasePart, victimRoot: BasePart): boolean
	local offset = flatten(attackerRoot.Position - victimRoot.Position)
	if offset.Magnitude < 0.01 then
		return false -- .Unit on a zero vector is NaN so treat it as a front hit
	end
	local facing = flatten(victimRoot.CFrame.LookVector).Unit
	return facing:Dot(offset.Unit) < CONFIG.BackstabDot -- dot > 0 is in front < 0 is behind
end

local function formatNumber(n: number): string
	return if math.floor(n) == n then tostring(n) else string.format("%.1f", n) -- no trailing ".0"
end

local function stagger(character: Model, duration: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or character:GetAttribute("Staggered") then
		return -- already staggered overlapping timers would restore WalkSpeed 0 as the "original"
	end
	character:SetAttribute("Staggered", true) -- flag other systems (like swing) can read
	local originalSpeed = humanoid.WalkSpeed -- restore the real value not a hardcoded 16
	humanoid.WalkSpeed = 0
	task.delay(duration, function()
		if humanoid.Parent then -- the character may have died during the stagger
			humanoid.WalkSpeed = originalSpeed
			character:SetAttribute("Staggered", nil)
		end
	end)
end

local function flash(character: Model, color: Color3)
	local highlight = Instance.new("Highlight") -- tints the whole character without touching materials
	highlight.FillColor = color
	highlight.FillTransparency = 1 -- starts invisible so the tween can fade it in
	highlight.OutlineTransparency = 1
	highlight.Parent = character
	local fadeIn = TweenService:Create(highlight, TweenInfo.new(0.1), { FillTransparency = 0.5 })
	fadeIn:Play()
	fadeIn.Completed:Connect(function() -- Connect auto disconnects so no connection is leaked
		local fadeOut = TweenService:Create(highlight, TweenInfo.new(0.1), { FillTransparency = 1 })
		fadeOut:Play()
		fadeOut.Completed:Connect(function()
			highlight:Destroy() -- prevents highlights piling up (roblox caps active Highlights)
		end)
	end)
end

local function showText(targetRoot: BasePart, text: string, color: Color3)
	local anchor = Instance.new("Part") -- invisible carrier: tween the Part and the BillboardGui rides along
	anchor.Size = Vector3.one
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false -- hitbox overlap queries must never pick up floating text
	local startPos = targetRoot.Position + Vector3.new(math.random(-15, 15) / 10, math.random(0, 15) / 10, 0) -- random offset so combo numbers do not stack
	anchor.CFrame = CFrame.new(startPos)
	anchor.Parent = workspace

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(140, 40)
	gui.AlwaysOnTop = true
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true -- long words like GUARD BREAK still fit the billboard
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = gui

	local peak = CFrame.new(startPos + Vector3.new(0, math.random(25, 45) / 10, 0))
	local rise = TweenService:Create(anchor, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = peak })
	rise:Play()
	rise.Completed:Connect(function()
		local fall = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In) -- Quad In accelerates like gravity
		TweenService:Create(anchor, fall, { CFrame = peak * CFrame.new(0, -2, 0) }):Play()
	end)
	local fade = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, false, 0.15) -- last arg delays the fade so the text is readable first
	TweenService:Create(label, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, 1.2)
end

--// Hitbox class: one object per attack the metatable lets every hitbox share the same methods
local Hitbox = {}
Hitbox.__index = Hitbox -- failed lookups on an instance fall through to the methods stored here

function Hitbox.new(data: HitboxData)
	local root = data.Character:FindFirstChild("HumanoidRootPart")
	assert(root, "Hitbox.new needs a character with a HumanoidRootPart") -- fail loudly at creation not silently later

	local self = setmetatable({}, Hitbox)
	self.Character = data.Character
	self.Root = root -- cached because it is read every Heartbeat
	self.Offset = data.Offset
	self.Follow = data.Follow ~= false -- nil counts as true only an explicit false disables it
	self.Damage = data.Damage or 0
	self.PostureCost = data.PostureCost or 0
	self.Blockable = data.Blockable ~= false
	self.Lifetime = data.Lifetime or CONFIG.DefaultLifetime
	self.OnHit = data.OnHit
	self.AlreadyHit = {} -- one swing must not hit the same target every frame
	self.Destroyed = false

	local part = Instance.new("Part") -- the detection volume
	part.Name = "HitBox"
	part.Anchored = true
	part.CanCollide = false
	part.Massless = true
	part.Size = data.Size
	part.Color = CONFIG.Colors.Hit
	part.Transparency = if CONFIG.Debug then 0.7 else 1
	part.CFrame = root.CFrame * data.Offset -- multiplying CFrames applies the offset in the attackers local space
	part.Parent = workspace
	self.Part = part

	local ignore = table.clone(data.Ignore or {}) -- clone so the callers table is never mutated
	table.insert(ignore, data.Character) -- an attacker must never hit themselves
	table.insert(ignore, part) -- the hitbox must not detect itself
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	self.Params = params
	return self
end

function Hitbox:Start()
	self.Connection = RunService.Heartbeat:Connect(function()
		self:_step()
	end)
	task.delay(self.Lifetime, function()
		self:Destroy() -- the active window ends after lifetime seconds
	end)
	return self -- allows Hitbox.new(...):Start() chaining
end

function Hitbox:Destroy()
	if self.Destroyed then
		return -- safe to call twice (timer and manual cancel)
	end
	self.Destroyed = true
	if self.Connection then
		self.Connection:Disconnect() -- stops the per frame callback so it cannot leak
	end
	self.Part:Destroy()
	table.clear(self.AlreadyHit)
end

function Hitbox:_step()
	if self.Follow then
		self.Part.CFrame = self.Root.CFrame * self.Offset
	end
	for _, part in workspace:GetPartsInPart(self.Part, self.Params) do
		local victim = part:FindFirstAncestorWhichIsA("Model") -- walk up from the limb to the character
		local humanoid = victim and victim:FindFirstChildOfClass("Humanoid")
		local victimRoot = victim and victim:FindFirstChild("HumanoidRootPart")
		if humanoid and victimRoot and humanoid.Health > 0 and not self.AlreadyHit[humanoid] then
			self.AlreadyHit[humanoid] = true -- marked before resolving so one overlap can never resolve twice
			self:_resolveHit(victim, humanoid, victimRoot)
		end
	end
end

function Hitbox:_resolveHit(victim: Model, humanoid: Humanoid, victimRoot: BasePart)
	local perfect = victim:GetAttribute("PerfectBlock") -- set by the defenders block system during the parry window
	local guarded = perfect or victim:GetAttribute("IsBlocking")
	local behind = isFromBehind(self.Root, victimRoot) -- guards only work against attacks from the front
	if self.Blockable and guarded and not behind then
		if perfect then
			self:_perfectBlock(victim, victimRoot)
		else
			self:_block(victim, victimRoot)
		end
		return -- the hit was blocked so no damage runs
	end
	if guarded and behind then
		showText(victimRoot, "BACKSTAB!", CONFIG.Colors.Hit)
	end
	if self.OnHit then
		self.OnHit(humanoid, victim) -- custom behaviour replaces default damage
	else
		humanoid:TakeDamage(self.Damage) -- TakeDamage respects forcefilds unlike setting Health
	end
	showText(victimRoot, formatNumber(self.Damage), CONFIG.Colors.Hit)
end

function Hitbox:_perfectBlock(victim: Model, victimRoot: BasePart)
	flash(victim, CONFIG.Colors.Parry)
	showText(victimRoot, "PARRY!", CONFIG.Colors.Parry)
	stagger(self.Character, CONFIG.PerfectBlockStagger) -- the attacker is punished instead of the defender
end

function Hitbox:_block(victim: Model, victimRoot: BasePart)
	flash(victim, CONFIG.Colors.Block)
	local posture = math.max(0, (victim:GetAttribute("Posture") or CONFIG.MaxPosture) - self.PostureCost) -- clamped so it never goes negative
	victim:SetAttribute("Posture", posture) -- attributes replicate so client UI can read posture
	showText(victimRoot, string.format("BLOCK %d", posture), CONFIG.Colors.Block)
	if posture <= 0 then
		victim:SetAttribute("IsBlocking", nil) -- guard break forcibly removes the block state
		stagger(victim, CONFIG.GuardBreakStagger)
		showText(victimRoot, "GUARD BREAK!", CONFIG.Colors.Break)
	end
end

--// Posture regeneration: one shared loop for every tagged combatant ----------------------------
local function startPostureRegen()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.5 then
			return -- batching regen twice a second saves per frame work
		end
		local gain = CONFIG.PostureRegenPerSecond * elapsed -- scaled by real time so regen is frame rate independent
		elapsed = 0
		for _, model in CollectionService:GetTagged("Combatant") do
			local posture = model:GetAttribute("Posture")
			if posture and posture < CONFIG.MaxPosture then
				model:SetAttribute("Posture", math.min(CONFIG.MaxPosture, posture + gain))
			end
		end
	end)
end

startPostureRegen() -- begins regenerating posture for every model tagged "Combatant"

return Hitbox
