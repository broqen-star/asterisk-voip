#!/usr/bin/env python3
"""
Linphoneで '##' が押されたときにdialplanから呼ばれるAGI。
自分(self)チャネルのBRIDGEPEER（=ht813側チャネル）へAMI経由でSendFlashを1回投げるだけ。
"""
import socket
import sys
import time

AMI_HOST = "127.0.0.1"
AMI_PORT = 5038
AMI_USER = "hookflash"
AMI_SECRET = "hookflash"  # ← 必ず変更してください


def agi_read_env():
    env = {}
    while True:
        line = sys.stdin.readline().strip()
        if line == "":
            break
        key, _, value = line.partition(":")
        env[key.strip()] = value.strip()
    return env


def agi_cmd(cmd):
    sys.stdout.write(cmd + "\n")
    sys.stdout.flush()
    return sys.stdin.readline()


def main():
    agi_read_env()

    resp = agi_cmd("GET VARIABLE BRIDGEPEER")
    peer = None
    if "(" in resp and ")" in resp:
        peer = resp.split("(", 1)[1].rsplit(")", 1)[0].strip()

    if not peer:
        agi_cmd('VERBOSE "hookflash: BRIDGEPEER not found" 1')
        return

    try:
        s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
        s.recv(4096)  # banner
        s.sendall(
            f"Action: Login\r\nUsername: {AMI_USER}\r\nSecret: {AMI_SECRET}\r\n\r\n".encode()
        )
        time.sleep(0.2)
        s.recv(4096)

        s.sendall(f"Action: SendFlash\r\nChannel: {peer}\r\n\r\n".encode())
        time.sleep(0.2)
        s.recv(4096)

        s.sendall(b"Action: Logoff\r\n\r\n")
        s.close()
    except OSError as e:
        agi_cmd(f'VERBOSE "hookflash: AMI error {e}" 1')


if __name__ == "__main__":
    main()