-- HiddenDevs application - discord adamp240, roblox adamp240. Evidence of ownership= client console in game. Message says scripted by adamp240.
-- Force ability for lightsaber game - handled as a server-owned smart-cast ability. Activate in game by equipping a saber (E on PC) and then press 5 key.
-- The server checks for one valid enemy in front of the caster before the cast starts, then keeps control of the animation timing, rock spawning, hit checks, damage, parries, knockback, ragdolling, and cleanup.
-- The basic flow is: find target -> lock caster -> summon rocks behind caster -> wait for the throw marker -> launch rocks one at a time -> apply hit logic -> remove any leftover objects.
-- Client replication is only used for visuals and local presentation, while the actual gameplay result stays on the server.

local RS = game:GetService("ReplicatedStorage")
local SS = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")

local VelocityModule = require(RS.Modules.Wiki.Handlers.VelocityHandler)
local Manager = require(SS.Modules.Managers.AbilityManager)
local Replicator = require(SS.Modules["Handler & Replicator"].Replicator)
local Damage = require(SS.Modules["Handler & Replicator"].Damage)
local SpeedManager = require(SS.Modules.Managers.SpeedManager)
local SFXHandler = require(RS.Modules.Wiki.Handlers.SFXHandler)
local RagdollHandler = require(RS.Modules.OS.RagdollHandler)

local AbilityFolder = RS.Assets.Abilities.Force["Fourth Force"]
local DebrisBlock = RS.Modules.OS.CustomRocks.DebrisTypes:FindFirstChild("DebrisBlock")
local Sounds = AbilityFolder:FindFirstChild("Sounds")

-- The animation is preloaded once when this module is required so the first cast is less likely to miss the marker because the asset was still loading.
task.spawn(function()
	local anim = AbilityFolder:FindFirstChild("Animation")
	if anim and anim.AnimationId ~= "" then pcall(function() ContentProvider:PreloadAsync({ anim }) end) end
end)

-- Main balance values. These control the count, shape, timing, target rules, damage split, and final rock impact without needing to touch the ability logic below.
local ROCK_COUNT = 17
local SUMMON_BEHIND = 10
local SPREAD_SIDE = 10
local SIDE_GAP = 4
local HEAD_CLEARANCE = 6.4
local SPREAD_BACK = 8
local HOVER_HEIGHT = 6
local SPREAD_VERT = 6
local RISE_TIME = 2
local HOVER_TIME = 1
local LAUNCH_SPEED = 120
local ROCK_LIFETIME = 1.5
local ROCK_RANGE = 150
local HIT_RADIUS = 4
local KB_FORWARD = 62.5
local KB_UP = 18
local LETHAL_KB_MULT = 3
local SELF_IMMUNE = true
local ROCK_SIZE_MIN = 0.7
local ROCK_SIZE_MAX = 4
local LOCK_SETTLE = 0.35
local THROW_DELAY =  0.4
local PARRY_WINDOW_GRACE = 0.15
local EMERGE_STAGGER = 0.07
local CHARGE_TELEGRAPH = true

-- Targeting and damage are separated from the visual rock settings so the ability can be tuned for fairness without changing the projectile feel.
local TARGET_RANGE = 80
local TARGET_BOX_WIDTH = 28
local TARGET_BOX_HEIGHT = 28
local OVERALL_DAMAGE = 60
local FINALE_DAMAGE_SHARE = 0.3
local FINALE_SIZE_MULT = 1.5
local FINALE_RAGDOLL_TIME = 1.2

-- These values make the barrage feel less mechanical: rocks vary slightly in size, launch timing, and swerve, while still fading the curve near the target so they can actually connect.
local SIZE_JITTER = 0.06
local ARRIVAL_STAGGER = 0.06
local FINALE_PAUSE = 0.3
local SWERVE_AMOUNT = 0.55
local SWERVE_FREQ = 5
local SWERVE_FADE = 18
local CAST_ROOT_TIME = RISE_TIME + HOVER_TIME

local module = {}
module.__index = module

