local function double(x)
    return x * 2
end

local function add(a, b)
    return a + b
end

local sum = 0
for i = 0, 9999999 do
    sum = sum + double(i)
    sum = sum + add(i, 1)
end
print(sum)
