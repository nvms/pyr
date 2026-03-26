arr = list(range(100))
s = 0
for i in range(10000000):
    s += arr[i % 100]
print(s)
