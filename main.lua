-- Rhythm Battle autoplayer (Rayfield UI)
-- Made with love 💖

local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Config = {
	-- defaults, live values come from the Keys tab
	KeyBinds = {
		[1] = Enum.KeyCode.A,
		[2] = Enum.KeyCode.S,
		[3] = Enum.KeyCode.W,
		[4] = Enum.KeyCode.D,
	},

	-- Input = synthetic key/touch, safest. Remote = fires the game's Notes remote
	-- directly. Most accurate, but server sees perfect hits, easy to flag
	HitMethod = "Input",
	-- random +/- offset sent with remote hits, 0 = dead-center every note
	RemoteJitterSec = 0,

	-- Auto = touch on phone, keyboard on pc
	InputMode = "Auto",
	-- Touch = multi-finger, Mouse = single pointer fallback
	TouchMethod = "Touch",
	-- shift tap point from receptor center if taps land wrong
	TouchXOffset = 0,
	TouchYOffset = 0,
	-- menu overlay eats taps on phone, hide it while playing
	HideUiWhilePlaying = true,

	-- nudge these if hits drift early or late
	HitOffsetPx = 0,
	InputLatency = 0,
	TailOffsetPx = 0,

	LateWindowSec = 0.06,
	LookaheadSec = 0.6,
	MinLookaheadPx = 600,
	TapDuration = 0.02,
	MaxHoldTime = 20,
	LongNoteMinPx = 30,
}

local player = Players.LocalPlayer
local tracked = {}
local processed = {}
local activeLanes = {}
local laneToken = {}
local laneSpeed = {}
local enabled = false
local mainConn
local laneBindControls = {}
local autoToggle

local function getKey(lane)
	local ctl = laneBindControls[lane]
	if ctl and ctl.CurrentKeybind then
		local ok, kc = pcall(function()
			return Enum.KeyCode[ctl.CurrentKeybind]
		end)
		if ok and kc then
			return kc
		end
	end
	return Config.KeyBinds[lane]
end

local laneTouchPos = {}

local function isTouchMode()
	if Config.InputMode == "Touch" then
		return true
	end
	if Config.InputMode == "Keyboard" then
		return false
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- AbsolutePosition ignores the topbar inset, VIM wants real screen coords
local function screenPos(inst)
	local pos = inst.AbsolutePosition + inst.AbsoluteSize / 2
	local gui = inst:FindFirstAncestorWhichIsA("ScreenGui")
	if gui and not gui.IgnoreGuiInset then
		pos = pos + GuiService:GetGuiInset()
	end
	return Vector2.new(pos.X + Config.TouchXOffset, pos.Y + Config.TouchYOffset)
end

-- one entry point for press and release, keyboard or touch
local function sendInput(lane, isDown, receptor)
	if isTouchMode() then
		local p = laneTouchPos[lane]
		if isDown and receptor then
			p = screenPos(receptor)
			laneTouchPos[lane] = p
		end
		if not p then
			return
		end

		if Config.TouchMethod == "Mouse" then
			VirtualInputManager:SendMouseButtonEvent(p.X, p.Y, 0, isDown, game, 0)
		else
			-- touch states: 0 begin, 2 end. lane = finger id
			VirtualInputManager:SendTouchEvent(lane, isDown and 0 or 2, p.X, p.Y)
		end
	else
		VirtualInputManager:SendKeyEvent(isDown, getKey(lane), false, game)
	end
end

-- remote path. mirrors what the game's own NoteInput sends on a hit:
-- Remotes.Notes:FireServer({noteName, noteAttr "T"}, offsetSeconds, lane)
local notesRemote

local function getNotesRemote()
	if notesRemote and notesRemote.Parent then
		return notesRemote
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local r = remotes and remotes:FindFirstChild("Notes")
	notesRemote = (r and r:IsA("RemoteEvent")) and r or nil
	return notesRemote
end

local function fireRemoteHit(lane, note)
	local remote = getNotesRemote()
	if not remote then
		return false
	end

	local j = Config.RemoteJitterSec
	local offset = j > 0 and (math.random() * 2 - 1) * j or 0

	remote:FireServer({ note.Name, note:GetAttribute("T") }, offset, lane)
	-- consume the note, otherwise the game's own miss check fires "NM" later
	note:Destroy()
	return true
end

local function sign(n)
	return n >= 0 and 1 or -1
end

