local n = 100000
local buffer = {}
local head, tail = 1, 0

local function send(v)
    tail = tail + 1
    buffer[tail] = v
end

local function recv()
    local v = buffer[head]
    buffer[head] = nil
    head = head + 1
    return v
end

for i = 0, n - 1 do
    send(i)
end

local sum = 0
for _ = 1, n do
    sum = sum + recv()
end
print(sum)
