import json
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
import serial

root = Path(__file__).resolve().parent
port = serial.Serial('COM4', 115200, timeout=0.1)
pending = b''
start = time.monotonic()
print('Capturing COM4 115200 8N1', flush=True)
with (root / 'uart_COM4.log').open('wb', buffering=0) as raw, (root / 'uart_timestamped.jsonl').open('w', encoding='utf-8') as log:
    try:
        while time.monotonic() - start < 240 and not (root / 'stop_uart').exists():
            data = port.read(65536)
            if not data:
                continue
            raw.write(data)
            pending += data
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                message = line.decode('ascii', errors='replace').strip()
                now = datetime.now(timezone(timedelta(hours=8))).isoformat(timespec='milliseconds')
                log.write(json.dumps({'time': now, 'seconds': round(time.monotonic()-start, 3), 'line': message}, ensure_ascii=False) + '\n')
                log.flush()
                if message.startswith('VIDEO ') or 'PASS' in message or 'FAIL' in message or 'initialized' in message:
                    print(now + ' ' + message, flush=True)
    finally:
        port.close()
