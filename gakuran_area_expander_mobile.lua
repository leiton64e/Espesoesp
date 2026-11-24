local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = pcall(function() return game:GetService("VirtualInputManager") end) and game:GetService("VirtualInputManager") or nil
local CoreGui = game:GetService("CoreGui")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	return
end

local env = (typeof(getgenv) == "function" and getgenv()) or _G
local SUITE_KEY = "GakuranAreaExpanderMobile_v1"

if env[SUITE_KEY] and typeof(env[SUITE_KEY].Cleanup) == "function" then
	pcall(env[SUITE_KEY].Cleanup)
end

local isTouchDevice = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local CONFIG = {
	AreaExpandEnabled = true,
	ReceiveAssistEnabled = true,
	ShowAreaRing = true,
	ActionMode = "AUTO", -- "AUTO" | "BUMP" ("COLISION") | "SET" ("ESTABLECER") | "DIVE" ("ZAMBULLA")

	-- Radio de ampliacion de area (en studs)
	AreaRadius = 28,
	MinRadius = 10,
	MaxRadius = 55,
	RadiusStep = 4,

	-- Nombres opcionales de botones del juego en PlayerGui
	BumpGuiName = "",
	SetGuiName = "",
	DiveGuiName = "",

	ActionCooldown = 0.20,
	ScanInterval = 0.02,
	HudInterval = 0.06,
	DragDeadzone = 6
}

local BALL_KEYWORDS = { "ball", "volleyball", "vball", "pelota", "balon" }

local suite = {
	AreaExpandEnabled = CONFIG.AreaExpandEnabled,
	ReceiveAssistEnabled = CONFIG.ReceiveAssistEnabled,
	ShowAreaRing = CONFIG.ShowAreaRing,
	ActionMode = CONFIG.ActionMode,
	AreaRadius = CONFIG.AreaRadius,
	Minimized = false,

	ReceiveCount = 0,
	LastTriggerClock = 0,
	LastJumpClock = 0,
	LastEvent = isTouchDevice and "Area Movil Lista" or "Area Lista",

	AreaPart = nil :: Part?,
	Gui = nil :: ScreenGui?,
	HudRefs = {} :: { [string]: GuiObject },
	Connections = {} :: { RBXScriptConnection },
	Cleanup = nil :: (() -> ())?
}

local function track(conn: RBXScriptConnection): RBXScriptConnection
	table.insert(suite.Connections, conn)
	return conn
end

local function getUiRoot(): Instance
	local root: Instance = CoreGui
	pcall(function()
		if typeof(gethui) == "function" then
			local custom = gethui()
			if typeof(custom) == "Instance" then
				root = custom
			end
		end
	end)
	return root
end

local function getMyRig()
	local char = localPlayer.Character
	if not char then
		return nil, nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = (char:FindFirstChild("HumanoidRootPart") :: BasePart?) or (char.PrimaryPart :: BasePart?)
	if not hum or not root or hum.Health <= 0 then
		return nil, nil, nil
	end
	return char, hum, root
end

local function findBallPart(): BasePart?
	local bestPart: BasePart? = nil
	local bestScore = -math.huge

	for _, desc in ipairs(workspace:GetDescendants()) do
		if desc:IsA("BasePart") then
			local nameLower = string.lower(desc.Name)
			local parentNameLower = desc.Parent and string.lower(desc.Parent.Name) or ""
			local matchesKeyword = false

			for _, kw in ipairs(BALL_KEYWORDS) do
				if string.find(nameLower, kw, 1, true) or string.find(parentNameLower, kw, 1, true) then
					matchesKeyword = true
					break
				end
			end

			if matchesKeyword and desc.Size.Magnitude < 25 then
				local score = 0
				if desc.Shape == Enum.PartType.Ball then
					score += 50
				end
				if desc:FindFirstChildWhichIsA("BodyMover") or desc:FindFirstChildWhichIsA("Constraint") then
					score += 10
				end
				if desc.AssemblyLinearVelocity.Magnitude > 0.2 then
					score += 5
				end
				if score > bestScore then
					bestScore = score
					bestPart = desc
				end
			end
		end
	end

	return bestPart
