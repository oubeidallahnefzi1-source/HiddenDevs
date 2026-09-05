local Players             = game:GetService("Players")
local UserInputService    = game:GetService("UserInputService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")
local Debris              = game:GetService("Debris")
local TweenService        = game:GetService("TweenService")

local Utils               = require(ReplicatedStorage.Main.Modules.Utils.Utils)
local CombatAnimations = ReplicatedStorage.Main.CombatAssets.Animations
local CombatConfig = require(ReplicatedStorage.Main.CombatAssets.Modules.CombatConfig)

local HitBoxModule = {}

local PERFECT_BLOCK_STAGGER_DURATION = CombatConfig.Block.PerfectBlockStaggerDuration
local BACKSTAB_DOT_THRESHOLD = CombatConfig.Block.BackstabDotThreshold

-- checks if attack came from behind the victim using dot product
local function isAttackFromBehind(attackerRoot, victimRoot)
	local offset = attackerRoot.Position - victimRoot.Position
	local flatOffset = Vector3.new(offset.X, 0, offset.Z)
	if flatOffset.Magnitude < 0.01 then
		return false
	end
	local dot = victimRoot.CFrame.LookVector:Dot(flatOffset.Unit)
	return dot < BACKSTAB_DOT_THRESHOLD
end

-- creates a hitbox part that checks for overlaps every heartbeat
function HitBoxModule.HitBox(data)
	local Character         = data.Character
	local Player            = Players:GetPlayerFromCharacter(Character)
	local HumanoidRootPart  = Character:WaitForChild("HumanoidRootPart")
	local Humanoid          = Character:WaitForChild("Humanoid")

	-- unpacking attack settings with fallback defaults
	local Size              = data.Size
	local Ignore            = data.Ignore or {}
	local OnHitFunc         = data.OnHitFunc
	local WeldValue         = data.Weld
	local HBCFrame          = data.CFrame
	local WeldTo            = data.WeldTo or HumanoidRootPart
	local Time              = data.Time or 100
	local Damage            = data.Damage or 0
	local CanPB             = data.CanPB
	local Blockable         = data.Blockable ~= false
	local Combo             = data.Combo or 1
	local AttackerState     = data.MyState
	local PostureCost 		= data.PostureCost or 0
	local DEFAULT_MAX_POSTURE = CombatConfig.Posture.Max

	local HitBox            = Instance.new("Part")
	HitBox.Name             = "HitBox"
	HitBox.Anchored         = true
	HitBox.CanCollide       = false
	HitBox.Size             = Size
	HitBox.Color            = Color3.fromRGB(255, 0, 0)
	HitBox.Transparency     = 1
	HitBox.Massless         = true
	HitBox.Material         = Enum.Material.ForceField
	HitBox.CFrame           = HBCFrame
	HitBox.Parent           = workspace.FX

	-- makes hitbox follow the attacker if needed
	if WeldValue == true then
		local weld            = Instance.new("WeldConstraint")
		weld.Parent           = HitBox
		weld.Part0            = WeldTo
		weld.Part1            = HitBox
	end

	local hitboxParams      = OverlapParams.new()
	hitboxParams.FilterType = Enum.RaycastFilterType.Exclude
	hitboxParams.FilterDescendantsInstances = {Ignore}

	local alreadyHit        = {} -- so we don't hit the same target twice
	local connection

	connection = RunService.Heartbeat:Connect(function()
		if HitBox.Parent == nil then
			connection:Disconnect()
			return
		end

		local parts = workspace:GetPartsInPart(HitBox, hitboxParams)

		for _, part in pairs(parts) do
			local victim     = part:FindFirstAncestorWhichIsA("Model")
			if not victim then continue end

			local ehum       = victim:FindFirstChildOfClass("Humanoid")
			local eroot      = victim:FindFirstChild("HumanoidRootPart")

			if ehum and eroot and not alreadyHit[ehum] and ehum.Health > 0 then
				alreadyHit[ehum] = true

				local attackFromBehind = isAttackFromBehind(HumanoidRootPart, eroot)

				-- perfect block: negates the hit and staggers the attacker instead
				if victim:GetAttribute("PerfectBlock") and not attackFromBehind then
					if Blockable then

						local CombatVFX = ReplicatedStorage.Main.CombatAssets.VFX
						local CombatSounds = ReplicatedStorage.Main.CombatAssets.Sounds

						local BlockHitReactionAnimation = CombatAnimations.BlockHitReaction["BlockHitReaction" .. math.random(1, 2)]

						local Animator = ehum:FindFirstChildOfClass("Animator")
						if not Animator then
							return
						end

						local BlockHitReactionTrack = Animator:LoadAnimation(BlockHitReactionAnimation)
						BlockHitReactionTrack:Play()

						local SoundName = tostring("PerfectBlock" .. math.random(1, 5))
						local Sound = CombatSounds.PerfectBlockSounds:FindFirstChild(SoundName)

						local PerfectBlockSound = Sound:Clone()

						PerfectBlockSound.Parent = eroot
						PerfectBlockSound:Play()

						local ParryVFX      = CombatVFX.Parry:Clone()
						ParryVFX.Parent     = workspace.FX
						ParryVFX.CFrame = eroot.CFrame * CFrame.new(0, -0.3, -1.2)
						Utils.Emit(ParryVFX)

						local PerfectBlockHighlight = Instance.new("Highlight")
						PerfectBlockHighlight.FillTransparency, PerfectBlockHighlight.OutlineTransparency = 1, 1
						PerfectBlockHighlight.FillColor = Color3.new(1, 0.333333, 1)
						PerfectBlockHighlight.Parent = victim

						task.spawn(function()
							local TweenIn = game:GetService("TweenService"):Create(PerfectBlockHighlight, TweenInfo.new(0.1), {FillTransparency = 0.5})
							TweenIn:Play()
							task.wait(0.1)
							local TweenOut = game:GetService("TweenService"):Create(PerfectBlockHighlight, TweenInfo.new(0.1), {FillTransparency = 1})
							TweenOut:Play()
						end)

						task.delay(2, function() PerfectBlockSound:Destroy() end)
						task.delay(2, function() ParryVFX:Destroy() end)

						-- punish the attacker with a stagger
						if AttackerState then
							AttackerState:Stagger(PERFECT_BLOCK_STAGGER_DURATION)
						end
						

					end
					return
				end

				-- regular block: drains posture instead of taking damage
				if victim:GetAttribute("IsBlocking") and not attackFromBehind then
					if Blockable then

						local CombatVFX = ReplicatedStorage.Main.CombatAssets.VFX
						local CombatSounds = ReplicatedStorage.Main.CombatAssets.Sounds

						local BlockHitReactionAnimation = CombatAnimations.BlockHitReaction["BlockHitReaction" .. math.random(1, 2)]

						local Animator = ehum:FindFirstChildOfClass("Animator")
						if not Animator then
							return
						end

						local BlockHitReactionTrack = Animator:LoadAnimation(BlockHitReactionAnimation)
						BlockHitReactionTrack:Play()

						-- picks the block sound based on combo number
						local SoundName = "Block" .. tostring(Combo)
						local Sound = CombatSounds.BlockSounds:FindFirstChild(SoundName)

						local BlockSound = Sound:Clone()

						BlockSound.Parent = eroot
						BlockSound:Play()

						local BlockVFX      = CombatVFX.Block:Clone()
						BlockVFX.Parent     = workspace.FX
						BlockVFX.CFrame = eroot.CFrame * CFrame.new(0, -0.3, -1.2)
						Utils.Emit(BlockVFX)

						local BlockHighlight = Instance.new("Highlight")
						BlockHighlight.FillTransparency, BlockHighlight.OutlineTransparency = 1, 1
						BlockHighlight.FillColor = Color3.new(1, 0.541176, 0.27451)
						BlockHighlight.Parent = victim

						task.spawn(function()
							local TweenIn = game:GetService("TweenService"):Create(BlockHighlight, TweenInfo.new(0.1), {FillTransparency = 0.5})
							TweenIn:Play()
							task.wait(0.1)
							local TweenOut = game:GetService("TweenService"):Create(BlockHighlight, TweenInfo.new(0.1), {FillTransparency = 1})
							TweenOut:Play()
						end)

						task.delay(2, function() BlockSound:Destroy() end)
						task.delay(2, function() BlockVFX:Destroy() end)

						-- drain posture, clamped so it can't go negative
						if PostureCost > 0 then
							local current = victim:GetAttribute("Posture") or DEFAULT_MAX_POSTURE
							victim:SetAttribute("Posture", math.max(0, current - PostureCost))
						end

					end
					return
				end

				-- hit landed for real, no block or parry
				OnHitFunc(ehum, victim)
				
				task.spawn(function()
					HitBoxModule.HitFx(eroot, Damage, Color3.new(255, 0, 0))
				end)
			end
		end
	end)

	-- clean up the hitbox after its active window ends
	task.delay(Time, function()
		if HitBox then HitBox:Destroy() end
	end)