-- Raycasts for ground placement should ignore characters and temporary effect folders, otherwise rocks can spawn on players, loose debris, or previous ability objects instead of the map.
local function groundRayParams(char)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { char }
	for _,n in ipairs({"Living","Effects","Debris","Rocks"}) do
		local f = workspace:FindFirstChild(n); if f then table.insert(ignore, f) end
	end
	p.FilterDescendantsInstances = ignore
	return p
end

-- The target overlap uses a broad box in front of the caster, but ignores non-character folders so the scan is mainly looking for real Humanoid models.
local function overlapParams(char)
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { char }
	for _,n in ipairs({"Effects","Debris","Rocks","Map","Model"}) do
		local f = workspace:FindFirstChild(n); if f then table.insert(ignore, f) end
	end
	op.FilterDescendantsInstances = ignore
	return op
end

-- Parts from GetPartBoundsInBox can be accessories, limbs, or nested parts, so this walks upward until it finds the character model that owns the part.
local function characterOf(part)
	local m = part
	while m and m.Parent do
		if m:FindFirstChildOfClass("Humanoid") then return m end
		if m == workspace then break end
		m = m.Parent
	end
	return nil
end

-- Sound calls are wrapped so a missing sound asset never breaks the actual ability.
local function playSfx(char, name, ...)
	local s = Sounds and Sounds:FindFirstChild(name)
	if s then pcall(SFXHandler.Play, char, s, ...) end
end
local function stopSfx(char, name)
	local s = Sounds and Sounds:FindFirstChild(name)
	if s then pcall(SFXHandler.Stop, char, s) end
end

function module:AcquireTarget(char, hrp)
	local op = overlapParams(char)
	local boxCF = hrp.CFrame * CFrame.new(0, 0, -TARGET_RANGE * 0.5)
	local boxSize = Vector3.new(TARGET_BOX_WIDTH, TARGET_BOX_HEIGHT, TARGET_RANGE)
	local best, bestDist, seen = nil, nil, {}

	-- The ability only locks one target. If multiple body parts are found for the same character, seen caches that lookup so the same model is not resolved again and again.
	for _, part in ipairs(workspace:GetPartBoundsInBox(boxCF, boxSize, op)) do
		local c = seen[part]
		if c == nil then c = characterOf(part) or false; seen[part] = c end
		if c and c ~= char and not (SELF_IMMUNE and Players:GetPlayerFromCharacter(c) == self.player) then
			local hh = c:FindFirstChildOfClass("Humanoid")
			local chrp = c:FindFirstChild("HumanoidRootPart")
			if hh and hh.Health > 0 and not c:GetAttribute("IsRagdolled") and chrp then
				local d = (chrp.Position - hrp.Position).Magnitude
				if not bestDist or d < bestDist then best, bestDist = c, d end
			end
		end
	end
	return best
end

function module.perform(player, data)
	local self = setmetatable({}, module)
	self.player = player
	self.AbilityData = data
	self.rocks = {}

	-- perform is the entry point from the ability system. It creates one cast instance, validates the caster, and refuses to start if there is no target in the smart-cast box.
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local target = hrp and self:AcquireTarget(char, hrp)
	if not target then
		task.defer(function() self:Finish() end)
		return self
	end

	self._target = target
	Manager.ReplicateToClient(true, script.Name, {reason = "Start", category = script.Parent.Name}, player)
	self:StartAbility(char, hrp)
	return self
end

