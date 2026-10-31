// Ti60 style-transfer BLE console. Shared by index.html (desktop) and index_mobile.html.
// Protocol lives in ble_proto.js; this file only drives the UI and the GATT link.
'use strict';

const $ = id => document.getElementById(id);
const $$ = sel => Array.from(document.querySelectorAll(sel));

const PROFILES = {
  ffe0: { service: 0xffe0, notify: 0xffe1, write: 0xffe1 },
  fff0: { service: 0xfff0, notify: 0xfff1, write: 0xfff2 },
  nus: {
    service: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    notify: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    write: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  },
};
const STORE = 'ti60-ble-profile';
const enc = new TextEncoder();

const STYLES = [
  { name: 'starry', label: '星空', color: '#5b6cff' },
  { name: 'candy', label: '糖果', color: '#f2559c' },
  { name: 'mosaic', label: '马赛克', color: '#0fb5a6' },
  { name: 'feathers', label: '羽毛', color: '#f0a020' },
];
const TIER_PCT = ['10%', '30%', '50%', '70%', '100%'];
const VIEW_NAMES = { 0: '单风格', 1: '对比', 2: '原画' };
// Raw knob positions are not sequential: 0=G3, 1=G1, 2=G2, 3=G4 (see main.c).
const KNOB_LABELS = ['G3 马赛克', 'G1 星空', 'G2 糖果', 'G4 羽毛'];

let device = null, notifyChar = null, writeChar = null, writeChain = Promise.resolve();
let styleBank = 0;
const styleTiers = [2, 2, 2, 2];   // per-style memory; board default is the middle tier

let snapping = false, current = null, garbage = 0;
const shots = [];
let supported = true;

// ---------- log ----------

function log(msg, cls) {
  const el = $('log');
  if (!el) return;
  const line = document.createElement('div');
  line.textContent = `${new Date().toLocaleTimeString()}  ${msg}`;
  if (cls) line.className = cls;
  el.appendChild(line);
  while (el.childNodes.length > 400) el.removeChild(el.firstChild);
  el.scrollTop = el.scrollHeight;
}

// ---------- connection status ----------

function setStatus(state, text) {
  const pill = $('statusPill');
  pill.dataset.state = state;
  $('statusText').textContent = text;
}

function setConnected(on) {
  $('connect').disabled = on || !supported;
  $('disconnect').disabled = !on;
  $('snap').disabled = !on || snapping;
  $('abort').disabled = !snapping;
  $('send').disabled = !on;
  $('text').disabled = !on;
  for (const b of $$('.ctl')) b.disabled = !on;
  for (const b of $$('.style-card')) b.disabled = !on;
  for (const b of $$('.tier')) b.disabled = !on;
  if (!on) {
    notifyChar = writeChar = null;
    $('deviceChip').textContent = '未连接';
    $('deviceChip').classList.remove('on');
  }
  updateStyleUI();
}

function checkSupport() {
  let why = '';
  if (!window.isSecureContext) {
    why = `当前地址 <code>${location.origin}</code> 不是安全上下文，浏览器关闭了蓝牙接口。<br>
      远程打开时二选一：<br>
      1. 在本设备的 Chrome 打开 <code>chrome://flags/#unsafely-treat-insecure-origin-as-secure</code>，
         填入 <code>${location.origin}</code>，设为 Enabled 并重启浏览器；<br>
      2. 用 <code>serve.py --https</code> 启动，并信任它的证书。`;
  } else if (!navigator.bluetooth) {
    why = `需要电脑或安卓上的 Chrome / Edge。Firefox、Safari 和 iPhone 上的浏览器不支持 Web Bluetooth。
      Linux 上的 Chrome 可能还需要在 <code>chrome://flags</code> 启用 Experimental Web Platform features。`;
  }
  if (why) {
    supported = false;
    $('warn').hidden = false;
    $('warnText').innerHTML = why;
    $('connect').disabled = true;
  }
}

function profileList() {
  const p = $('profile').value;
  if (p === 'custom') {
    const parse = v => (/^[0-9a-f]{4}$/i.test(v) ? parseInt(v, 16) : v.trim().toLowerCase());
    return [{
      service: parse($('cService').value),
      notify: parse($('cNotify').value),
      write: parse($('cWrite').value),
    }];
  }
  return p === 'auto' ? Object.values(PROFILES) : [PROFILES[p]];
}

