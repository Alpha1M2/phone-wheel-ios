"""Ephemeral CI-only TLS/WebSocket peer; no dependencies or user data."""
import asyncio
import base64
import hashlib
import ssl
import struct
import sys
from pathlib import Path

def frame(opcode, data):
    return bytes([0x80 | opcode, len(data)]) + data

async def handle(reader, writer):
    try:
        request = await reader.readuntil(b'\r\n\r\n')
        headers = dict(line.split(':', 1) for line in request.decode().split('\r\n')[1:] if ':' in line)
        headers = {key.lower(): value.strip() for key, value in headers.items()}
        accept = base64.b64encode(hashlib.sha1((headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        writer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        writer.write(frame(9, b'keepalive'))
        await writer.drain()
        pong = False
        text = None
        while True:
            first, second = await reader.readexactly(2)
            opcode = first & 15
            size = second & 127
            if size == 126: size = struct.unpack('!H', await reader.readexactly(2))[0]
            if size == 127: size = struct.unpack('!Q', await reader.readexactly(8))[0]
            if size > 8192: raise ValueError('oversized smoke frame')
            mask = await reader.readexactly(4) if second & 128 else None
            data = await reader.readexactly(size)
            if mask: data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            if opcode == 8: break
            if opcode == 10 and data == b'keepalive': pong = True
            if opcode == 1: text = data
            if pong and text is not None:
                writer.write(frame(1, b'echo:' + text)); await writer.drain(); text = None
    except (asyncio.IncompleteReadError, ConnectionError, ssl.SSLError):
        pass
    finally:
        writer.close()
        try: await writer.wait_closed()
        except (ConnectionError, ssl.SSLError): pass

async def main():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    server = await asyncio.start_server(handle, '127.0.0.1', 19876, ssl=context)
    Path(sys.argv[3]).touch()
    async with server: await server.serve_forever()

asyncio.run(main())
