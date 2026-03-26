import socket
import threading

def main():
    n = 10000
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 19961))
    server.listen(1)

    def handler():
        conn, _ = server.accept()
        for _ in range(n):
            data = conn.recv(4096)
            conn.sendall(data)
        conn.close()

    t = threading.Thread(target=handler)
    t.start()

    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.connect(("127.0.0.1", 19961))
    for _ in range(n):
        client.sendall(b"ping")
        client.recv(4096)
    client.close()
    t.join()
    server.close()
    print(n)

main()
