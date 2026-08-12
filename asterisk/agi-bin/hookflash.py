#!/usr/bin/env python3
import socket
import sys
import time

AMI_HOST = "127.0.0.1"
AMI_PORT = 5038
AMI_USER = "hookflash"
AMI_SECRET = "hookflash"


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


def ami_recv(s):
    time.sleep(0.2)
    try:
        return s.recv(4096).decode(errors="replace")
    except OSError:
        return ""


def main():
    agi_read_env()

    resp = agi_cmd("GET VARIABLE BRIDGEPEER")
    peer = None
    if "(" in resp and ")" in resp:
        peer = resp.split("(", 1)[1].rsplit(")", 1)[0].strip()

    if not peer:
        agi_cmd('VERBOSE "hookflash: BRIDGEPEER not found" 1')
        return

    agi_cmd(f'VERBOSE "hookflash: target={peer}" 1')

    try:
        s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
        ami_recv(s)  # banner

        login_action = (
            "Action: Login\r\n"
            f"Username: {AMI_USER}\r\n"
            f"Secret: {AMI_SECRET}\r\n"
            "\r\n"
        )
        s.sendall(login_action.encode())
        login_resp = ami_recv(s)
        agi_cmd(f'VERBOSE "hookflash: login_resp={login_resp.strip()!r}" 1')

        flash_action = (
            "Action: SendFlash\r\n"
            f"Channel: {peer}\r\n"
            "\r\n"
        )
        s.sendall(flash_action.encode())
        flash_resp = ami_recv(s)
        agi_cmd(f'VERBOSE "hookflash: flash_resp={flash_resp.strip()!r}" 1')

        s.sendall(b"Action: Logoff\r\n\r\n")
        s.close()
    except OSError as e:
        agi_cmd(f'VERBOSE "hookflash: AMI error {e}" 1')


if __name__ == "__main__":
    main()