async function connect() {
  const list = profileList();
  try {
    device = await navigator.bluetooth.requestDevice({
      acceptAllDevices: true,
      optionalServices: list.map(p => p.service),
    });
  } catch (e) {
    if (e.name !== 'NotFoundError') log(`选择设备失败：${e.message}`, 'err');
    return;
  }
  device.removeEventListener('gattserverdisconnected', onDisconnected);
  device.addEventListener('gattserverdisconnected', onDisconnected);
  setStatus('connecting', '连接中…');
  try {
    const server = await device.gatt.connect();
    let found = null;
    for (const p of list) {
      try {
        const svc = await server.getPrimaryService(p.service);
        found = {
          notify: await svc.getCharacteristic(p.notify),
          write: await svc.getCharacteristic(p.write),
          p,
        };
        break;
      } catch (e) { /* try the next profile */ }
    }
    if (!found) throw new Error('模块上没有找到已知的串口服务，请在“模块 UUID”中填写自定义 UUID');
    notifyChar = found.notify;
    writeChar = found.write;
    notifyChar.removeEventListener('characteristicvaluechanged', onNotify);
    notifyChar.addEventListener('characteristicvaluechanged', onNotify);
    await notifyChar.startNotifications();
    try {
      localStorage.setItem(STORE, JSON.stringify({
        profile: $('profile').value,
        custom: [$('cService').value, $('cNotify').value, $('cWrite').value],
      }));
    } catch (_) { /* private mode / file:// may refuse storage; the link still works */ }
    const name = device.name || 'BLE 设备';
    setStatus('on', '已连接');
    $('deviceChip').textContent = name;
    $('deviceChip').classList.add('on');
    log(`已连接 ${name} · 服务 ${String(found.p.service).slice(0, 8)}`, 'note');
    setConnected(true);
    sendLine(`RATE,${$('rate').value}`);
    sendLine('STATE');
  } catch (e) {
    log(`连接失败：${e.message}`, 'err');
    setStatus('off', '未连接');
    try { device.gatt.disconnect(); } catch (_) {}
    setConnected(false);
  }
}

function onDisconnected() {
  setConnected(false);
  setStatus('off', '已断开');
  log('连接已断开', 'err');
  if (snapping) endSnap('连接断开');
}

// One handler for the page's lifetime: Chrome hands back the same characteristic object
// after a reconnect, and a second listener would deliver every byte twice.
function onNotify(ev) {
  const v = ev.target.value;
  rx.push(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));
}

// ---------- style / tier ----------

function clampTier(t) { return Math.max(0, Math.min(4, t | 0)); }

function updateStyleUI() {
  const bank = Math.max(0, Math.min(3, styleBank | 0));
  const tier = clampTier(styleTiers[bank]);
  document.documentElement.style.setProperty('--tier-accent', STYLES[bank].color);
  for (const b of $$('.style-card')) {
    const on = +b.dataset.bank === bank;
    b.classList.toggle('sel', on);
    b.setAttribute('aria-pressed', String(on));
  }
  for (const b of $$('.tier')) {
    const on = +b.dataset.tier === tier;
    b.classList.toggle('sel', on);
    b.setAttribute('aria-pressed', String(on));
  }
  const now = $('tierNow');
  if (now) now.textContent = `${STYLES[bank].label} · ${TIER_PCT[tier]}`;
}

function selectStyle(bank) {
  styleBank = Math.max(0, Math.min(3, bank | 0));
  updateStyleUI();
  sendLine(`SLOT,${styleBank}`);
}

function selectTier(tier) {
  const bank = styleBank;
  styleTiers[bank] = clampTier(tier);
  updateStyleUI();
  sendLine(`TIER,${bank},${styleTiers[bank]}`);
}

// ---------- GATT writes ----------

// GATT allows one operation at a time; every write goes through one chain.
function write(bytes) {
  if (!writeChar) return Promise.resolve();
  writeChain = writeChain.then(async () => {
    for (let i = 0; i < bytes.length; i += 20) {
      const part = bytes.slice(i, i + 20);
      if (writeChar.properties.writeWithoutResponse) await writeChar.writeValueWithoutResponse(part);
      else await writeChar.writeValueWithResponse(part);
    }
  }).catch(e => log(`写入失败：${e.message}`, 'err'));
  return writeChain;
}

function sendLine(s, quiet) {
  if (!quiet) log(`→ ${s}`, 'tx');
  return write(enc.encode(s + '\r\n'));
}

// ---------- image transfer ----------

