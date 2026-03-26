class Data:
    __slots__ = ('x', 'y', 'z')
    def __init__(self, x, y, z):
        self.x = x
        self.y = y
        self.z = z

n = 1000000
total = 0
for i in range(n):
    d = Data(i, i + 1, i + 2)
    total += d.x + d.y + d.z
print(total)
