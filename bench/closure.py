def apply_n(f, x, n):
    result = x
    for i in range(n):
        result = f(result)
    return result

step = 3
inc = lambda n: n + step
print(apply_n(inc, 0, 10000000))
