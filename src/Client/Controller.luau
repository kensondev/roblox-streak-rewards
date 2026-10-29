--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

export type Handle = {
	Open: () -> (),
	Close: () -> (),
	Destroy: () -> (),
}

type Reward = {
	kind: "Attribute" | "Leaderstats" | "Custom",
	name: string,
	amount: number,
	label: string,
}

type ClientConfig = {
	CycleLength: number,
	CycleMode: "Loop" | "Cap",
	NotifyOnJoin: boolean,
	Rewards: { Reward },
	RemoteCooldownSeconds: number,
}

type StatePacket = {
	canClaim: boolean,
	nextClaimAt: number,
	newStreak: number,
	rewardIndex: number,
	streakBroken: boolean,
	streak: number,
	serverTime: number,
	message: string?,
}

type RemoteNames = {
	Folder: string,
	ClaimRequest: string,
	StateRequest: string,
	StateUpdate: string,
}

type DayCard = {
	frame: Frame,
	status: TextLabel,
	stroke: UIStroke,
}

local WAIT_SECONDS = 10
local RESPONSE_SECONDS = 12
local TOGGLE_ACTION = "StreakRewards.Toggle"
local CLOSE_ACTION = "StreakRewards.Close"
local CLAIM_ACTION = "StreakRewards.Claim"
local COLORS = {
	panel = Color3.fromRGB(20, 27, 43),
	card = Color3.fromRGB(32, 42, 61),
	text = Color3.fromRGB(242, 246, 255),
	muted = Color3.fromRGB(183, 196, 219),
	accent = Color3.fromRGB(84, 159, 255),
	ready = Color3.fromRGB(93, 223, 162),
	warning = Color3.fromRGB(255, 199, 108),
}

local Controller = {}
local current: Handle? = nil

