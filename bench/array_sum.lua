local arr = {}
for i = 0, 999999 do
    arr[#arr + 1] = i
end
local s = 0
for _, x in ipairs(arr) do
    s = s + x
end
print(s)