end

local function findGameButton(kind: string): GuiButton?
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local explicitName = ""
	if kind == "BUMP" then
		explicitName = CONFIG.BumpGuiName
	elseif kind == "SET" then
		explicitName = CONFIG.SetGuiName
	elseif kind == "DIVE" then
		explicitName = CONFIG.DiveGuiName
	end

	if explicitName ~= "" then
		local exact = playerGui:FindFirstChild(explicitName, true)
		if exact and exact:IsA("GuiButton") then
			return exact
		end
	end

	local matchers = {
		BUMP = { "colision", "collision", "bump", "recib", "receive" },
		SET = { "establecer", "set", "armar", "levant" },
		DIVE = { "zambull", "dive", "salv", "save", "lanz" }
	}
	local keys = matchers[kind] or {}

	for _, desc in ipairs(playerGui:GetDescendants()) do
		if desc:IsA("GuiButton") and desc.Visible then
			local n = string.lower(desc.Name)
			local t = desc:IsA("TextButton") and string.lower(desc.Text) or ""
			for _, kw in ipairs(keys) do
				if string.find(n, kw, 1, true) or string.find(t, kw, 1, true) then
					return desc
				end
			end
		end
	end

	return nil
end

local function triggerGuiButton(btn: GuiButton)
	pcall(function()
		if typeof(getconnections) == "function" then
			for _, conn in ipairs(getconnections(btn.MouseButton1Down)) do
				conn:Fire()
			end
			for _, conn in ipairs(getconnections(btn.MouseButton1Click)) do
				conn:Fire()
			end
			for _, conn in ipairs(getconnections(btn.Activated)) do
				conn:Fire()
			end
		end
	end)
end

local function pressJump()
	local _, hum = getMyRig()
	if hum and hum.FloorMaterial ~= Enum.Material.Air then
		hum.Jump = true
	end
	if VirtualInputManager then
		pcall(function()
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
			task.delay(0.05, function()
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
			end)
		end)
	end
end

local function chooseAction(ball: BasePart, root: BasePart): string
	if suite.ActionMode ~= "AUTO" then
		return suite.ActionMode
	end
	local dy = ball.Position.Y - root.Position.Y
	local dist = (ball.Position - root.Position).Magnitude
	if dy < -2.2 and dist > 9 then
		return "DIVE"
	elseif dy > 2.2 then
		return "SET"
	else
		return "BUMP"
	end
end

local function removeAreaRing()
	if suite.AreaPart then
		pcall(function()
			suite.AreaPart:Destroy()
		end)
		suite.AreaPart = nil
	end
end

