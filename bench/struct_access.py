class Point:
    __slots__ = ('x', 'y')
    def __init__(self, x, y):
        self.x = x
        self.y = y

def access_fields(p, n):
    total = 0.0
    for i in range(n):
        total += p.x + p.y
    return total

p = Point(1.0, 2.0)
print(access_fields(p, 10000000))
