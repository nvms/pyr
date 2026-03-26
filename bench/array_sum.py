arr = []
for i in range(1000000):
    arr.append(i)
s = 0
for x in arr:
    s += x
print(s)