local function rounded(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(radius, 0)
	corner.Parent = parent
end

local function text(
	parent: Instance,
	name: string,
	value: string,
	position: UDim2,
	size: UDim2,
	maximum: number
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = position
	label.Size = size
	label.Font = Enum.Font.GothamMedium
	label.Text = value
	label.TextColor3 = COLORS.text
	label.TextScaled = true
	label.TextWrapped = true
	local bounds = Instance.new("UITextSizeConstraint")
	bounds.MinTextSize = 11
	bounds.MaxTextSize = maximum
	bounds.Parent = label
	label.Parent = parent
	return label
end

local function button(parent: Instance, name: string, value: string, position: UDim2, size: UDim2): TextButton
	local result = Instance.new("TextButton")
	result.Name = name
	result.Position = position
	result.Size = size
	result.BackgroundColor3 = COLORS.accent
	result.BorderSizePixel = 0
	result.Font = Enum.Font.GothamBold
	result.Text = value
	result.TextColor3 = COLORS.panel
	result.TextScaled = true
	result.TextWrapped = true
	result.Selectable = true
	result.AutoButtonColor = true
	local bounds = Instance.new("UITextSizeConstraint")
	bounds.MinTextSize = 12
	bounds.MaxTextSize = 20
	bounds.Parent = result
	rounded(result, 0.18)
	result.Parent = parent
	return result
end

local function clockText(seconds: number): string
	local remaining = math.max(0, math.ceil(seconds))
	local hours = math.floor(remaining / 3600)
	local minutes = math.floor(remaining % 3600 / 60)
	local secs = remaining % 60
	return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

function Controller.Start(): Handle?
	if current then
		return current
	end
	local player = Players.LocalPlayer
	if not player then
		warn("StreakRewards client must run from a LocalScript.")
		return nil
	end
	local playerGui = player:WaitForChild("PlayerGui", WAIT_SECONDS)
	if not playerGui or not playerGui:IsA("PlayerGui") then
		warn("StreakRewards could not find PlayerGui within 10 seconds.")
		return nil
	end

	local connections: { RBXScriptConnection } = {}
	local destroyed = false
	local manualInteraction = false
	local opened = false
	local pending = false
	local requestVersion = 0
	local lastRequestAt = -math.huge
	local cooldown = 0.75
	local clockOffset = 0
	local state: StatePacket? = nil
	local config: ClientConfig? = nil
	local claimRemote: RemoteEvent? = nil
	local stateRemote: RemoteEvent? = nil
	local previousSelection: GuiObject? = nil
	local cards: { DayCard } = {}
	local feedback = "Connecting to daily rewards..."
	local feedbackIsError = false

	local gui = Instance.new("ScreenGui")
	gui.Name = "StreakRewards"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.ClipToDeviceSafeArea = true

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Visible = false
	backdrop.Active = true
	backdrop.Parent = gui

	local panel = Instance.new("Frame")
	panel.Name = "Calendar"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.94, 0.92)
	panel.BackgroundColor3 = COLORS.panel
	panel.BorderSizePixel = 0
	panel.SelectionGroup = true
	rounded(panel, 0.035)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(720, 650)
	limit.Parent = panel
	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = panel
	panel.Parent = backdrop

	local title = text(panel, "Title", "DAILY REWARDS", UDim2.fromScale(0.055, 0.035), UDim2.fromScale(0.74, 0.065), 27)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local close = button(panel, "Close", "X", UDim2.fromScale(0.86, 0.025), UDim2.fromScale(0.1, 0.075))
	close.BackgroundColor3 = COLORS.card
	close.TextColor3 = COLORS.text
	local streakLabel =
		text(panel, "Streak", "Your streak: --", UDim2.fromScale(0.055, 0.12), UDim2.fromScale(0.89, 0.065), 29)
	streakLabel.TextXAlignment = Enum.TextXAlignment.Left
	local countdown = text(
		panel,
		"Countdown",
		"Waiting for server state",
		UDim2.fromScale(0.055, 0.19),
		UDim2.fromScale(0.89, 0.05),
		17
	)
	countdown.TextXAlignment = Enum.TextXAlignment.Left
	countdown.TextColor3 = COLORS.muted

	local calendar = Instance.new("ScrollingFrame")
	calendar.Name = "Days"
	calendar.Position = UDim2.fromScale(0.055, 0.275)
	calendar.Size = UDim2.fromScale(0.89, 0.425)
	calendar.BackgroundTransparency = 1
	calendar.BorderSizePixel = 0
	calendar.ScrollBarThickness = 4
	calendar.ScrollBarImageColor3 = COLORS.muted
	calendar.ScrollingDirection = Enum.ScrollingDirection.Y
	calendar.CanvasSize = UDim2.fromScale(0, 0)
	calendar.AutomaticCanvasSize = Enum.AutomaticSize.Y
	calendar.Parent = panel
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.CellSize = UDim2.fromScale(0.235, 0.46)
	grid.CellPadding = UDim2.fromScale(0.018, 0.045)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = calendar

	local status = text(panel, "Status", feedback, UDim2.fromScale(0.055, 0.725), UDim2.fromScale(0.89, 0.09), 17)
	status.TextColor3 = COLORS.muted
	local claim = button(panel, "Claim", "Connecting...", UDim2.fromScale(0.055, 0.835), UDim2.fromScale(0.89, 0.09))
	text(
		panel,
		"InputHint",
		"F7 / Y: toggle | Enter: claim | B: close",
		UDim2.fromScale(0.055, 0.94),
		UDim2.fromScale(0.89, 0.035),
		12
	).TextColor3 =
		COLORS.muted

	local launcher =
		button(gui, "Launcher", "Daily rewards", UDim2.fromScale(0.025, 0.965), UDim2.fromScale(0.35, 0.075))
	launcher.AnchorPoint = Vector2.new(0, 1)
	local launcherLimit = Instance.new("UISizeConstraint")
	launcherLimit.MinSize = Vector2.new(135, 42)
	launcherLimit.MaxSize = Vector2.new(205, 52)
	launcherLimit.Parent = launcher
	close.NextSelectionDown = claim
	claim.NextSelectionUp = close

	local function connect(connection: RBXScriptConnection)
		table.insert(connections, connection)
	end

	local function serverNow(): number
		return DateTime.now().UnixTimestampMillis / 1000 + clockOffset
	end

	local function refresh()
		if destroyed then
			return
		end
		local packet = state
		local ready = packet ~= nil and packet.canClaim
		local checkable = packet ~= nil and not packet.canClaim and serverNow() >= packet.nextClaimAt
		local enabled = not pending
			and claimRemote ~= nil
			and stateRemote ~= nil
			and (ready or checkable or packet == nil)
		claim.Active = enabled
		claim.Selectable = enabled
		claim.AutoButtonColor = enabled
		claim.BackgroundColor3 = if enabled then COLORS.accent else COLORS.card
		claim.TextColor3 = if enabled then COLORS.panel else COLORS.muted
		if pending then
			claim.Text = "Waiting for server..."
		elseif claimRemote == nil or stateRemote == nil then
			claim.Text = if feedbackIsError then "Rewards unavailable" else "Connecting..."
		elseif packet == nil or checkable then
			claim.Text = "Check availability"
		elseif ready then
			claim.Text = "Claim today's reward"
		else
			claim.Text = "Claimed for now"
		end
		status.Text = feedback
		status.TextColor3 = if feedbackIsError then COLORS.warning else COLORS.muted
		if packet then
			streakLabel.Text = `Your streak: {packet.streak} {if packet.streak == 1 then "day" else "days"}`
			if ready then
				countdown.Text = `Day {packet.rewardIndex} is ready to claim`
				countdown.TextColor3 = COLORS.ready
			elseif checkable then
				countdown.Text = "A new reward may be ready. Check availability."
				countdown.TextColor3 = COLORS.ready
			else
				countdown.Text = `Next reward in {clockText(packet.nextClaimAt - serverNow())}`
				countdown.TextColor3 = COLORS.muted
			end
			local cfg = config
			if cfg then
				local completed = if cfg.CycleMode == "Cap"
					then math.min(packet.streak, cfg.CycleLength)
					else if packet.streak == 0 then 0 else (packet.streak - 1) % cfg.CycleLength + 1
				for index, card in cards do
					local target = ready and index == packet.rewardIndex
					local earned = not packet.streakBroken and index <= completed
					if ready and cfg.CycleMode == "Loop" and packet.rewardIndex == 1 then
						earned = false
					end
					card.frame.BackgroundColor3 = if target then Color3.fromRGB(33, 64, 82) else COLORS.card
					card.stroke.Color = if target then COLORS.ready else COLORS.card
					card.status.Text = if target then "READY" else if earned then "CLAIMED" else "UPCOMING"
					card.status.TextColor3 = if target then COLORS.ready else COLORS.muted
				end
			end
		end
		if opened and GuiService.SelectedObject == claim and not enabled then
			GuiService.SelectedObject = close
		end
	end

	local function unavailable(message: string)
		if destroyed then
			return
		end
		feedback = message
		feedbackIsError = true
		pending = false
		refresh()
	end

	local function sendRequest(isClaim: boolean)
		if destroyed or pending then
			return
		end
		local remote = if isClaim then claimRemote else stateRemote
		if not remote then
			return
		end
		if os.clock() - lastRequestAt < cooldown then
			return
		end
		if isClaim and (state == nil or not state.canClaim) then
			return
		end
		lastRequestAt = os.clock()
		pending = true
		requestVersion += 1
		local version = requestVersion
		feedback = if isClaim then "Claiming your reward..." else "Checking with the server..."
		feedbackIsError = false
		refresh()
		remote:FireServer()
		task.delay(RESPONSE_SECONDS, function()
			if destroyed or not pending or requestVersion ~= version then
				return
			end
			unavailable("The server did not reply. Check availability or try your claim again.")
		end)
	end

	local function setOpen(value: boolean, manual: boolean)
		if destroyed then
			return
		end
		if manual then
			manualInteraction = true
		end
		if value == opened then
			return
		end
		opened = value
		backdrop.Visible = value
		launcher.Visible = not value
		if value then
			previousSelection = GuiService.SelectedObject
			refresh()
			if UserInputService.GamepadEnabled then
				GuiService.SelectedObject = if claim.Selectable then claim else close
			end
			sendRequest(false)
		else
			local selected = GuiService.SelectedObject
			if selected and selected:IsDescendantOf(gui) then
				GuiService.SelectedObject = if previousSelection and previousSelection.Parent
					then previousSelection
					else if UserInputService.GamepadEnabled then launcher else nil
			end
		end
	end

	local handle: Handle
	local function cleanup(removeGui: boolean)
		if destroyed then
			return
		end
		destroyed = true
		requestVersion += 1
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		ContextActionService:UnbindAction(TOGGLE_ACTION)
		ContextActionService:UnbindAction(CLOSE_ACTION)
		ContextActionService:UnbindAction(CLAIM_ACTION)
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(gui) then
			GuiService.SelectedObject = if previousSelection and previousSelection.Parent
				then previousSelection
				else nil
		end
		if current == handle then
			current = nil
		end
		if removeGui then
			gui:Destroy()
		end
	end
	handle = {
		Open = function()
			setOpen(true, true)
		end,
		Close = function()
			setOpen(false, true)
		end,
		Destroy = function()
			cleanup(true)
		end,
	}
	current = handle
	connect(launcher.Activated:Connect(handle.Open))
	connect(close.Activated:Connect(handle.Close))
	connect(claim.Activated:Connect(function()
		local packet = state
		sendRequest(packet ~= nil and packet.canClaim)
	end))
	connect(gui.Destroying:Connect(function()
		cleanup(false)
	end))
	connect(gui.AncestryChanged:Connect(function()
		if not gui:IsDescendantOf(playerGui) then
			handle.Destroy()
		end
	end))

	ContextActionService:BindAction(
		TOGGLE_ACTION,
		function(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
			if UserInputService:GetFocusedTextBox() then
				return Enum.ContextActionResult.Pass
			end
			if inputState == Enum.UserInputState.Begin then
				setOpen(not opened, true)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.KeyCode.F7,
		Enum.KeyCode.ButtonY
	)
	ContextActionService:BindAction(
		CLOSE_ACTION,
		function(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
			if not opened then
				return Enum.ContextActionResult.Pass
			end
			if inputState == Enum.UserInputState.Begin then
				setOpen(false, true)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.KeyCode.ButtonB
	)
	ContextActionService:BindAction(
		CLAIM_ACTION,
		function(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
			if not opened or UserInputService:GetFocusedTextBox() then
				return Enum.ContextActionResult.Pass
			end
			if inputState == Enum.UserInputState.Begin and claim.Active then
				local packet = state
				sendRequest(packet ~= nil and packet.canClaim)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter
	)

	local elapsed = 0
	connect(RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed >= 1 then
			elapsed = 0
			if opened then
				refresh()
			end
		end
	end))
	gui.Parent = playerGui
	refresh()

	task.spawn(function()
		local function child(parent: Instance, name: string): Instance?
			if destroyed then
				return nil
			end
			return parent:WaitForChild(name, WAIT_SECONDS)
		end
		local kit = child(ReplicatedStorage, "StreakRewards")
		local shared = if kit then child(kit, "Shared") else nil
		local configModule = if shared then child(shared, "Config") else nil
		local namesModule = if shared then child(shared, "Remotes") else nil
		if destroyed then
			return
		end
		if
			not configModule
			or not configModule:IsA("ModuleScript")
			or not namesModule
			or not namesModule:IsA("ModuleScript")
		then
			unavailable("Daily rewards could not load. Please rejoin or contact the game's support.")
			return
		end
		local loadedConfig: ClientConfig? = nil
		local loadedNames: RemoteNames? = nil
		local ok, problem = pcall(function()
			loadedConfig = require(configModule)
			loadedNames = require(namesModule)
		end)
		local cfg = loadedConfig
		local names = loadedNames
		if not ok or not cfg or not names then
			warn(`StreakRewards configuration failed to load: {tostring(problem)}`)
			unavailable("Daily rewards configuration is unavailable.")
			return
		end
		if destroyed then
			return
		end
		config = cfg
		cooldown = math.max(0.75, cfg.RemoteCooldownSeconds)
		local columns = math.min(4, cfg.CycleLength)
		grid.FillDirectionMaxCells = columns
		grid.CellSize = UDim2.fromScale((1 - 0.018 * (columns - 1)) / columns - 0.005, 0.46)
		for day = 1, cfg.CycleLength do
			local reward = cfg.Rewards[day]
			local card = Instance.new("Frame")
			card.Name = `Day{day}`
			card.LayoutOrder = day
			card.BackgroundColor3 = COLORS.card
			card.BorderSizePixel = 0
			rounded(card, 0.08)
			local stroke = Instance.new("UIStroke")
			stroke.Color = COLORS.card
			stroke.Thickness = 2
			stroke.Parent = card
			text(card, "Day", `DAY {day}`, UDim2.fromScale(0.06, 0.06), UDim2.fromScale(0.88, 0.2), 15)
			text(card, "Reward", reward.label, UDim2.fromScale(0.06, 0.3), UDim2.fromScale(0.88, 0.4), 20)
			local dayStatus =
				text(card, "Status", "UPCOMING", UDim2.fromScale(0.04, 0.76), UDim2.fromScale(0.92, 0.16), 12)
			dayStatus.TextColor3 = COLORS.muted
			card.Parent = calendar
			table.insert(cards, { frame = card, status = dayStatus, stroke = stroke })
		end
		if cfg.NotifyOnJoin and not manualInteraction then
			setOpen(true, false)
		end
		local folder = child(ReplicatedStorage, names.Folder)
		local claimEvent = if folder then child(folder, names.ClaimRequest) else nil
		local requestEvent = if folder then child(folder, names.StateRequest) else nil
		local updateEvent = if folder then child(folder, names.StateUpdate) else nil
		if destroyed then
			return
		end
		if
			not claimEvent
			or not claimEvent:IsA("RemoteEvent")
			or not requestEvent
			or not requestEvent:IsA("RemoteEvent")
			or not updateEvent
			or not updateEvent:IsA("RemoteEvent")
		then
			unavailable("Daily rewards are unavailable on this server. Please try another server.")
			return
		end
		claimRemote = claimEvent
		stateRemote = requestEvent
		connect(updateEvent.OnClientEvent:Connect(function(packet: StatePacket)
			if destroyed then
				return
			end
			state = packet
			clockOffset = packet.serverTime - DateTime.now().UnixTimestampMillis / 1000
			pending = false
			requestVersion += 1
			feedback = packet.message
				or (
					if packet.canClaim
						then "Your next daily reward is ready."
						else "Come back for your next daily reward."
				)
			feedbackIsError = false
			refresh()
		end))
		sendRequest(false)
	end)

	return handle
end

return Controller