local function updateAreaRing(root: BasePart?)
	if not suite.AreaExpandEnabled or not suite.ShowAreaRing or not root then
		removeAreaRing()
		return
	end

	local part = suite.AreaPart
	if not part or not part.Parent then
		part = Instance.new("Part")
		part.Name = "GakuranReceiveAreaRing"
		part.Shape = Enum.PartType.Cylinder
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(95, 225, 255)
		part.Transparency = 0.78
		part.Parent = workspace
		suite.AreaPart = part
	end

	local diameter = suite.AreaRadius * 2
	part.Size = Vector3.new(0.18, diameter, diameter)
	part.CFrame = CFrame.new(root.Position.X, root.Position.Y - 2.6, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
end

local function triggerReceiveInExpandedArea(ball: BasePart, root: BasePart)
	local now = os.clock()
	if now - suite.LastTriggerClock < CONFIG.ActionCooldown then
		return
	end
	suite.LastTriggerClock = now

	local flat = Vector3.new(ball.Position.X - root.Position.X, 0, ball.Position.Z - root.Position.Z)
	if flat.Magnitude > 0.05 then
		pcall(function()
			root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
		end)
	end

	local kind = chooseAction(ball, root)
	local btn = findGameButton(kind) or findGameButton("BUMP")
	if btn then
		triggerGuiButton(btn)
	end

	if kind == "SET" and now - suite.LastJumpClock > 0.45 then
		suite.LastJumpClock = now
		pressJump()
	end

	suite.ReceiveCount += 1
	suite.LastEvent = string.format("Recibido en %.0f studs (#%d)", suite.AreaRadius, suite.ReceiveCount)
end

local function scanArea()
	local _, _, root = getMyRig()
	updateAreaRing(root)

	if not root then
		return
	end

	local ball = findBallPart()
	if not ball then
		return
	end

	local effectiveRadius = suite.AreaExpandEnabled and suite.AreaRadius or 12
	local toPlayer = root.Position - ball.Position
	local dist = toPlayer.Magnitude

	if suite.ReceiveAssistEnabled and dist <= effectiveRadius and dist > 0.05 then
		local dirToPlayer = toPlayer.Unit
		local speedTowardPlayer = ball.AssemblyLinearVelocity:Dot(dirToPlayer)
		if speedTowardPlayer > 2.0 or dist <= effectiveRadius * 0.65 then
			triggerReceiveInExpandedArea(ball, root)
		end
	end
end

local function makeDraggable(targetGui: GuiObject, onClick: (() -> ())?)
	local dragging = false
	local movedEnough = false
	local dragStart = Vector2.zero
	local startPos = targetGui.Position

	track(targetGui.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			movedEnough = false
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			startPos = targetGui.Position
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local current = Vector2.new(input.Position.X, input.Position.Y)
			local delta = current - dragStart
			if delta.Magnitude >= CONFIG.DragDeadzone then
				movedEnough = true
			end
			if movedEnough then
				targetGui.Position = UDim2.new(
					startPos.X.Scale,
					startPos.X.Offset + delta.X,
					startPos.Y.Scale,
					startPos.Y.Offset + delta.Y
				)
			end
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local wasTap = not movedEnough
			dragging = false
			movedEnough = false
			if wasTap and onClick then
				onClick()
			end
		end
	end))
end

local function getPanelSize(): UDim2
	local w = isTouchDevice and 242 or 256
	if suite.Minimized then
		return UDim2.fromOffset(w, 34)
	end
	return UDim2.fromOffset(w, isTouchDevice and 196 or 188)
end

local refreshHud: () -> ()

local function toggleArea()
	suite.AreaExpandEnabled = not suite.AreaExpandEnabled
	suite.LastEvent = suite.AreaExpandEnabled and string.format("Area ON (%.0f studs)", suite.AreaRadius) or "Area OFF"
	if refreshHud then refreshHud() end
end

local function toggleReceive()
	suite.ReceiveAssistEnabled = not suite.ReceiveAssistEnabled
	suite.LastEvent = suite.ReceiveAssistEnabled and "Recibir ON" or "Recibir OFF"
	if refreshHud then refreshHud() end
end

local function changeRadius(delta: number)
	suite.AreaRadius = math.clamp(suite.AreaRadius + delta, CONFIG.MinRadius, CONFIG.MaxRadius)
	suite.LastEvent = string.format("Alcance: %.0f studs", suite.AreaRadius)
	if refreshHud then refreshHud() end
end

