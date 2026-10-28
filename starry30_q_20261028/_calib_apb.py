import socket, time, re, sys

VIDEO=0xf8100000
R_SHADOW, G_SHADOW, B_SHADOW = 0x040, 0x044, 0x048
CFG_APPLY, CFG_STATUS = 0x050, 0x054

def connect():
    s = socket.create_connection(('127.0.0.1',4444),timeout=20); s.settimeout(8)
    def rd(t=1.0):
        o=b''; e=time.time()+t
        while time.time()<e:
            try:
                x=s.recv(65536)
                if not x: break
                o+=x
            except socket.timeout: break
        return o.decode('utf-8','replace')
    rd(1)
    def cmd(c,t=3.0):
        s.sendall((c+'\n').encode()); time.sleep(0.3); return rd(t)
    return s, cmd

def wr(cmd, addr, val):
    cmd('mww 0x%08x 0x%08x' % (addr,val), 2)

def rdw(cmd, addr):
    r = cmd('mdw 0x%08x 1' % addr, 2)
    m = re.search(r'0x[0-9a-f]+:\s*([0-9a-f]{8})', r.replace('\r',''))
    return int(m.group(1),16) if m else None

def apply_gains(cmd, r,g,b, verbose=True):
    cmd('halt',2)
    wr(cmd, VIDEO+R_SHADOW, r)
    wr(cmd, VIDEO+G_SHADOW, g)
    wr(cmd, VIDEO+B_SHADOW, b)
    wr(cmd, VIDEO+CFG_APPLY, 1)
    time.sleep(0.1)
    st = rdw(cmd, VIDEO+CFG_STATUS)
    ra_ = rdw(cmd, VIDEO+0x060)
    ga_ = rdw(cmd, VIDEO+0x064)
    ba_ = rdw(cmd, VIDEO+0x068)
    cmd('resume',1)
    if verbose:
        print("  写 R=%d G=%d B=%d  => STATUS=0x%x ACTIVE=%s,%s,%s" % (
            r,g,b, st or 0, ra_, ga_, ba_))
    return (ra_,ga_,ba_)

if __name__=='__main__':
    s,cmd = connect()
    print("=== 当前增益 ===")
    cmd('halt',2)
    print("  R=%s G=%s B=%s STATUS=0x%x" % (
        rdw(cmd,VIDEO+0x060), rdw(cmd,VIDEO+0x064), rdw(cmd,VIDEO+0x068), rdw(cmd,VIDEO+CFG_STATUS) or 0))
    cmd('resume',1)
    s.close()
