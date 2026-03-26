local function sum_range(n)
    local total = 0
    for i = 0, n - 1 do
        total = total + i
    end
    return total
end

print(sum_range(10000000))
