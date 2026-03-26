local function apply(tag, n, val)
    if tag == 1 then return val + n
    elseif tag == 2 then return val - n
    else return val
    end
end

local result = 0
for i = 1, 10000000 do
    result = apply(1, 3, result)
    result = apply(2, 1, result)
    result = apply(3, 0, result)
end
print(result)
