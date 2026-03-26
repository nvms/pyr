class Add:
    def __init__(self, n): self.n = n
class Sub:
    def __init__(self, n): self.n = n
class Nop:
    pass

def apply(op, val):
    if isinstance(op, Add): return val + op.n
    if isinstance(op, Sub): return val - op.n
    return val

a = Add(3)
s = Sub(1)
n = Nop()

result = 0
for i in range(10000000):
    result = apply(a, result)
    result = apply(s, result)
    result = apply(n, result)
print(result)