local function edgeY(inst, edge)
	local y = inst.AbsolutePosition.Y
	return edge == "bottom" and (y + inst.AbsoluteSize.Y) or y
end

local function getPlayerIndex()
	local ok, result = pcall(function()
		local file = player:FindFirstChild("File")
		local current = file and file:FindFirstChild("CurrentPlayer")
		return current and current.Value and current.Value.Name == "Player2" and 2 or 1
	end)
	return ok and result or 1
end

local ksCache, ksTime = nil, 0

-- cached half a second, lookups were running every frame
local function getKeySync()
	local t = os.clock()
	if ksCache and ksCache.Parent and t - ksTime < 0.5 then
		return ksCache
	end

	local gui = player:FindFirstChild("PlayerGui")
	local main = gui and gui:FindFirstChild("Main")
	local match = main and main:FindFirstChild("MatchFrame")
	local found = match and match.Visible and match:FindFirstChild("KeySync" .. getPlayerIndex())
	ksCache = found or nil
	ksTime = t
	return found
end

-- dy is the signed distance to the hit line, vel the signed scroll speed
local function shouldHit(dy, vel, dt)
	if vel == 0 then
		return false
	end

	local dyEff = dy + vel * Config.InputLatency
	local approaching = (dyEff > 0 and vel < 0) or (dyEff < 0 and vel > 0)

	if not approaching then
		return math.abs(dyEff) <= math.abs(vel) * Config.LateWindowSec
	end

	return math.abs(dyEff) <= math.abs(vel) * dt * 0.5
end

-- long notes are a head ("6") plus a sibling body ("Hold_6") with an End child
local function findTail(note, notes, scrollsDown)
	local body = notes:FindFirstChild("Hold_" .. note.Name) or note:FindFirstChild("Hold")
	if not body then
		return nil
	end

	local marker = body:FindFirstChild("End")
	if marker and marker:IsA("GuiObject") then
		return marker, "top"
	end
	if body:IsA("GuiObject") then
		return body, scrollsDown and "top" or "bottom"
	end
	return nil
end

local function pressNote(lane, note, notes, receptor, speed)
	laneToken[lane] = (laneToken[lane] or 0) + 1
	local token = laneToken[lane]

	task.spawn(function()
		if activeLanes[lane] then
			sendInput(lane, false, receptor)
			RunService.Heartbeat:Wait()
			if laneToken[lane] ~= token then
				return
			end
		end

		activeLanes[lane] = true
		sendInput(lane, true, receptor)

		local tailInst, edge = findTail(note, notes, speed > 0)
		local isLong, dist, initialSign = false, 0, 1

		if tailInst then
			local offset = edgeY(tailInst, edge) + Config.TailOffsetPx
				- (receptor.AbsolutePosition.Y + Config.HitOffsetPx)
			dist = math.abs(offset)
			initialSign = sign(offset)
			isLong = dist > Config.LongNoteMinPx
		end

		if isLong then
			local startTime = os.clock()
			local lastTime = startTime
			local releaseAt = startTime + dist / math.abs(speed) - Config.InputLatency

			while true do
				if laneToken[lane] ~= token then
					return
				end

				local now = os.clock()
				if now - startTime > Config.MaxHoldTime then
					break
				end

				local frameDt = math.max(now - lastTime, 1 / 240)
				lastTime = now
				local v = laneSpeed[lane] or speed

				if tailInst.Parent and tailInst.Visible then
					local dy = edgeY(tailInst, edge) + Config.TailOffsetPx
						- (receptor.AbsolutePosition.Y + Config.HitOffsetPx)
						+ v * Config.InputLatency

					if sign(dy) ~= initialSign then
						break
					end
					if math.abs(dy) <= math.abs(v) * frameDt * 0.5 then
						break
					end
					-- tail stopped scrolling, don't hang on it
					if now >= releaseAt + 0.3 then
						break
					end
				elseif now >= releaseAt then
					-- tail got removed, fall back to the timer
					break
				end

				RunService.Heartbeat:Wait()
			end
		else
			task.wait(Config.TapDuration)
		end

		if laneToken[lane] == token then
			sendInput(lane, false, receptor)
			activeLanes[lane] = nil
		end
	end)
end

local function releaseAll()
	table.clear(tracked)
	for lane in pairs(Config.KeyBinds) do
		laneToken[lane] = (laneToken[lane] or 0) + 1
		if activeLanes[lane] then
			sendInput(lane, false)
			activeLanes[lane] = nil
		end
	end
end

-- UI

