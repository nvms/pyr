local function apply_n(f, x, n)
    local result = x
    for i = 1, n do
        result = f(result)
    end
    return result
end

local step = 3
local inc = function(n) return n + step end
print(apply_n(inc, 0, 10000000))