local function cycleMode()
	local order = { "AUTO", "BUMP", "SET", "DIVE" }
	local idx = 1
	for i, m in ipairs(order) do
		if m == suite.ActionMode then
			idx = i
			break
		end
	end
	suite.ActionMode = order[(idx % #order) + 1]
	suite.LastEvent = "Modo: " .. suite.ActionMode
	if refreshHud then refreshHud() end
end

local function toggleMinimize()
	suite.Minimized = not suite.Minimized
	local body = suite.HudRefs.BodyFrame
	local panel = suite.HudRefs.MainPanel
	local minBtn = suite.HudRefs.MinBtn :: TextButton?
	if body and panel then
		body.Visible = not suite.Minimized
		panel.Size = getPanelSize()
	end
	if minBtn then
		minBtn.Text = suite.Minimized and "+" or "-"
	end
end

refreshHud = function()
	local refs = suite.HudRefs
	local statusLbl = refs.StatusLabel :: TextLabel?
	local radiusLbl = refs.RadiusLabel :: TextLabel?
	local eventLbl = refs.EventLabel :: TextLabel?
	local areaBtn = refs.AreaBtn :: TextButton?
	local recBtn = refs.RecBtn :: TextButton?
	local modeBtn = refs.ModeBtn :: TextButton?

	if statusLbl then
		statusLbl.Text = suite.AreaExpandEnabled and "AMPLIADOR AREA: ON" or "AMPLIADOR AREA: OFF"
		statusLbl.TextColor3 = suite.AreaExpandEnabled and Color3.fromRGB(115, 255, 185) or Color3.fromRGB(255, 110, 110)
	end
	if radiusLbl then
		radiusLbl.Text = string.format("Alcance: %.0f studs | Recibidos: %d", suite.AreaRadius, suite.ReceiveCount)
	end
	if eventLbl then
		eventLbl.Text = suite.LastEvent
	end
	if areaBtn then
		areaBtn.Text = suite.AreaExpandEnabled and "AREA: ON" or "AREA: OFF"
	end
	if recBtn then
		recBtn.Text = suite.ReceiveAssistEnabled and "RECIBIR: ON" or "RECIBIR: OFF"
	end
	if modeBtn then
		modeBtn.Text = "MODO: " .. suite.ActionMode
	end
end

local function buildMenu()
	local root = getUiRoot()
	local prev = root:FindFirstChild("GakuranAreaExpander_Gui")
	if prev then
		prev:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "GakuranAreaExpander_Gui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = root
	suite.Gui = gui

	local panel = Instance.new("Frame")
	panel.Name = "MainPanel"
	panel.Size = getPanelSize()
	panel.Position = isTouchDevice and UDim2.new(0, 10, 0.20, 0) or UDim2.new(0, 16, 0.25, 0)
	panel.BackgroundColor3 = Color3.fromRGB(14, 19, 30)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Parent = gui

	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
	local stroke = Instance.new("UIStroke", panel)
	stroke.Color = Color3.fromRGB(105, 215, 255)
	stroke.Thickness = 1.3
	stroke.Transparency = 0.3

	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 34)
	titleBar.BackgroundColor3 = Color3.fromRGB(20, 29, 45)
	titleBar.BackgroundTransparency = 0.1
	titleBar.BorderSizePixel = 0
	titleBar.Active = true
	titleBar.Parent = panel
	Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 12)

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(1, -42, 1, 0)
	titleLbl.Position = UDim2.fromOffset(10, 0)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 11.5
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextColor3 = Color3.fromRGB(130, 225, 255)
	titleLbl.Text = "AREA RECIBIR (ARRASTRAR)"
	titleLbl.Parent = titleBar

	local minBtn = Instance.new("TextButton")
	minBtn.Size = isTouchDevice and UDim2.fromOffset(28, 28) or UDim2.fromOffset(24, 24)
	minBtn.Position = isTouchDevice and UDim2.new(1, -32, 0.5, -14) or UDim2.new(1, -30, 0.5, -12)
	minBtn.BackgroundColor3 = Color3.fromRGB(36, 52, 78)
	minBtn.BorderSizePixel = 0
	minBtn.Font = Enum.Font.GothamBold
	minBtn.TextSize = 14
	minBtn.TextColor3 = Color3.fromRGB(240, 248, 255)
	minBtn.Text = "-"
	minBtn.Parent = titleBar
	Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

	minBtn.MouseButton1Click:Connect(toggleMinimize)
	makeDraggable(panel, nil)

	local body = Instance.new("Frame")
	body.Name = "BodyFrame"
	body.Size = UDim2.new(1, -16, 1, -42)
	body.Position = UDim2.fromOffset(8, 38)
	body.BackgroundTransparency = 1
	body.Parent = panel

	local statusLbl = Instance.new("TextLabel")
	statusLbl.Size = UDim2.new(1, 0, 0, 18)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font = Enum.Font.GothamBold
	statusLbl.TextSize = 11
	statusLbl.TextXAlignment = Enum.TextXAlignment.Left
	statusLbl.TextColor3 = Color3.fromRGB(115, 255, 185)
	statusLbl.Text = "AMPLIADOR AREA: ON"
	statusLbl.Parent = body

	local radiusLbl = Instance.new("TextLabel")
	radiusLbl.Size = UDim2.new(1, 0, 0, 16)
	radiusLbl.Position = UDim2.fromOffset(0, 18)
	radiusLbl.BackgroundTransparency = 1
	radiusLbl.Font = Enum.Font.GothamSemibold
	radiusLbl.TextSize = 10.5
	radiusLbl.TextXAlignment = Enum.TextXAlignment.Left
	radiusLbl.TextColor3 = Color3.fromRGB(220, 234, 248)
	radiusLbl.Text = string.format("Alcance: %.0f studs | Recibidos: 0", suite.AreaRadius)
	radiusLbl.Parent = body

	local eventLbl = Instance.new("TextLabel")
	eventLbl.Size = UDim2.new(1, 0, 0, 16)
	eventLbl.Position = UDim2.fromOffset(0, 36)
	eventLbl.BackgroundTransparency = 1
	eventLbl.Font = Enum.Font.Gotham
	eventLbl.TextSize = 10
	eventLbl.TextXAlignment = Enum.TextXAlignment.Left
	eventLbl.TextColor3 = Color3.fromRGB(180, 206, 230)
	eventLbl.Text = suite.LastEvent
	eventLbl.Parent = body

	local function makeBtn(name: string, pos: UDim2, size: UDim2, text: string, color: Color3, cb: () -> ())
		local b = Instance.new("TextButton")
		b.Name = name
		b.Position = pos
		b.Size = size
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = isTouchDevice and 11 or 10.5
		b.TextColor3 = Color3.fromRGB(244, 250, 255)
		b.Text = text
		b.Parent = body
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
		b.MouseButton1Click:Connect(cb)
		return b
	end

	local btnH = isTouchDevice and 30 or 26
	suite.HudRefs.MainPanel = panel
	suite.HudRefs.BodyFrame = body
	suite.HudRefs.MinBtn = minBtn
	suite.HudRefs.StatusLabel = statusLbl
	suite.HudRefs.RadiusLabel = radiusLbl
	suite.HudRefs.EventLabel = eventLbl
	suite.HudRefs.AreaBtn = makeBtn("AreaBtn", UDim2.fromOffset(0, 56), UDim2.new(0.485, 0, 0, btnH), "AREA: ON", Color3.fromRGB(28, 58, 92), toggleArea)
	suite.HudRefs.RecBtn = makeBtn("RecBtn", UDim2.new(0.515, 0, 0, 56), UDim2.new(0.485, 0, 0, btnH), "RECIBIR: ON", Color3.fromRGB(28, 70, 56), toggleReceive)
	makeBtn("MinusBtn", UDim2.fromOffset(0, 90), UDim2.new(0.23, 0, 0, btnH), "- AREA", Color3.fromRGB(58, 42, 46), function()
		changeRadius(-CONFIG.RadiusStep)
	end)
	makeBtn("PlusBtn", UDim2.new(0.255, 0, 0, 90), UDim2.new(0.23, 0, 0, btnH), "+ AREA", Color3.fromRGB(36, 62, 88), function()
		changeRadius(CONFIG.RadiusStep)
	end)
	suite.HudRefs.ModeBtn = makeBtn("ModeBtn", UDim2.new(0.515, 0, 0, 90), UDim2.new(0.485, 0, 0, btnH), "MODO: " .. suite.ActionMode, Color3.fromRGB(48, 38, 76), cycleMode)
end

local lastScan, lastHud = 0, 0
track(RunService.RenderStepped:Connect(function()
	local now = os.clock()
	if now - lastScan >= CONFIG.ScanInterval then
		lastScan = now
		scanArea()
	end
	if now - lastHud >= CONFIG.HudInterval then
		lastHud = now
		refreshHud()
	end
end))

suite.Cleanup = function()
	removeAreaRing()
	for _, c in ipairs(suite.Connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(suite.Connections)
	if suite.Gui then
		pcall(function()
			suite.Gui:Destroy()
		end)
		suite.Gui = nil
	end
end

env[SUITE_KEY] = suite
buildMenu()
refreshHud()
