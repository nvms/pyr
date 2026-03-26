local socket = require("socket")

local n = 10000
local server = assert(socket.bind("127.0.0.1", 19962))
server:settimeout(5)

local client = assert(socket.connect("127.0.0.1", 19962))
local conn = assert(server:accept())

for _ = 1, n do
    client:send("ping")
    local data = conn:receive(4)
    conn:send(data)
    client:receive(4)
end

conn:close()
client:close()
server:close()
print(n)
