// Replays a real board capture (deliverable/qse_mainline_merge_20261030/reports/snapshot_stream.bin)
// through the browser receiver in 20-byte BLE notifications.
//   node tools/ble_web/test_ble_proto.js
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { Receiver, crc32 } = require('./ble_proto.js');

const root = path.resolve(__dirname, '../..');
const dir = path.join(root, 'deliverable/qse_mainline_merge_20261030/reports');
const stream = fs.readFileSync(path.join(dir, 'snapshot_stream.bin'));
const expected = fs.readFileSync(path.join(dir, 'snapshot.jpg'));

// Byte offsets of every packet in the stream.
function packets(buf) {
  const out = [];
  for (let i = 0; i + 5 <= buf.length; i++)
    if (buf[i] === 0xa5 && buf[i + 1] === 0x5a) { out.push({ at: i, seq: buf[i + 2] | buf[i + 3] << 8, len: buf[i + 4] }); i += buf[i + 4] + 6; }
  return out;
}

function run(name, bytes) {
  const sent = [], lines = [], errors = [];
  let image = null;
  const rx = new Receiver({
    send: s => sent.push(s), line: s => lines.push(s), error: e => errors.push(e),
    image: (d, im) => { image = { d, im }; },
  });
  for (let i = 0; i < bytes.length; i += 20) rx.push(bytes.subarray(i, i + 20));
  assert.deepStrictEqual(errors, [], name);
  assert.ok(image, `${name}: no image`);
  assert.ok(Buffer.from(image.d).equals(expected), `${name}: image differs`);
  assert.strictEqual(crc32(image.d), image.im.crc);
  console.log(`PASS ${name}: ${image.im.w}x${image.im.h} ${image.d.length} B, sent ${sent.length} replies, text lines ${JSON.stringify(lines)}`);
  return { sent, lines };
}

const all = packets(stream);
assert.ok(all.length > 20);
const imgEnd = stream.indexOf(Buffer.from('IMG,END'));
assert.ok(imgEnd > 0);
const firstTwo = all.find(p => p.seq === 2);

// 1. Exact board output.
run('as sent', stream);

// 2. Drop packet 2: the receiver must NAK, then finish from the board's go-back-N resend.
//    The fixture has no duplicate copy, so replay the whole stream after the gap.
const dropped = Buffer.concat([
  stream.subarray(0, firstTwo.at),
  stream.subarray(firstTwo.at + firstTwo.len + 7, imgEnd),
  stream,
]);
const r2 = run('packet 2 lost', dropped);
assert.ok(r2.sent.includes('NAK,2'), 'NAK,2 not sent');

// 3. Corrupt one payload byte in packet 2: CRC fails, NAK, resend used.
const corrupt = Buffer.from(stream);
corrupt[firstTwo.at + 9] ^= 0x40;
const r3 = run('packet 2 corrupt', Buffer.concat([corrupt.subarray(0, imgEnd), stream]));
assert.ok(r3.sent.includes('NAK,2'), 'NAK,2 not sent for corrupt packet');
assert.deepStrictEqual(r3.lines, [], 'corrupt bytes leaked as text');

// 4. An event line in front of the image header passes through as text.
run('with event line', Buffer.concat([Buffer.from('KNOB,2\r\n'), stream]));
console.log('PASS browser receiver');
