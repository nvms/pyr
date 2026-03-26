local n = 1000000
local total = 0
for i = 0, n - 1 do
    local d = { x = i, y = i + 1, z = i + 2 }
    total = total + d.x + d.y + d.z
end
print(total)
