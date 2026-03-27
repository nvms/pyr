def double(x):
    return x * 2

def add(a, b):
    return a + b

sum = 0
for i in range(10000000):
    sum = sum + double(i)
    sum = sum + add(i, 1)
print(sum)
