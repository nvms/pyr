import threading
import queue

def main():
    ch = queue.Queue(maxsize=100)
    n = 100000

    def producer():
        for i in range(n):
            ch.put(i)

    t = threading.Thread(target=producer)
    t.start()

    total = 0
    for _ in range(n):
        total += ch.get()

    t.join()
    print(total)

main()
