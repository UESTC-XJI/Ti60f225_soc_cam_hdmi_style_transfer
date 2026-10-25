"""Cycle-level trace of the shared DDR read channel in the integrated style system.

Reuses the testbench generator in tools/test_style_system.py (same stimulus:
prepared display pair in slot0, 640xH CNN job in slot1, one dense 1080p camera
frame into slot2, randomized DDR stalls) and injects a recorder sampled on the
falling edge of the 100 MHz AXI clock. Output per variant:

  reports/ddr_read_trace/<variant>[_vgaH]/read_channel.trace   raw events
  reports/ddr_read_trace/<variant>[_vgaH]/simulation.log

Trace line formats (cycle = 100 MHz cycles after reset release):
  C <cycle> <code>          state change, code bits below (run-length encoded)
  A <cycle> <owner> <arlen> AR handshake on the DDR side, owner 0=CNN 1=display
  E <cycle>                 RLAST handshake
  L <cycle> <level>         display pixel FIFO write-side level, every 32 cycles
  N <cycle> <layer>         CNN layer index change

code[2:0] phase: 0 idle, 1 AR valid, 2 waiting for RVALID, 3 beat, 4 RREADY low
code[3] owner of the in-flight burst (1=display), code[4] CNN AR waiting at
the bridge, code[5] display AR waiting at the bridge, code[6] display urgent,
code[7] CNN in READWAIT/SKIPWAIT, code[8] CNN core busy, code[9] CNN job busy.

Behavioural DDR model only; no outer CPU traffic, no DDR PHY timing.
Example: python tools/trace_ddr_read.py --variant adaptive
"""
from pathlib import Path
import argparse, os, re, shutil, subprocess, sys, time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = os.name == 'nt'
# Native Linux build used by tools/run_native.py; fall back to PATH.
NATIVE_BIN = Path.home() / '.hermes/cache/scratch/ti60_sim_bin'


def default_tool(name):
    if WINDOWS:
        return f'C:/iverilog/bin/{name}.exe'
    native = NATIVE_BIN / name
    return str(native) if native.exists() else name

TRACE_BLOCK = r'''
  // ---- injected by tools/trace_ddr_read.py ----
  integer trace_fd=0,trace_cycle=0,trace_code=-1,trace_new,trace_layer=-1;
  string trace_file;
  initial if($value$plusargs("trace=%s",trace_file))begin
    trace_fd=$fopen(trace_file,"w");if(!trace_fd)$fatal(1,"cannot open trace file");
  end
  wire [2:0] trace_phase=!dut.bridge.rd_busy ? 3'd0 : arvalid ? 3'd1 : !rvalid ? 3'd2 : rready ? 3'd3 : 3'd4;
  always @(posedge clk) if(rst_n) trace_cycle<=trace_cycle+1;
  always @(negedge clk) if(trace_fd&&rst_n) begin
    trace_new={22'b0,dut.accelerator.network.busy,dut.accelerator.network.core_busy,
      (dut.accelerator.network.state==4||dut.accelerator.network.state==6),
      dut.display_read_urgent,(dut.v_arvalid&&!dut.v_arready),(dut.c_arvalid&&!dut.c_arready),
      dut.bridge.rd_owner,trace_phase};
    if(trace_new!=trace_code)begin $fwrite(trace_fd,"C %0d %0d\n",trace_cycle,trace_new);trace_code=trace_new;end
    if(arvalid&&arready)$fwrite(trace_fd,"A %0d %0d %0d\n",trace_cycle,dut.bridge.rd_owner,arlen);
    if(rvalid&&rready&&rlast)$fwrite(trace_fd,"E %0d\n",trace_cycle);
    if(trace_cycle%32==0)$fwrite(trace_fd,"L %0d %0d\n",trace_cycle,dut.display.pixel_level);
    if(dut.accelerator.network.layer_index!=trace_layer)begin
      trace_layer=dut.accelerator.network.layer_index;$fwrite(trace_fd,"N %0d %0d\n",trace_cycle,trace_layer);
    end
  end
  final if(trace_fd)$fclose(trace_fd);
  // ---- end of injected recorder ----
'''


def build_testbench(variant, height):
    """Run the testbench-building part of test_style_system.py unchanged."""
    source = (ROOT / 'tools/test_style_system.py').read_text(encoding='utf-8')
    begin = source.index("text=(ROOT/'reports/style_demo/accel/tb.sv').read_text()")
    end = source.index("tb=OUT/'tb.sv'")
    scope = {'ROOT': ROOT, 'args': SimpleNamespace(variant=variant, height=height, tag='')}
    exec(compile(source[begin:end], 'test_style_system.py', 'exec'), scope)
    text = scope['text']
    anchor = '  always @(posedge clk) begin\n    rng<='
    assert text.count(anchor) == 1, 'testbench layout changed; update the trace anchor'
    return text.replace(anchor, TRACE_BLOCK + anchor)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--variant', choices=['baseline', 'buffer', 'adaptive'], default='adaptive')
    p.add_argument('--height', type=int, default=48)
    p.add_argument('--iverilog', default=default_tool('iverilog'))
    p.add_argument('--vvp', default=default_tool('vvp'))
    args = p.parse_args()
    assert 24 <= args.height <= 480 and args.height % 4 == 0
    for tool in (args.iverilog, args.vvp):
        if not shutil.which(tool):
            sys.exit(f'{tool} not found. Install Icarus Verilog (e.g. sudo apt install iverilog) '
                     f'or pass --iverilog/--vvp with full paths.')

    fixture = ROOT / f'reports/style_demo/vga_{args.height}'
    if not all((fixture / n).exists() for n in ['input.hex', 'expected.hex']):
        subprocess.run([sys.executable, 'tools/test_style_vga.py', '--height', str(args.height), '--fixtures-only'], cwd=ROOT, check=True)
    if not (ROOT / 'reports/style_demo/accel/tb.sv').exists():
        subprocess.run([sys.executable, 'tools/test_style_accel.py'], cwd=ROOT, check=True)

    name = args.variant + ('' if args.height == 48 else f'_vga{args.height}')
    out = ROOT / 'reports/ddr_read_trace' / name
    out.mkdir(parents=True, exist_ok=True)
    tb = out / 'tb.sv'
    tb.write_text(build_testbench(args.variant, args.height), encoding='utf-8')
    sim = out / 'test.vvp'
    modules = [q.relative_to(ROOT).as_posix() for q in sorted((ROOT / 'rtl/style').glob('*.sv'))]
    modules.append('rtl/soc_integration/axi_shared_ddr_2m.sv')
    c = subprocess.run([args.iverilog, '-g2012', '-grelative-include', '-s', 'style_system_tb', '-o', str(sim), str(tb), *modules],
                       cwd=ROOT, capture_output=True, text=True)
    if c.returncode:
        sys.exit(c.stderr)
    trace = out / 'read_channel.trace'
    t = time.monotonic()
    with (out / 'simulation.log').open('w') as log:
        r = subprocess.run([args.vvp, str(sim), '+input=' + str(fixture / 'input.hex'),
                            '+expected=' + str(fixture / 'expected.hex'), '+trace=' + str(trace)],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=5400)
    result = (out / 'simulation.log').read_text()
    print(result[-600:])
    if r.returncode or not re.search(r'^PASS ', result, re.M):
        sys.exit(f'simulation failed, see {out / "simulation.log"}')
    print(f'trace {trace} ({trace.stat().st_size >> 10} KiB) in {time.monotonic() - t:.0f}s')


if __name__ == '__main__':
    main()
