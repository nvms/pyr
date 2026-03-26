local arr = {}
for i = 0, 99 do
    arr[i] = i
end
local s = 0
for i = 0, 9999999 do
    s = s + arr[i % 100]
end
print(s)
