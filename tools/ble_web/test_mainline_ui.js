// Execute the real page script against a minimal DOM and replay real RV32 UART data.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const { Receiver, crc32 } = require('./ble_proto.js');

const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const mobile = fs.readFileSync(path.join(__dirname, 'index_mobile.html'), 'utf8');
const code = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');

const els = new Map();
function element(id) {
  if (!els.has(id)) {
    els.set(id, {
      id, value: '', textContent: '', innerHTML: '', hidden: false, disabled: false,
      style: { setProperty() {} }, dataset: {}, options: [], childNodes: [],
      classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
      appendChild(x) { this.childNodes.push(x); },
      removeChild() { this.childNodes.shift(); },
      addEventListener() {}, removeEventListener() {},
      setAttribute() {}, getAttribute() { return null; },
    });
  }
  return els.get(id);
}

const writes = [];
const context = {
  writes,
  document: {
    getElementById: element,
    querySelectorAll: () => [],
    createElement: () => element('child' + Math.random()),
    documentElement: { style: { setProperty() {} } },
  },
  window: { isSecureContext: true, addEventListener() {} },
  navigator: { bluetooth: {} },
  location: { protocol: 'file:', origin: 'file://', hostname: '' },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  TextEncoder, TextDecoder, Uint8Array, Blob: class {}, URL,
  BleProto: { Receiver }, console,
  setTimeout: () => 1, clearTimeout() {},
};
vm.createContext(context);
vm.runInContext(code, context);

function run(expr) { return vm.runInContext(expr, context); }
function line(s) { run(`rx.h.line(${JSON.stringify(s)})`); }

// ---- UI state follows the board's text lines ----
for (const [n, label] of [[0, 'G3 马赛克'], [1, 'G1 星空'], [2, 'G2 糖果'], [3, 'G4 羽毛']]) {
  line(`KNOB,${n}`);
  assert.equal(element('knob').textContent, `旋钮 ${label}`);
}
line('SLOT,2');
assert.equal(run('styleBank'), 2);
line('TIER,2,4,0');
assert.equal(element('tierNow').textContent, '马赛克 · 100%');
assert.equal(run('styleTiers[2]'), 4);
line('OSD,1');
assert.equal(element('osd').textContent, 'OSD 开');
line('VIEW,1');
assert.equal(element('view').textContent, '视图 对比');
element('rate').options = ['800', '1500', '2500', '4000', '6000', '9000'].map(value => ({ value }));
line('RATE,2500');
assert.equal(element('rate').value, '2500');

// ---- style/tier clicks emit SLOT/TIER over GATT ----
run(`writeChar = {
  properties: { writeWithoutResponse: true },
  async writeValueWithoutResponse(bytes) { writes.push(new TextDecoder().decode(bytes)); }
}`);
run('selectStyle(1)');
run('selectTier(3)');
Promise.resolve(run('writeChain')).then(() => {
  const sent = writes.join('');
  assert(sent.includes('SLOT,1\r\n'), 'expected SLOT,1, got ' + JSON.stringify(sent));
  assert(sent.includes('TIER,1,3\r\n'), 'expected TIER,1,3, got ' + JSON.stringify(sent));
  assert.equal(run('styleBank'), 1);
  assert.equal(run('styleTiers[1]'), 3);
  assert.equal(element('tierNow').textContent, '糖果 · 70%');

  // ---- page wiring ----
  for (const page of [html, mobile]) {
    assert(/<link rel="manifest" href="\.\/manifest/.test(page));
    assert(page.includes('src="./app.js"') || page.includes('src="app.js"'));
    assert(page.includes('id="installBtn"'));
    assert.equal((page.match(/class="style-card/g) || []).length, 4);
    assert.equal((page.match(/data-tier="/g) || []).length, 5);
  }
  assert(fs.existsSync(path.join(__dirname, 'sw.js')));
  assert(fs.existsSync(path.join(__dirname, 'manifest.webmanifest')));
  assert(fs.existsSync(path.join(__dirname, 'icons', 'icon-192.png')));
  console.log('PASS page script: KNOB/SLOT/TIER/OSD/VIEW/RATE updates, SLOT/TIER writes, PWA wiring');

  // ---- receiver replay: real RV32 320x240 JPEG byte-for-byte ----
  const dir = path.resolve(__dirname, '../../deliverable/qse_mainline_merge_20261030/reports');
  const stream = fs.readFileSync(path.join(dir, 'snapshot_stream.bin'));
  const jpg = fs.readFileSync(path.join(dir, 'snapshot.jpg'));
  function replay(bytes) {
    let image;
    const errs = [];
    const rx = new Receiver({
      send() {}, line() {}, progress() {}, image: d => (image = Buffer.from(d)), error: e => errs.push(e),
    });
    for (let i = 0; i < bytes.length; i += 20) rx.push(bytes.subarray(i, i + 20));
    assert.deepEqual(errs, []);
    assert(image && image.equals(jpg));
  }
  replay(stream);

  // Corrupt/drop packet 2, then supply the actual board's packets again as go-back-N retransmission.
  const at = stream.indexOf(Buffer.from([0xa5, 0x5a, 2, 0]));
  assert(at >= 0);
  const len = stream[at + 4] + 7;
  const corrupt = Buffer.from(stream);
  corrupt[at + 9] ^= 0x40;
  const end = stream.indexOf(Buffer.from('IMG,END'));
  const data = stream.subarray(0, end);
  replay(Buffer.concat([corrupt.subarray(0, end), data, Buffer.from('IMG,END\r\n')]));
  replay(Buffer.concat([
    stream.subarray(0, at), stream.subarray(at + len, end), data, Buffer.from('IMG,END\r\n'),
  ]));
  console.log('PASS receiver: real 320x240 JPEG byte-for-byte, CRC, fragmented BLE notifications, loss/corruption recovery', crc32(jpg).toString(16));
}).catch(e => {
  console.error(e);
  process.exit(1);
});