function module:StartAbility(char, hrp)
	local hum = char:FindFirstChildOfClass("Humanoid")
	self._char = char
	self._hum = hum

	-- The caster is rooted during the wind-up so the server-side animation, charge telegraph, and rock positions all stay lined up.
	self.player:SetAttribute("CannotWalk", true)
	SpeedManager.AddModification(char, "Stunned", SpeedManager.Priorities.Stunned, 0, 0, LOCK_SETTLE + CAST_ROOT_TIME)

	-- These connections make sure the cast does not leave rocks, sounds, or heartbeat loops behind if the character dies or respawns mid-ability.
	if hum then
		self._diedConn = hum.Died:Connect(function() self:Cleanup(); self:Finish() end)
	end
	self._charRemovingConn = self.player.CharacterRemoving:Connect(function(c)
		if c == char then self:Cleanup(); self:Finish() end
	end)

	if CHARGE_TELEGRAPH then
		Manager.ReplicateToClient(true, script.Name, {func = "OnCharge", category = script.Parent.Name, casterChar = char, origin = hrp.Position, look = hrp.CFrame.LookVector, behind = SUMMON_BEHIND, duration = LOCK_SETTLE}, self.player)
	end

	-- Prefer the animation-marker path when the throw animation exists. The marker is used because it keeps the gameplay launch synced to the actual throw pose instead of guessing with a fixed delay.
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local anim = AbilityFolder:FindFirstChild("Animation")
	if animator and anim and anim.AnimationId ~= "" then
		self._hasAnim = true
		task.spawn(function()
			local track = animator:LoadAnimation(anim)
			track.Priority = Enum.AnimationPriority.Action4
			track.Looped = false
			local t0 = os.clock()

			-- LoadAnimation can report a zero length briefly on first use, so this waits a short time before playing so the marker connection is reliable.
			while track.Length <= 0 and os.clock() - t0 < 3 do task.wait() end
			if self._finished then pcall(function() track:Stop() end) return end
			self.Track = track
			track:GetMarkerReachedSignal("Throw"):Connect(function() self:OnThrowMarker() end)

			-- If the marker is missing from the asset, the ability still launches when the track stops instead of getting stuck forever.
			track.Stopped:Connect(function()
				if self._finished then return end
				if not self._launched then self:OnThrowMarker() end
			end)

			-- The small settle gives the telegraph a moment to show before the rocks erupt behind the caster and the throw starts.
			task.wait(LOCK_SETTLE)
			if self._finished or not (self.player.Character == char and char.Parent) then self:Finish() return end
			self:SummonRocks(char, hrp)
			track:Play()
		end)
	else
		-- This fallback keeps the ability usable even before an animation is added. It follows the same summon -> hover -> launch order, just with timers instead of a marker.
		task.delay(LOCK_SETTLE, function()
			if not (self.player.Character == char and char.Parent) then self:Finish() return end
			self:SummonRocks(char, hrp)
			task.delay(RISE_TIME + HOVER_TIME, function()
				self:DoLaunch()
			end)
		end)
	end

	-- A final safety cleanup runs after the longest expected cast window so any missed rock or disconnected state gets removed.
	task.delay(LOCK_SETTLE + RISE_TIME + HOVER_TIME + (ROCK_COUNT - 1) * ARRIVAL_STAGGER * 3 + FINALE_PAUSE + ROCK_LIFETIME + 2, function() self:Cleanup() end)
end

function module:OnThrowMarker()
	if self._throwTriggered or self._launched or self._finished then return end
	self._throwTriggered = true

	-- The marker freezes the character on the throwing pose for a short hold, then the animation resumes at the same time the barrage actually launches.
	if self.Track then pcall(function() self.Track:AdjustSpeed(0) end) end
	task.delay(THROW_DELAY, function()
		if self._finished then return end
		if self.Track then pcall(function() self.Track:AdjustSpeed(1) end) end
		self:DoLaunch()
	end)
end

function module:DoLaunch()
	if self._launched or self._finished then return end
	self._launched = true

	-- All paths call this one method so the rocks cannot double-launch from both the animation marker and the fallback stop event.
	local char = self._char
	if char and char.Parent and (not self._hum or self._hum.Health > 0) then
		self:LaunchRocks(char)
	end
	self:Finish()
end

