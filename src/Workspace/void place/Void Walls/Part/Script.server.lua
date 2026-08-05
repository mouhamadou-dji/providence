script.Parent.Touched:connect(Function(hit)
	if hit.parent:FindFirstChild("Humanoid") then
	    hit.parent.Humanoid.Health = 0
    end
 end