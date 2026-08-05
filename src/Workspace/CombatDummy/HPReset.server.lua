local hum = script.Parent:WaitForChild("Humanoid")
while true do
    task.wait(10)
    hum.Health = hum.MaxHealth
end
