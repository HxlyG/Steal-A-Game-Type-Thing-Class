--[[
ThingClass.lua

Represents a purchasable, movable, income-generating object that can be:
- Purchased
- Moved to a plot
- Displayed
- Sold
- Stolen (with server-authoritative validation)

Responsibilities:
- Movement + hover physics
- ProximityPrompt management
- Ownership transfer
- Cash generation
- Stealing lifecycle
- Serialization / cloning

Server-authoritative. Clients only receive visuals & UI updates.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Gamepasses = require(game.ReplicatedStorage.Shared.Data.Gamepasses)
local PlotHandler = require(ReplicatedStorage.Shared.PlotHandler)
local NumberAbbreviator = require(ReplicatedStorage.Shared.Util.NumberAbbreviator)
local VFXModule = require(ReplicatedStorage.Shared.Util.VFXModule)
local PlayerOwnsGamepass = require(ReplicatedStorage.Shared.Util.PlayerOwnsGamepass)

local THING_FOLDER = workspace:WaitForChild("Things")
local THING_SPEED = 10
local THING_HOVER_HEIGHT = 2
local STEP_RATE = 0.2

local Thing = {}
Thing.__index = Thing

local Things: {Types.Thing} = {}

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.FilterDescendantsInstances = {workspace.Things, workspace.Characters}

--[[
Global movement stepper.
Runs every STEP_RATE seconds and advances all Things in the "Moving" state.

Features:
- XZ-plane directional movement
- Ground raycast for hover height
- Smooth facing toward movement direction
- Automatic arrival detection
]]
task.spawn(function()
	while task.wait(STEP_RATE) do
		for _, thing in pairs(Things) do
			if thing.State ~= "Moving" then continue end
			local primary = thing.Model.PrimaryPart
			if not primary then continue end

			local pivot = thing.Model:GetPivot()

			-- === Direction (XZ) ===
			local flatTarget = Vector3.new(
				thing.TargetPosition.X,
				pivot.Position.Y,
				thing.TargetPosition.Z
			)

			local toTarget = flatTarget - pivot.Position
			local dist = toTarget.Magnitude

			if dist <= THING_SPEED * STEP_RATE then
				thing.Model:PivotTo(
					CFrame.lookAt(thing.TargetPosition, thing.TargetPosition + toTarget)
				)
				thing:CancelMovement()
				if thing.OnArrive then thing:OnArrive() end
				continue
			end

			local stepDir = toTarget.Unit
			local stepXZ = pivot.Position + stepDir * THING_SPEED * STEP_RATE

			-- === Raycast from stepped position ===
			local ray = workspace:Raycast(
				stepXZ + Vector3.new(0, 5, 0),
				Vector3.new(0, -1000, 0),
				params
			)

			local hoverY = stepXZ.Y
			if ray then
				hoverY = ray.Position.Y + primary.Size.Y / 2 + THING_HOVER_HEIGHT
			end

			local finalPos = Vector3.new(
				stepXZ.X,
				hoverY,
				stepXZ.Z
			)

			-- === Facing ===
			local newCFrame = CFrame.lookAt(
				finalPos,
				finalPos + stepDir,
				Vector3.yAxis
			)

			thing.Model:PivotTo(newCFrame)
		end
	end
end)


-- Disables all proximity prompts for the stealing player,
-- plays steal animation, locks tools, and applies walk speed penalty.
local function PlayerStealing(player: Player)
	for _, thing in ipairs(Things) do
		local prompt = thing.Model:FindFirstChildOfClass("ProximityPrompt")
		ReplicatedStorage.RemoteEvents.SetPropertyForClient:FireClient(player, prompt, "Enabled", false)
	end
	game.ReplicatedStorage.RemoteEvents.PlayAnimation:FireClient(player, game.ReplicatedStorage.Animations.Steal)
	game.ReplicatedStorage.RemoteEvents.SetGears:FireClient(player, false)
	if not PlayerOwnsGamepass(player.UserId, Gamepasses.Passes[2]) then
		player.Character.Humanoid.WalkSpeed = 16
	end
end

-- Restores prompts, stops animation, re-enables tools,
-- and resets walk speed after stealing ends.
local function PlayerStoppedStealing(player: Player)
	for _, thing in ipairs(Things) do
		local prompt = thing.Model:FindFirstChildOfClass("ProximityPrompt")
		ReplicatedStorage.RemoteEvents.SetPropertyForClient:FireClient(player, prompt, "Enabled", true)
	end
	game.ReplicatedStorage.RemoteEvents.StopAnimation:FireClient(player, game.ReplicatedStorage.Animations.Steal)
	game.ReplicatedStorage.RemoteEvents.SetGears:FireClient(player, true)
	player.Character.Humanoid.WalkSpeed = 24
end

--[[
Creates a new Thing instance.

@param props table {
    Name: string,
    Owner: Player?,
    Model: Model,
    Rarity: table,
    Price: number,
    Income: number,
    Mutations: {Mutation}
}

@param class table? Optional subclass (e.g., Fish)

@return Thing
]]
function Thing.new(props, class)
	local self = setmetatable({}, class or Thing)

	--Data
	self.Name = props.Name
	self.Owner = props.Owner
	self.Model = props.Model
	self.Rarity = props.Rarity
	self.Price = props.Price
	self.Income = props.Income
	self.Mutations = props.Mutations
	
	self.InteractPrompt = self.Model:FindFirstChildOfClass("ProximityPrompt") or Instance.new("ProximityPrompt")
	self.CurrentMoney = 0
	
	if self.Model.PrimaryPart:FindFirstChild("NametagAttachment"):FindFirstChildOfClass("BillboardGui") then
		self.Nametag = self.Model.PrimaryPart:FindFirstChild("NametagAttachment"):FindFirstChildOfClass("BillboardGui")
	else
		self.Nametag = ReplicatedStorage.Misc.ThingName:Clone()
	end
	
	self.Nametag.Parent = self.Model.PrimaryPart:FindFirstChild("NametagAttachment")
	
	--Movement
	self.TargetPosition = nil
	self.State = "Idle"

	--Stealing
	self.CurrentThief = nil
	
	--Events
	self.OnArrive = function()
		self:Destroy()
	end
	
	--Connections
	self._InteractPromptConnection = self.InteractPrompt.Triggered:Connect(function(player)
		print("triggered")
	end)

	table.insert(Things, self)
	
	if game["Run Service"]:IsServer() then
		self:UpdateNametag()
		self:CashLoop()
	end
	
	self.InteractPrompt.Parent = self.Model
	
	if game:GetService("RunService"):IsServer() then
		self._PlayerAddedConnection = game.Players.PlayerAdded:Connect(function()
			self:UpdateProximityPrompt()
		end)
	end

	return self
end

if game["Run Service"]:IsServer() then
	--//State & Runtime\\
	
	-- Sets Thing state and model attributes
	function Thing:SetState(state)
		self.State = state
		self.Model:SetAttribute("State", state)
	end
	
	--[[
	Passive income loop.
	Runs once per second while Thing is in "Display" state.

	Modifiers:
	- Rebirth multiplier
	- Double income gamepass
	]]
	function Thing:CashLoop()
		task.spawn(function()
			while wait() do
				if self.State == "Display" and self ~= nil then
					local rebirthMult = 1 + (self.Owner:WaitForChild("leaderstats").Rebirths.Value * 0.5)
					if PlayerOwnsGamepass(self.Owner.UserId, Gamepasses.Passes[4]) then
						self.CurrentMoney += self.Income*rebirthMult*2
					else
						self.CurrentMoney += self.Income*rebirthMult
					end
					wait(1)
				end
			end
		end)
	end

	--//Data Display\\

	function Thing:UpdateProximityPrompt()
		if not self.Model then return end

		if self._InteractPromptConnection then
			self._InteractPromptConnection:Disconnect()
			self._InteractPromptConnection = nil
		end

		if self.State == "Moving" or self.State == "Idle" then
			self.InteractPrompt.ActionText = "Purchase"
			self.InteractPrompt.ObjectText = NumberAbbreviator:AbbreviateNumbers(self.Price) .. "$"
			self.InteractPrompt.HoldDuration = .25
			self.InteractPrompt.Enabled = true
			
			game.ReplicatedStorage.RemoteEvents.SetPropertyForClient:FireAllClients(self.InteractPrompt, "Enabled", true)
			
			if self.Owner then
				game.ReplicatedStorage.RemoteEvents.SetPropertyForClient:FireClient(self.Owner, self.InteractPrompt, "Enabled", false)
			end
			
			local class = getmetatable(self) or Thing
			self._InteractPromptConnection = self.InteractPrompt.Triggered:Connect(function(player)
				-- call the Purchase defined on the class (Fish or Thing)
				if class and class.Purchase then
					class.Purchase(self, player)
				else
					-- fallback
					Thing.Purchase(self, player)
				end
			end)

		elseif self.State == "Display" then
			self.InteractPrompt.ActionText = "Steal"
			self.InteractPrompt.ObjectText = ""
			self.InteractPrompt.HoldDuration = 1
			self.InteractPrompt.Enabled = true

			game.ReplicatedStorage.RemoteEvents.SetPropertyForClient:FireAllClients(self.InteractPrompt, "Enabled", true)
			game.ReplicatedStorage.RemoteEvents.SetPropertyForClient:FireAllClients(self.InteractPrompt, "ActionText", "Steal")
			game.ReplicatedStorage.RemoteEvents.SetPropertyForClient:FireClient(self.Owner, self.InteractPrompt, "ActionText", "Sell")

			self._InteractPromptConnection = self.InteractPrompt.Triggered:Connect(function(player)
				if player == self.Owner then
					self:Sell()
				else
					self:Steal(player)
				end
			end)

		elseif self.State == "Carry" then
			self.InteractPrompt.Enabled = false
		end
	end


	function Thing:UpdateNametag()
		local primary = self.Model.PrimaryPart
		if not primary then return end

		self.Nametag.Parent = primary:FindFirstChild("NametagAttachment")
		self.Nametag.NameLabel.Text = self.Name
		self.Nametag.PriceLabel.Text = NumberAbbreviator:AbbreviateNumbers(self.Price) .. "$"
		self.Nametag.MoneyLabel.Text = NumberAbbreviator:AbbreviateNumbers(self.Income) .. "$/s"
		self.Nametag.RarityLabel.Text = self.Rarity.Name
		self.Nametag.RarityLabel.UIGradient.Color = self.Rarity.Color
	end

	--[[
	Applies mutation effects:
	- Price multiplier
	- Income multiplier
	- VFX
	- UI labels
	]]
	function Thing:LoadMutations()
		local priceMult = 1
		for _, mutation in ipairs(self.Mutations) do
			priceMult += mutation.PriceMultiplier - 1
			mutation:LoadVFX(self.Model)

			local label = self.Nametag.Mutations.MutationTemplate:Clone()
			label.Parent = self.Nametag.Mutations
			label.Text = mutation.Name
			label.Visible = true
			label.UIGradient.Color = mutation.Color
		end
		self.Price = math.floor(self.Price * priceMult)
		self.Income = math.floor(self.Income * priceMult)
		self:UpdateNametag()
	end

	--//Movement\\

	-- Sets the movement destination
	function Thing:SetTargetPosition(targetPos)
		self.TargetPosition = targetPos
		self.Model:SetAttribute("TargetPosition", targetPos)
	end

	-- Cancels movement and returns to Idle
	function Thing:CancelMovement()
		self:SetState("Idle")
		self:SetTargetPosition(nil)
		
		self:UpdateProximityPrompt()
	end

	-- Begins smooth movement toward a world position
	function Thing:MoveTo(position)
		self:SetState("Moving")
		self:SetTargetPosition(position)
		
		self:UpdateProximityPrompt()
	end
	
	--[[
	Places the Thing onto the owner's plot.

	@param index number? Optional plot slot
	]]
	function Thing:Display(index: number?)
		local plot = PlotHandler:GetPlotFromOwner(self.Owner)
		
		self:SetState("Display")
		
		plot:AddThing(self, index)
		
		self:UpdateNametag()
		self:UpdateProximityPrompt()
	end

	-- Spawns the Thing into the world at a given CFrame
	function Thing:Spawn(cframe)
		self.Model.Parent = THING_FOLDER
		self.Model:PivotTo(cframe)
		self:UpdateNametag()
	end

	--[[
	Attempts to purchase the Thing.

	Validations:
	- Buyer is not the owner
	- Buyer has enough cash
	- Plot capacity not exceeded
	- Crafting queue not full

	On success:
	- Deducts cash
	- Transfers ownership
	- Moves Thing to plot
	]]
	function Thing:Purchase(player)
		if self.Owner == player then return end
		local cash = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Cash")
		local plot = PlotHandler:GetPlotFromOwner(player)
		local previousPlot

		if self.Owner then
			previousPlot = PlotHandler:GetPlotFromOwner(self.Owner)
		end

		if cash.Value < self.Price then
			game.ReplicatedStorage.RemoteEvents.UI.Alert:FireClient(player, "Not enough cash.", "err")
			return
		end

		if plot.ThingCount >= plot.MaxThings then
			game.ReplicatedStorage.RemoteEvents.UI.Alert:FireClient(player, "Max sushis owned.", "err")
			return
		end
		
		if #plot.Ingredients + #plot.MovingThings >= 2 then
			game.ReplicatedStorage.RemoteEvents.UI.Alert:FireClient(player, "Wait for sushi to be done crafting.", "err")
		end

		if cash and cash.Value >= self.Price and plot.ThingCount < plot.MaxThings and #plot.Ingredients + #plot.MovingThings < 2 then
			if previousPlot then
				table.remove(previousPlot.MovingThings, table.find(previousPlot.MovingThings, self))
			end

			table.insert(plot.MovingThings, self)

			cash.Value -= self.Price
			self.Owner = player

			self:MoveTo(plot.Model.ThingPart.Position)
			local class = getmetatable(self) or Thing
			self.OnArrive = function()
				self:CancelMovement()
				task.wait()
				class.Display(self)
			end

			ReplicatedStorage.RemoteEvents.PlaySound:FireClient(player, ReplicatedStorage.SFX.Effects.CashPurchase)
			game.ReplicatedStorage.RemoteEvents.UI.Alert:FireClient(player, "Bought "..self.Name..".", "success")
			
			self:UpdateProximityPrompt()
		end
	end
	
	-- Finalizes ownership transfer when dropped at plot
	function Thing:CompleteSteal(player)
		if not self.IsBeingStolen or player ~= self.CurrentThief then return end

		self.IsBeingStolen = false
		PlayerStoppedStealing(player)

		local thiefPlot = PlotHandler:GetPlotFromOwner(player)
		if not thiefPlot then
			self:CancelSteal()
			return
		end

		-- Transfer ownership
		PlotHandler:GetPlotFromOwner(self.Owner):RemoveThing(self)
		self.Owner = player
		self.CurrentMoney = 0

		if self._stealCloneModel then self._stealCloneModel:Destroy() end
		self.Model:SetAttribute("Transparency", 0)

		self:Display()

		if self._DropOffConnection then self._DropOffConnection:Disconnect() end
		if self._cancelThread ~= nil and coroutine.status(self._cancelThread) == "suspended" then pcall(function() task.cancel(self._cancelThread) end) end
	end
	
	-- Cleans up all steal-related state safely
	function Thing:CancelSteal()
		if not self.IsBeingStolen then return end

		self.IsBeingStolen = false
		self.State = "Display"

		if self.CurrentThief ~= nil and self.CurrentThief.Parent ~= nil then
			PlayerStoppedStealing(self.CurrentThief)
		end

		self.CurrentThief = nil
		self.Model:SetAttribute("Transparency", 0)

		if self._DropOffConnection then
			self._DropOffConnection:Disconnect()
			self._DropOffConnection = nil
		end

		if self._cancelThread and coroutine.status(self._cancelThread) == "suspended" then
			task.cancel(self._cancelThread)
		end
		self._cancelThread = nil

		if self._stealCloneModel then
			self._stealCloneModel:Destroy()
			self._stealCloneModel = nil
		end
	end
	
	-- Begins stealing flow if all validations pass
	function Thing:Steal(player)
		-- === SERVER AUTH / SANITY ===
		if self.State ~= "Display" then return end
		if self.Owner == player then return end
		if PlotHandler:GetPlotFromOwner(player) == nil then return end
		if self.IsBeingStolen then return end

		-- Anti-spam
		if self._LastSteal and (os.clock() - self._LastSteal) < 2 then return end
		self._LastSteal = os.clock()

		-- Character validations
		local char = player.Character
		if not char then return end

		local hrp = char:FindFirstChild("HumanoidRootPart")
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hrp or not hum or hum.Health <= 0 then return end

		-- Must be physically near the item to begin
		if (self.Model:GetPivot().Position - hrp.Position).Magnitude > 10 then
			return
		end

		-- === STATE INIT ===
		self.IsBeingStolen = true
		self.State = "Carry"
		self.CurrentThief = player
		self.Model:SetAttribute("Transparency", 0.5)

		PlayerStealing(player)
		ReplicatedStorage.RemoteEvents.UI.Alert:FireClient(self.Owner, "Someone is stealing your "..self.Name.."!", "err")

		-- Clone visual
		self._stealCloneModel = self.Model:Clone()
		self._stealCloneModel.Parent = workspace
		self._stealCloneModel.PrimaryPart.Anchored = false
		self._stealCloneModel.PrimaryPart:SetNetworkOwner(player)
		self._stealCloneModel:FindFirstChildOfClass("ProximityPrompt"):Destroy()

		for _, part in self._stealCloneModel:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Massless = true
			end
		end
		
		self._stealCloneModel:PivotTo(CFrame.new(hrp.Position + hrp.CFrame.LookVector*2, hrp.Position + hrp.CFrame.LookVector) * CFrame.Angles(0,0,0))

		-- Attach to player
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hrp
		weld.Part1 = self._stealCloneModel.PrimaryPart
		weld.Parent = hrp

		local thiefPlot = PlotHandler:GetPlotFromOwner(player)
		if not thiefPlot then
			self:CancelSteal()
			return
		end

		-- === TOUCH VALIDATION (Server authoritative) ===
		self._DropOffConnection = thiefPlot.Model.StealPart.Touched:Connect(function(hit)
			local hitChar = hit:FindFirstAncestorWhichIsA("Model")
			if hitChar ~= char then return end -- prevents fake triggers

			self:CompleteSteal(player)
		end)

		-- === Cancel watchers ===
		self._cancelThread = task.spawn(function()
			while self.IsBeingStolen do
				task.wait(0.1)
				
				if not player or not player.Parent then
					print("left game")
					self:CancelSteal(); break
				end

				if not player.Character or hum.Health <= 0 then
					self:CancelSteal(); break
				end

				if self.Owner == player then
					self:CancelSteal(); break
				end
			end
		end)
	end

	-- Sells the Thing for 50% of its price
	function Thing:Sell()
		if self.IsBeingStolen then game.ReplicatedStorage.RemoteEvents.UI.Alert.FireClient(self.Owner, "You cannot sell this while someone is stealing from you.", "err") return end
		if self.Owner and self.Owner.leaderstats and self.Owner.leaderstats:FindFirstChild("Cash") then
			local plot = PlotHandler:GetPlotFromOwner(self.Owner)
			
			plot:RemoveThing(self)
			
			self.Owner.leaderstats.Cash.Value += math.floor(self.Price / 2)
			ReplicatedStorage.RemoteEvents.PlaySound:FireClient(self.Owner, game.ReplicatedStorage.SFX.Effects.CashPickup)
			self:Destroy()
		end
	end

	-- Serializes minimal save data
	function Thing:Serialize()
		local mutations = {}
		for _, mutation in ipairs(self.Mutations) do
			table.insert(mutations, mutation.Name)
		end

		return {
			Name = self.Name,
			Mutations = mutations,
			CurrentMoney = self.CurrentMoney,
		}
	end

	-- Creates a deep copy of the Thing
	function Thing:Clone()
		local function deepCopy(tbl)
			local copy = {}
			for k, v in pairs(tbl) do
				copy[k] = type(v) == "table" and deepCopy(v) or v
			end
			return copy
		end

		return Thing.new({
			Name = self.Name,
			Owner = self.Owner,
			ThingID = "_clone",
			Model = self.Model:Clone(),
			Rarity = self.Rarity,
			Price = self.Price,
			Income = self.Income,
			Mutations = deepCopy(self.Mutations),
		})
	end 

	-- Removes Thing from registry and destroys model
	function Thing:Destroy()
		table.remove(Things, table.find(Things, self))
		self.Model:Destroy()
		self.Model = nil
		self = nil
	end
end

return Thing