--!strict

local controllerModule = script.Parent:WaitForChild("Controller", 10)
if not controllerModule or not controllerModule:IsA("ModuleScript") then
	warn("StreakRewards client Controller was not found within 10 seconds.")
	return
end

local Controller = require(controllerModule)
Controller.Start()