const rx = new BleProto.Receiver({
  send: s => sendLine(s, true),
  line: s => {
    // Stray packet bytes (lost sync) are not text; count them instead of printing.
    if (/[^\x20-\x7e\t]/.test(s)) {
      garbage += s.length;
      $('xfer').dataset.garbage = garbage;
      return;
    }
    log(`← ${s}`, 'rx');
    let m;
    if ((m = /^KNOB,(\d)$/.exec(s))) {
      const i = +m[1];
      $('knob').textContent = `旋钮 ${KNOB_LABELS[i] || i}`;
      $('knob').classList.add('on');
      for (const b of $$('.ctl[data-cmd^="KNOB,"]')) {
        b.classList.toggle('active', b.dataset.cmd === `KNOB,${i}`);
      }
    } else if ((m = /^OSD,([01])$/.exec(s))) {
      const on = m[1] === '1';
      $('osd').textContent = `OSD ${on ? '开' : '关'}`;
      $('osd').classList.toggle('on', on);
      $('osdBtn').classList.toggle('active', on);
    } else if ((m = /^VIEW,([0-9])$/.exec(s))) {
      const v = +m[1];
      $('view').textContent = `视图 ${VIEW_NAMES[v] || v}`;
      $('view').classList.toggle('on', v !== 0);
      $('viewBtn').classList.toggle('active', v !== 0);
    } else if ((m = /^RATE,(\d+)$/.exec(s))) {
      const o = Array.from($('rate').options).find(x => x.value === m[1]);
      if (o) $('rate').value = m[1];
    } else if ((m = /^SLOT,(\d+)$/.exec(s))) {
      styleBank = Math.max(0, Math.min(3, +m[1] || 0));
      updateStyleUI();
    } else if ((m = /^TIER,(\d+),(\d+)/.exec(s))) {
      const bank = +m[1];
      if (bank >= 0 && bank < styleTiers.length) {
        styleTiers[bank] = clampTier(+m[2]);
        styleBank = bank;
        updateStyleUI();
      }
    } else if (/^ERR,TIER/.test(s)) {
      log('调档失败：板卡拒绝了这次 TIER 命令', 'err');
    }
  },
  progress: im => {
    setProgress(im.expect, im.packets);
    const t = (Date.now() - im.start) / 1000;
    $('xfer').textContent = `${im.w}×${im.h} · ${im.bytes}/${im.size} B · `
      + `${t > 0.2 ? (im.bytes / 1024 / t).toFixed(1) : '—'} KB/s`
      + (im.naks ? ` · 重传 ${im.naks}` : '');
    if (im.expect === 0) garbage = 0;
  },
  image: (data, im) => {
    const kbs = (im.size / 1024 / Math.max(im.seconds, 0.001)).toFixed(1);
    $('xfer').textContent = `完成：${im.w}×${im.h}，${im.size} B，${im.seconds.toFixed(1)} s，${kbs} KB/s`
      + (im.naks ? `，重传 ${im.naks}` : '');
    log(`收到图像 ${im.w}×${im.h} ${im.size} B，用时 ${im.seconds.toFixed(1)} s，重传 ${im.naks}`
      + (garbage ? `，丢弃失步字节 ${garbage}` : ''), 'note');
    if (im.naks > im.packets / 10) log('重传较多：可以把“板卡发送速率”调低一档', 'err');
    setProgress(im.packets, im.packets);
    addShot(data, im);
    endSnap();
  },
  error: why => {
    log(`图传失败：${why}`, 'err');
    $('xfer').textContent = `失败：${why}`;
    endSnap(why);
  },
});

function setProgress(value, max) {
  const track = $('prog');
  const bar = $('progBar');
  if (!max) {
    track.classList.add('indeterminate');
    bar.style.width = '';
    return;
  }
  track.classList.remove('indeterminate');
  bar.style.width = `${Math.min(100, (value / max) * 100).toFixed(1)}%`;
}

function addShot(data, im) {
  const blob = new Blob([data], { type: 'image/jpeg' });
  const shot = {
    url: URL.createObjectURL(blob),
    w: im.w, h: im.h, size: im.size,
    bank: styleBank,
    tier: styleTiers[styleBank],
    time: new Date(),
  };
  shots.unshift(shot);
  while (shots.length > 30) URL.revokeObjectURL(shots.pop().url);
  showShot(shot);
}

function showShot(s) {
  current = s;
  $('shot').src = s.url;
  $('shot').classList.add('has');
  $('emptyViewer').hidden = true;
  $('save').disabled = false;
  $('shotInfo').textContent = `${s.w}×${s.h} · ${(s.size / 1024).toFixed(1)} KB · `
    + `${STYLES[s.bank]?.label || ''} ${TIER_PCT[s.tier] || ''} · ${s.time.toLocaleTimeString()}`;
  renderGallery();
}