local Window = Rayfield:CreateWindow({
	Name = "AutoPlayer",
	LoadingTitle = "AutoPlayer",
	LoadingSubtitle = "Open-source!",
	ConfigurationSaving = {
		Enabled = true,
		FolderName = "RhythmAutoplayer",
		FileName = "config",
	},
	KeySystem = false,
})

local MainTab = Window:CreateTab("Main", "play")
local TimingTab = Window:CreateTab("Timing", "timer")
local KeysTab = Window:CreateTab("Keys", "keyboard")

autoToggle = MainTab:CreateToggle({
	Name = "Autoplay",
	CurrentValue = false,
	Flag = "AutoplayEnabled",
	Callback = function(value)
		enabled = value
		if not enabled then
			releaseAll()
		end
	end,
})

MainTab:CreateKeybind({
	Name = "Toggle key",
	CurrentKeybind = "F6",
	HoldToInteract = false,
	Flag = "ToggleKey",
	Callback = function()
		autoToggle:Set(not enabled)
	end,
})

local function firstOption(opt)
	return type(opt) == "table" and opt[1] or opt
end

MainTab:CreateDropdown({
	Name = "Hit method",
	Options = { "Input", "Remote" },
	CurrentOption = { "Input" },
	MultipleOptions = false,
	Flag = "HitMethod",
	Callback = function(opt)
		releaseAll()
		Config.HitMethod = firstOption(opt)
		if Config.HitMethod == "Remote" then
			if getNotesRemote() then
				Rayfield:Notify({
					Title = "Remote mode",
					Content = "Most accurate. Server sees every hit, easy to detect.",
					Duration = 5,
				})
			else
				Rayfield:Notify({
					Title = "Remote not found",
					Content = "ReplicatedStorage.Remotes.Notes missing, using input.",
					Duration = 5,
				})
			end
		end
	end,
})

MainTab:CreateSlider({
	Name = "Remote jitter",
	Range = { 0, 60 },
	Increment = 1,
	Suffix = "ms",
	CurrentValue = 0,
	Flag = "RemoteJitterMs",
	Callback = function(v)
		Config.RemoteJitterSec = v / 1000
	end,
})

MainTab:CreateDropdown({
	Name = "Input mode",
	Options = { "Auto", "Keyboard", "Touch" },
	CurrentOption = { "Auto" },
	MultipleOptions = false,
	Flag = "InputMode",
	Callback = function(opt)
		releaseAll()
		Config.InputMode = firstOption(opt)
	end,
})

MainTab:CreateDropdown({
	Name = "Touch method",
	Options = { "Touch", "Mouse" },
	CurrentOption = { "Touch" },
	MultipleOptions = false,
	Flag = "TouchMethod",
	Callback = function(opt)
		releaseAll()
		Config.TouchMethod = firstOption(opt)
	end,
})

