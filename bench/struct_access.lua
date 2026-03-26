local function access_fields(p, n)
    local total = 0.0
    for i = 1, n do
        total = total + p.x + p.y
    end
    return total
end

local p = {x = 1.0, y = 2.0}
print(access_fields(p, 10000000))
