from pathlib import Path
import subprocess,shlex,re,json,shutil
r=Path(__file__).resolve().parents[1]
base=r.parent/'Ti60f225_soc_cam_hdmi_style_demo'
rep=r/'reports/versions/lite-unified-clock-experiment'
installation=Path('/home/goodmann/efinity/2026.1/ipm/ip/efx_soc/efx_soc')
config=(base/'soc/efx_sapphire_soc/soc/source/soc_config').read_text()
boot=installation/'generator/bootloader/bootloader_124K.hex'
config=re.sub(r'^--ramHex .*$', '--ramHex '+str(boot),config,flags=re.M)
config+='\n--noDdrAClock\n--lowArea 5\n'
# Standard has M and barrel shifter enabled and full CSR. Do not emit disabling switches.
(rep/'soc_config_lite').write_text(config)
work=r/'work_lite_generator';work.mkdir(exist_ok=True)
(work/'hardware/netlist').mkdir(parents=True,exist_ok=True)
(work/'bsp/efinix/EfxSapphireSoc').mkdir(parents=True,exist_ok=True)
cmd=['java','-cp',str(installation/'generator/EfxSapphireSoc.jar'),'saxon.board.efinix.EfxSapphireSoc']+shlex.split(config)+['--bsp',str(work/'bsp/efinix/EfxSapphireSoc')]
(rep/'generation_command.json').write_text(json.dumps(cmd,indent=2))
p=subprocess.run(cmd,cwd=work,capture_output=True,text=True)
(rep/'generation.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr);p.check_returncode()
s=(work/'hardware/netlist/EfxSapphireSoc.v').read_text()
assert 'system_ddr_ddrLogic_cc_fifo' not in s
assert not re.search(r'input\s+(?:wire\s+)?io_memoryClk\b',s)
# Match the original public wrapper, retaining unused memory reset output as a system-reset alias.
old=(base/'soc/efx_sapphire_soc/soc/soc.v').read_text()
wrapper=old[:old.index('// Generator :')]
wrapper=re.sub(r'^\s*input io_memoryClk,\s*$', '', wrapper, flags=re.M)
wrapper=re.sub(r'^.*\.io_memoryClk \( io_memoryClk \),?\s*$', '',wrapper,flags=re.M)
wrapper=re.sub(r'^.*\.io_memoryReset \( io_memoryReset \),?\s*$', '',wrapper,flags=re.M)
wrapper=wrapper.replace('module soc\n','module soc\n')
# Insert the alias inside the outer wrapper, before its endmodule.
pos=wrapper.index('endmodule')
wrapper=wrapper[:pos]+'assign io_memoryReset = io_systemReset;\n'+wrapper[pos:]
# Apply the same module namespace macro used by the IP manager, including protected CPU module names.
s=re.sub(r'\b(EfxSapphireSoc)(?!\.v)\b',r'`IP_MODULE_NAME(\1)',s)
for name in ['EfxCPUSp1.v','EfxCPUSp2.v']:
 s+='\n'+(installation/'source_efinity'/name).read_text()
(r/'soc/efx_sapphire_soc/soc/soc.v').write_text(wrapper+s+'\n`undef IP_UUID\n`undef IP_NAME_CONCAT\n`undef IP_MODULE_NAME\n')
for p in (work/'hardware/netlist').glob('*.bin'):
 shutil.copy2(p,r/'soc/efx_sapphire_soc/soc'/p.name)
settings=r/'soc/efx_sapphire_soc/soc/settings.json';d=json.loads(settings.read_text())
for k,v in {'SOC_MODE':'1','DDRCLK_DOMAIN':'1','DDR_OPT':'0','MULDIV_EXT':"1'b1",'BARREL_SHIFTER':"1'b1",'REDUCED_CSR':"1'b0"}.items():d['conf'][k]=v
settings.write_text(json.dumps(d,indent=2)+'\n')
print('Installed generated Lite candidate into copied project only.')