function module:SummonRocks(char, hrp)
	if not DebrisBlock then return end
	playSfx(char, "Rumble", 3, 90)
	local rp = groundRayParams(char)
	local baseCF = hrp.CFrame
	local look, right = baseCF.LookVector, baseCF.RightVector
	local positions, delays = {}, {}

	-- The rocks are spawned behind the caster using their current facing direction. Their sizes increase across the set, with the final one being treated as the big finishing hit.
	for i = 1, ROCK_COUNT do
		local isFinale = (i == ROCK_COUNT and ROCK_COUNT > 1)
		local frac = (ROCK_COUNT > 1) and ((i - 1) / (ROCK_COUNT - 1)) or 1
		local sortFrac, s
		if isFinale then
			s = ROCK_SIZE_MAX * FINALE_SIZE_MULT
			sortFrac = 9
		else
			frac = math.clamp(frac + (math.random() - 0.5) * 2 * SIZE_JITTER, 0, 1)
			s = ROCK_SIZE_MIN + frac * (ROCK_SIZE_MAX - ROCK_SIZE_MIN)
			sortFrac = frac
		end

		-- Bigger rocks hover higher so the barrage reads clearly, and the finale naturally sits above the rest before launching last.
		local h = HOVER_HEIGHT + (isFinale and 1.15 or frac) * SPREAD_VERT + (math.random() - 0.5) * 1.0
		local back = -look * (SUMMON_BEHIND + (math.random() - 0.5) * SPREAD_BACK * 2)
		local lateral = (math.random() - 0.5) * SPREAD_SIDE * 2
		if math.abs(lateral) < SIDE_GAP and h < HEAD_CLEARANCE then
			local sign = (math.random() < 0.5) and -1 or 1
			lateral = sign * (SIDE_GAP + math.random() * math.max(0, SPREAD_SIDE - SIDE_GAP))
		end
		local side = right * lateral
		local originXZ = hrp.Position + back + side

		-- Each rock raycasts down so it rises from the actual surface below it and copies that surface material/color for better map blending.
		local hit = workspace:Raycast(originXZ + Vector3.new(0, 25, 0), Vector3.new(0, -150, 0), rp)
		local groundY = hit and hit.Position.Y or (hrp.Position.Y - 3)
		local groundPos = Vector3.new(originXZ.X, groundY, originXZ.Z)
		local hoverPos = groundPos + Vector3.new(0, h, 0)

		local rock = DebrisBlock:Clone()
		rock.Anchored = true
		rock.CanCollide = false
		rock.CanQuery = false
		rock.CanTouch = false
		rock.Size = Vector3.new(s, s * (0.7 + math.random()*0.5), s * (0.8 + math.random()*0.4))
		rock:SetAttribute("SizeFrac", sortFrac)
		if hit then rock.Material = hit.Instance.Material; rock.Color = hit.Instance.Color end
		local spin = CFrame.Angles(math.rad(math.random(0,360)), math.rad(math.random(0,360)), math.rad(math.random(0,360)))
		rock.CFrame = CFrame.new(groundPos) * spin
		rock.Parent = workspace:FindFirstChild("Effects") or workspace

		-- The stagger makes the summon feel like the ground is breaking apart instead of every rock appearing at the exact same frame.
		local d = (i - 1) * EMERGE_STAGGER
		task.delay(d, function()
			if rock and rock.Parent then
				TweenService:Create(rock, TweenInfo.new(RISE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = CFrame.new(hoverPos) * spin }):Play()
			end
		end)
		table.insert(self.rocks, rock)
		positions[i] = groundPos
		delays[i] = d
	end

	-- The hum starts after the rise so it matches the hovering charge phase rather than the initial ground eruption.
	task.delay(RISE_TIME, function()
		if self.player.Character == char and char.Parent and not self._finished then
			playSfx(char, "Hum", 1.5, 70, 0, true)
		end
	end)
	Manager.ReplicateToClient(true, script.Name, {func = "OnSummon", category = script.Parent.Name, casterChar = char, positions = positions, delays = delays}, self.player)
end