function renderGallery() {
  const g = $('gallery');
  g.textContent = '';
  for (const s of shots) {
    const img = document.createElement('img');
    img.src = s.url;
    img.alt = '历史画面';
    img.className = s === current ? 'sel' : '';
    img.onclick = () => showShot(s);
    g.appendChild(img);
  }
}

// ---------- capture ----------

let snapTimer = 0;

function snap() {
  if (snapping || !writeChar) return;
  snapping = true;
  $('snap').disabled = true;
  $('abort').disabled = false;
  setProgress(0, 0);
  $('xfer').textContent = '板卡正在抓取并编码…';
  sendLine(`SNAP,${$('size').value},${$('quality').value},${$('window').value}`);
  armWatchdog();
}

// The board resends on its own; give up only if nothing arrives for 15 s.
function armWatchdog() {
  clearTimeout(snapTimer);
  snapTimer = setTimeout(() => {
    if (!snapping) return;
    log('15 秒没有收到数据，已中止', 'err');
    sendLine('ABORT');
    endSnap('超时');
  }, 15000);
}

function endSnap(err) {
  clearTimeout(snapTimer);
  snapping = false;
  rx.img = null;
  $('prog').classList.remove('indeterminate');
  $('abort').disabled = true;
  $('snap').disabled = !writeChar;
  if (!err && $('auto').checked && writeChar) setTimeout(snap, 400);
}

// ---------- wiring ----------

$('connect').onclick = connect;
$('disconnect').onclick = () => {
  $('auto').checked = false;
  if (device) device.gatt.disconnect();
};
$('snap').onclick = snap;
$('abort').onclick = () => {
  $('auto').checked = false;
  sendLine('ABORT');
  endSnap('已中止');
};
$('save').onclick = () => {
  if (!current) return;
  const a = document.createElement('a');
  const t = current.time;
  const p = n => String(n).padStart(2, '0');
  const style = STYLES[current.bank]?.name || 'style';
  const pct = (TIER_PCT[current.tier] || '50%').replace('%', '');
  a.href = current.url;
  a.download = `ti60_${style}_${pct}_${t.getFullYear()}${p(t.getMonth() + 1)}${p(t.getDate())}`
    + `_${p(t.getHours())}${p(t.getMinutes())}${p(t.getSeconds())}.jpg`;
  a.click();
};

for (const b of $$('.ctl')) b.onclick = () => sendLine(b.dataset.cmd);

for (const b of $$('.style-card')) b.onclick = () => selectStyle(+b.dataset.bank);
for (const b of $$('.tier')) b.onclick = () => selectTier(+b.dataset.tier);

$('rate').onchange = () => sendLine(`RATE,${$('rate').value}`);
$('send').onclick = () => {
  const v = $('text').value;
  if (v) { sendLine(v); $('text').value = ''; }
};
$('text').onkeydown = e => { if (e.key === 'Enter') $('send').click(); };
$('profile').onchange = () => {
  $('customRow').hidden = $('profile').value !== 'custom';
};

// Any data from the board keeps an in-progress snapshot alive.
const origPush = rx.push.bind(rx);
rx.push = chunk => {
  if (snapping) armWatchdog();
  origPush(chunk);
};

// ---------- PWA ----------

let deferredPrompt = null;
const installBtn = $('installBtn');

window.addEventListener('beforeinstallprompt', e => {
  e.preventDefault();
  deferredPrompt = e;
  if (installBtn) installBtn.hidden = false;
});

if (installBtn) {
  installBtn.addEventListener('click', async () => {
    if (!deferredPrompt) return;
    deferredPrompt.prompt();
    let accepted = false;
    try {
      const choice = await deferredPrompt.userChoice;
      accepted = choice.outcome === 'accepted';
    } catch (_) {}
    deferredPrompt = null;
    installBtn.hidden = true;
    log(accepted ? '已请求安装应用' : '已取消安装', accepted ? 'note' : '');
  });
}

window.addEventListener('appinstalled', () => {
  deferredPrompt = null;
  if (installBtn) installBtn.hidden = true;
  log('已安装到桌面，可从主屏幕直接打开', 'note');
});

if ('serviceWorker' in navigator && /^https?:$/.test(location.protocol)) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  });
}

// ---------- boot ----------

try {
  const saved = JSON.parse(localStorage.getItem(STORE) || 'null');
  if (saved) {
    if (saved.profile) $('profile').value = saved.profile;
    if (Array.isArray(saved.custom)) {
      [$('cService').value, $('cNotify').value, $('cWrite').value] = saved.custom;
    }
    $('profile').onchange();
  }
} catch (_) {}

updateStyleUI();
checkSupport();
setConnected(false);
log('就绪：点“连接蓝牙模块”选择板子', 'note');