end


-- formats damage text, avoids trailing zeros
local function cleanNum(n)
	return (math.floor(n) == n) and tostring(n) or string.format("%.1f", n)
end

-- floating damage number that pops up and fades
function HitBoxModule.HitFx(HumanoidRootPart, Damage, Color)
	if not HumanoidRootPart then return end

	local Hit = script:WaitForChild("Hit"):Clone()
	local bill = Hit:WaitForChild("Bill")
	local frame = bill:WaitForChild("Frame")
	local text1 = frame:WaitForChild("TextLabel")
	local text2 = text1:FindFirstChild("TextLabel")

	local dmgText = cleanNum(Damage)
	text1.TextColor3 = Color
	text1.Text = dmgText
	if text2 then
		text2.Text = dmgText
	end

	-- randomized start position so multi hit combos don't stack numbers on top of each other
	local startCFrame = HumanoidRootPart.CFrame * CFrame.new(
		math.random(-15, 15) / 10,
		math.random(0, 15) / 10,
		math.random(-15, 15) / 10
	)

	Hit.CFrame = startCFrame
	Hit.Anchored = true
	Hit.CanCollide = false
	Hit.Parent = workspace

	local upHeight = math.random(25, 45) / 10
	local driftX = math.random(-10, 10) / 10
	local driftZ = math.random(-10, 10) / 10
	local spin = math.random(-25, 25)

	-- rises and spins to a peak, then falls and finishes the spin
	local peakCFrame = startCFrame
		* CFrame.new(driftX * 0.5, upHeight, driftZ * 0.5)
		* CFrame.Angles(0, math.rad(spin * 0.5), 0)

	local endCFrame = peakCFrame
		* CFrame.new(driftX * 0.5, -(upHeight + 1), driftZ * 0.5)
		* CFrame.Angles(0, math.rad(spin), 0)

	local upInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local downInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	local upTween = TweenService:Create(Hit, upInfo, { CFrame = peakCFrame })
	local downTween = TweenService:Create(Hit, downInfo, { CFrame = endCFrame })

	upTween:Play()
	upTween.Completed:Connect(function()
		if Hit and Hit.Parent then
			downTween:Play()
		end
	end)

	-- fades the text out before the number gets destroyed
	task.delay(0.15, function()
		if not Hit or not Hit.Parent then return end
		local fadeTweenInfo = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		local fadeGoal = { TextTransparency = 1, TextStrokeTransparency = 1 }
		TweenService:Create(text1, fadeTweenInfo, fadeGoal):Play()
		if text2 then
			TweenService:Create(text2, fadeTweenInfo, fadeGoal):Play()
		end
	end)

	Debris:AddItem(Hit, 1.6)
end

return HitBoxModule
