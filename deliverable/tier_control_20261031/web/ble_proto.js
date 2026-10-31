// Board <-> browser protocol for the Ti60 style demo BLE link (see software/firmware/qse_imgtx.h).
// Plain script: loads from file://, http(s):// and Node (for tools/ble_web/test_ble_proto.js).
(function (root) {
  'use strict';

  const CRC32 = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    CRC32[n] = c >>> 0;
  }
  function crc32(bytes) {
    let c = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) c = CRC32[(c ^ bytes[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }
  // CRC-16/CCITT-FALSE
  function crc16(bytes, start, end) {
    let c = 0xffff;
    for (let i = start; i < end; i++) {
      c ^= bytes[i] << 8;
      for (let b = 0; b < 8; b++) c = c & 0x8000 ? ((c << 1) ^ 0x1021) & 0xffff : (c << 1) & 0xffff;
    }
    return c;
  }

  const MAX_LINE = 256;

  // Splits the byte stream into text lines and image packets, and runs the receive side
  // of the image transfer. send(text) must write one command line to the board.
  class Receiver {
    constructor(handlers) {
      this.h = handlers;           // { send, line, progress, image, error }
      this.buf = new Uint8Array(0);
      this.img = null;
    }

    push(chunk) {
      const merged = new Uint8Array(this.buf.length + chunk.length);
      merged.set(this.buf);
      merged.set(chunk, this.buf.length);
      this.buf = merged;
      let i = 0;
      while (i < this.buf.length) {
        const b = this.buf;
        if (b[i] === 0xa5) {
          if (i + 1 >= b.length) break;
          if (b[i + 1] === 0x5a) {
            if (i + 5 > b.length) break;
            const len = b[i + 4];
            if (i + len + 7 > b.length) break;
            const crc = b[i + len + 5] | (b[i + len + 6] << 8);
            if (crc16(b, i + 2, i + len + 5) === crc) {
              this.packet(b[i + 2] | (b[i + 3] << 8), b.slice(i + 5, i + 5 + len));
              i += len + 7;
            } else {
              // Corrupt packet: drop bytes up to the next packet header.
              if (this.img) this.nak();
              i += 2;
              while (i < b.length && !(b[i] === 0xa5 && (i + 1 >= b.length || b[i + 1] === 0x5a))) i++;
            }
            continue;
          }
        }
        const nl = b.indexOf(0x0a, i);
        const stop = nl < 0 ? -1 : nl;
        // A text line ends at '\n'; a packet header inside it starts over.
        let cut = -1;
        for (let k = i + 1; k < (stop < 0 ? b.length : stop); k++)
          if (b[k] === 0xa5 && (k + 1 >= b.length || b[k + 1] === 0x5a)) { cut = k; break; }
        if (cut >= 0) { this.text(b.slice(i, cut), false); i = cut; continue; }
        if (stop < 0) {
          if (b.length - i > MAX_LINE) { this.text(b.slice(i), false); i = b.length; }
          break;
        }
        this.text(b.slice(i, stop + 1), true);
        i = stop + 1;
      }
      this.buf = this.buf.slice(i);
    }

    text(bytes, complete) {
      let s = '';
      for (const c of bytes) s += String.fromCharCode(c);
      s = s.replace(/\r?\n$/, '');
      if (complete && s.startsWith('IMG,')) { this.imageLine(s); return; }
      if (s.length) this.h.line && this.h.line(s);
    }

    imageLine(s) {
      const f = s.split(',');
      if (f[1] === 'END') {
        if (this.img) this.finish();
        return;
      }
      if (f[1] === 'ERR') {
        this.img = null;
        this.h.error && this.h.error(f.slice(2).join(','));
        return;
      }
      if (f.length !== 6) { this.h.line && this.h.line(s); return; }
      const [w, h, size, packets] = [f[1], f[2], f[3], f[5]].map(Number);
      this.img = {
        w, h, size, packets, crc: parseInt(f[4], 16) >>> 0,
        parts: new Array(packets), expect: 0, bytes: 0, naks: 0, lastNak: -1,
        start: Date.now(),
      };
      this.h.progress && this.h.progress(this.img);
    }

    packet(seq, payload) {
      const im = this.img;
      if (!im) return;
      if (seq === im.expect) {
        im.parts[seq] = payload;
        im.bytes += payload.length;
        im.expect++;
        im.lastNak = -1;
        this.h.send(`ACK,${im.expect}`);
        this.h.progress && this.h.progress(im);
      } else if (seq > im.expect) {
        this.nak();                 // gap: go back to the first missing packet
      } else {
        this.h.send(`ACK,${im.expect}`);   // duplicate after a resend
      }
    }

    nak() {
      const im = this.img;
      if (im.lastNak === im.expect) return;   // one NAK per gap
      im.lastNak = im.expect;
      im.naks++;
      this.h.send(`NAK,${im.expect}`);
    }

    finish() {
      const im = this.img;
      this.img = null;
      if (im.expect !== im.packets) { this.h.error && this.h.error('INCOMPLETE'); return; }
      const data = new Uint8Array(im.size);
      let off = 0;
      for (const p of im.parts) { data.set(p, off); off += p.length; }
      if (off !== im.size || crc32(data) !== im.crc) { this.h.error && this.h.error('CRC'); return; }
      im.seconds = (Date.now() - im.start) / 1000;
      this.h.image && this.h.image(data, im);
    }
  }

  const api = { crc32, crc16, Receiver };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.BleProto = api;
})(this);