MainTab:CreateSlider({
	Name = "Tap X offset",
	Range = { -200, 200 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = 0,
	Flag = "TouchXOffset",
	Callback = function(v)
		Config.TouchXOffset = v
	end,
})

MainTab:CreateSlider({
	Name = "Tap Y offset",
	Range = { -200, 200 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = 0,
	Flag = "TouchYOffset",
	Callback = function(v)
		Config.TouchYOffset = v
	end,
})

MainTab:CreateButton({
	Name = "Release all keys",
	Callback = releaseAll,
})

MainTab:CreateButton({
	Name = "Unload",
	Callback = function()
		enabled = false
		releaseAll()
		if mainConn then
			mainConn:Disconnect()
			mainConn = nil
		end
		Rayfield:Destroy()
	end,
})

TimingTab:CreateSlider({
	Name = "Hit offset",
	Range = { -150, 150 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = Config.HitOffsetPx,
	Flag = "HitOffsetPx",
	Callback = function(v)
		Config.HitOffsetPx = v
	end,
})

TimingTab:CreateSlider({
	Name = "Tail offset",
	Range = { -150, 150 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = Config.TailOffsetPx,
	Flag = "TailOffsetPx",
	Callback = function(v)
		Config.TailOffsetPx = v
	end,
})

TimingTab:CreateSlider({
	Name = "Input latency",
	Range = { 0, 200 },
	Increment = 1,
	Suffix = "ms",
	CurrentValue = Config.InputLatency * 1000,
	Flag = "InputLatencyMs",
	Callback = function(v)
		Config.InputLatency = v / 1000
	end,
})

TimingTab:CreateSlider({
	Name = "Late window",
	Range = { 0, 200 },
	Increment = 1,
	Suffix = "ms",
	CurrentValue = Config.LateWindowSec * 1000,
	Flag = "LateWindowMs",
	Callback = function(v)
		Config.LateWindowSec = v / 1000
	end,
})

TimingTab:CreateSlider({
	Name = "Tap duration",
	Range = { 5, 100 },
	Increment = 1,
	Suffix = "ms",
	CurrentValue = Config.TapDuration * 1000,
	Flag = "TapDurationMs",
	Callback = function(v)
		Config.TapDuration = v / 1000
	end,
})

TimingTab:CreateSlider({
	Name = "Lookahead",
	Range = { 0.2, 2 },
	Increment = 0.05,
	Suffix = "s",
	CurrentValue = Config.LookaheadSec,
	Flag = "LookaheadSec",
	Callback = function(v)
		Config.LookaheadSec = v
	end,
})

TimingTab:CreateSlider({
	Name = "Min lookahead",
	Range = { 100, 1500 },
	Increment = 10,
	Suffix = "px",
	CurrentValue = Config.MinLookaheadPx,
	Flag = "MinLookaheadPx",
	Callback = function(v)
		Config.MinLookaheadPx = v
	end,
})

TimingTab:CreateSlider({
	Name = "Long note min length",
	Range = { 5, 150 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = Config.LongNoteMinPx,
	Flag = "LongNoteMinPx",
	Callback = function(v)
		Config.LongNoteMinPx = v
	end,
})

TimingTab:CreateSlider({
	Name = "Max hold time",
	Range = { 1, 60 },
	Increment = 1,
	Suffix = "s",
	CurrentValue = Config.MaxHoldTime,
	Flag = "MaxHoldTime",
	Callback = function(v)
		Config.MaxHoldTime = v
	end,
})

local defaultNames = { "A", "S", "W", "D" }
for lane = 1, 4 do
	laneBindControls[lane] = KeysTab:CreateKeybind({
		Name = "Lane " .. lane,
		CurrentKeybind = defaultNames[lane],
		HoldToInteract = false,
		Flag = "LaneKey" .. lane,
		Callback = function() end, -- value read live via getKey
	})
end

-- main loop

mainConn = RunService.Heartbeat:Connect(function(dt)
	if not enabled then
		return
	end

	local keySync = getKeySync()
	if not keySync then
		return
	end

	local now = os.clock()

	for lane = 1, 4 do
		local laneFrame = keySync:FindFirstChild("Arrow" .. lane)
		if not laneFrame then
			continue
		end

		local receptor = laneFrame:FindFirstChild("Arrow")
		local notes = laneFrame:FindFirstChild("Notes")
		if not receptor or not notes then
			continue
		end

		local receptorY = receptor.AbsolutePosition.Y + Config.HitOffsetPx
		local lookahead = math.max(Config.MinLookaheadPx, math.abs(laneSpeed[lane] or 0) * Config.LookaheadSec)

		for _, note in ipairs(notes:GetChildren()) do
			if not note:IsA("GuiObject") or not note.Visible or note.Name == "Arrow"
				or string.sub(note.Name, 1, 5) == "Hold_" then
				continue
			end

			if processed[note] then
				continue
			end

			local y = note.AbsolutePosition.Y
			local dy = y - receptorY

			-- the whole chart lives in Notes, skip anything far from the line
			if math.abs(dy) > lookahead then
				continue
			end

			local velocity
			local last = tracked[note]
			if last then
				local elapsed = now - last.t
				if elapsed > 0 then
					velocity = (y - last.y) / elapsed
					last.y = y
					last.t = now

					if math.abs(velocity) > 1 then
						local prev = laneSpeed[lane]
						laneSpeed[lane] = prev and (prev * 0.8 + velocity * 0.2) or velocity
					end
				end
			else
				tracked[note] = { y = y, t = now }
				note.AncestryChanged:Once(function()
					tracked[note] = nil
					processed[note] = nil
				end)
			end

			local speed = laneSpeed[lane] or velocity
			if speed and speed ~= 0 and shouldHit(dy, speed, dt) then
				processed[note] = true
				if Config.HitMethod == "Remote" and getNotesRemote() then
					fireRemoteHit(lane, note)
				else
					pressNote(lane, note, notes, receptor, speed)
				end
			end
		end
	end
end)

Rayfield:LoadConfiguration()
