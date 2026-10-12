import time
from pathlib import Path
import serial

root = Path(__file__).resolve().parent
ports = []
for name in ('COM4', 'COM6', 'COM3'):
    try:
        connection = serial.Serial(name, 115200, timeout=0)
        output = (root / ('uart_' + name + '.log')).open('wb', buffering=0)
        ports.append((name, connection, output))
        print('Capturing ' + name, flush=True)
    except Exception as exc:
        print(name + ': ' + str(exc), flush=True)
deadline = time.monotonic() + 180
try:
    while time.monotonic() < deadline and not (root / 'stop_uart').exists():
        for name, connection, output in ports:
            data = connection.read(65536)
            if data:
                output.write(data)
                print(name + ': ' + data.decode('ascii', errors='replace'), end='', flush=True)
        time.sleep(0.05)
finally:
    for name, connection, output in ports:
        connection.close()
        output.close()