function module:LaunchRocks(char)
	stopSfx(char, "Hum")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local target = self._target
	local fallback = hrp and hrp.CFrame.LookVector or Vector3.new(0,0,-1)
	fallback = Vector3.new(fallback.X, 0, fallback.Z)
	fallback = fallback.Magnitude > 0 and fallback.Unit or Vector3.new(0,0,-1)
	playSfx(char, "Whoosh", 4, 120)
	Manager.ReplicateToClient(true, script.Name, {func = "OnLaunch", category = script.Parent.Name, casterChar = char, rocks = self.rocks}, self.player)

	-- States hold per-rock runtime data. The rocks are sorted by SizeFrac so smaller flurry rocks go first and the finale rock is delayed until the end.
	local states = {}
	for _, rock in ipairs(self.rocks) do
		if rock and rock.Parent then
			states[#states+1] = { part = rock, traveled = 0, launched = false, dir = fallback,
				frac = rock:GetAttribute("SizeFrac") or 0,
				phase = math.random() * 6.283, swerveSign = (math.random() < 0.5) and -1 or 1, swerveAmt = SWERVE_AMOUNT * (0.3 + math.random() * 1.6), swerveFreq = SWERVE_FREQ * (0.5 + math.random() * 1.5),
				spin = CFrame.Angles(math.rad(math.random(-3,3)), math.rad(math.random(-3,3)), math.rad(math.random(-3,3))) }
		end
	end
	table.sort(states, function(a, b) return a.frac < b.frac end)
	local n = #states
	local startClock = os.clock()
	local t = 0

	-- Each rock gets its own launch time. The last rock gets an extra pause to sell it as the final blow instead of just another small hit.
	for j, st in ipairs(states) do
		if j == n then
			st.biggest = (n > 1)
			st.launchAt = startClock + t + FINALE_PAUSE
		else
			st.launchAt = startClock + t
			t = t + ARRIVAL_STAGGER * (0.15 + math.random() * 2.7)
		end
	end

	-- Total damage stays controlled by OVERALL_DAMAGE, with the finale taking its own share and the rest split across the flurry.
	local flurryDamage = OVERALL_DAMAGE * (1 - FINALE_DAMAGE_SHARE) / math.max(1, n - 1)
	local finaleDamage = OVERALL_DAMAGE * FINALE_DAMAGE_SHARE
	local parryRepFired, parriedAt = false, nil

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		local tHrp = target and target.Parent and target:FindFirstChild("HumanoidRootPart")
		local targetPos = tHrp and tHrp.Position
		local stepLen = LAUNCH_SPEED * dt
		local anyLeft = false

		-- Heartbeat moves every active rock on the server, so hit detection and the visual position stay based on the same projectile state.
		for _, st in ipairs(states) do
			local rock = st.part
			if rock and rock.Parent and not st.dead then
				anyLeft = true
				if not st.launched and now >= st.launchAt then st.launched = true end
				if st.launched then
					if targetPos then
						local to = targetPos - rock.Position
						if to.Magnitude > 0.05 then st.dir = to.Unit end
					end

					-- The swerve is added perpendicular to the homing direction, then fades near the target so the movement looks nicer without ruining the hit chance.
					local finalDir = st.dir
					if targetPos then
						local dist = (targetPos - rock.Position).Magnitude
						local perp = st.dir:Cross(Vector3.yAxis)
						if perp.Magnitude < 0.05 then perp = st.dir:Cross(Vector3.xAxis) end
						if perp.Magnitude > 0 then
							local wob = math.sin(now * st.swerveFreq + st.phase) * st.swerveAmt * st.swerveSign * math.clamp(dist / SWERVE_FADE, 0, 1)
							finalDir = st.dir + perp.Unit * wob
							finalDir = (finalDir.Magnitude > 0) and finalDir.Unit or st.dir
						end
					end

					rock.CFrame = (rock.CFrame + finalDir * stepLen) * st.spin
					st.traveled = st.traveled + stepLen

					if targetPos and (rock.Position - targetPos).Magnitude <= HIT_RADIUS then
						st.dead = true
						local finaleKb, finaleLethal = nil, false
						local parrying = target:GetAttribute("IsParrying")
							or (parriedAt ~= nil and (now - parriedAt) <= PARRY_WINDOW_GRACE)
						if parrying then
							if target:GetAttribute("IsParrying") then parriedAt = now end
							if not parryRepFired then
								parryRepFired = true
								Replicator.ClientRep(true, nil, { V = "IsParried", info = { caster = char, enemyChar = target } })
							end
						else
							-- Damage.Dmg handles block/parry style rules and returns whether this rock was blocked, which decides if the finale is allowed to ragdoll and knock back.
							local blocked = Damage.Dmg(char, target, st.biggest and finaleDamage or flurryDamage, false, script.Name)
							if st.biggest and not blocked then
								local thum = target:FindFirstChildOfClass("Humanoid")
								finaleLethal = (thum and thum.Health <= 0) or false
								finaleKb = Vector3.new(0, KB_UP, KB_FORWARD) * (finaleLethal and LETHAL_KB_MULT or 1)

								-- Player targets receive the final knockback through the replicated hit effect, while NPCs get pushed from the server because they have no client owner.
								if not Players:GetPlayerFromCharacter(target) then
									pcall(function() VelocityModule.Knockback(target, finaleKb, st.dir, nil, true) end)
								end
								pcall(function() RagdollHandler.Enable(target) end)
								task.delay(FINALE_RAGDOLL_TIME, function()
									if target and target.Parent and target:GetAttribute("IsRagdolled") then RagdollHandler.Disable(target) end
								end)
							end
						end

						-- Every hit is replicated so clients can shatter the correct rock and, for player victims, apply the local finale knockback cleanly.
						Manager.ReplicateToClient(true, script.Name, {func = "OnRockHit", category = script.Parent.Name, pos = rock.Position, size = rock.Size, color = rock.Color, material = rock.Material.Name, dir = st.dir, enemyChar = target, casterChar = char, biggest = st.biggest, kbVel = (finaleKb and Players:GetPlayerFromCharacter(target)) and finaleKb or nil, kbDir = (st.biggest and Players:GetPlayerFromCharacter(target)) and st.dir or nil, lethal = finaleLethal}, self.player)
						rock:Destroy()
					elseif st.traveled >= ROCK_RANGE or (now - st.launchAt) >= ROCK_LIFETIME or (target and not target.Parent) then
						-- Missed or expired rocks shrink out instead of staying around in the Effects folder.
						st.dead = true
						pcall(function() TweenService:Create(rock, TweenInfo.new(0.25), { Size = Vector3.new(0.05,0.05,0.05), Transparency = 1 }):Play() end)
						Debris:AddItem(rock, 0.3)
					end
				end
			end
		end
		if not anyLeft then conn:Disconnect() end
	end)
	self._conn = conn

	-- This timeout is another cleanup layer in case the heartbeat loop misses a rock because of target deletion, script errors, or timing edge cases.
	local maxWindow = (n > 0 and (states[n].launchAt - startClock) or 0) + ROCK_LIFETIME + 0.5
	task.delay(maxWindow, function()
		if self._conn then pcall(function() self._conn:Disconnect() end) end
		for _, st in ipairs(states) do
			local rock = st.part
			if rock and rock.Parent and not st.dead then
				st.dead = true
				pcall(function() TweenService:Create(rock, TweenInfo.new(0.3), { Size = Vector3.new(0.05,0.05,0.05) }):Play() end)
				Debris:AddItem(rock, 0.35)
			end
		end
	end)
end

function module:Cleanup()
	if self._cleaned then return end
	self._cleaned = true

	-- Cleanup is for objects and connections that could continue running after the cast has visually ended.
	for _, k in ipairs({"_diedConn", "_charRemovingConn", "_conn"}) do
		if self[k] then pcall(function() self[k]:Disconnect() end) self[k] = nil end
	end
	if self.player then self.player:SetAttribute("CannotWalk", false) end
	if self._char then stopSfx(self._char, "Hum") end
	for _, rock in ipairs(self.rocks or {}) do
		if rock and rock.Parent then rock:Destroy() end
	end
	self.rocks = {}
end

function module:Finish()
	if self._finished then return end
	self._finished = true

	-- Finish tells the ability manager the cast is over. It is separate from Cleanup because the ability can end while leftover rocks still need their own timed cleanup.
	if self._diedConn then pcall(function() self._diedConn:Disconnect() end) self._diedConn = nil end
	if self._charRemovingConn then pcall(function() self._charRemovingConn:Disconnect() end) self._charRemovingConn = nil end
	if self.player then
		self.player:SetAttribute("CannotWalk", false)
		Manager.EndAbility(self.player, script.Name)
	end
end

function module:PerformEnd() end

return module
