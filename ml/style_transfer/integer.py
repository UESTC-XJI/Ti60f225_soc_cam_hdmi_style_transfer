"""Independent integer graph oracle. Convolution uses int32 NumPy, affine int64."""
from pathlib import Path
import json
import numpy as np


def round_shift(x,r):
    r=np.asarray(r,dtype=np.int64)
    # Magnitudes fit signed64; exact ties away from zero, including negatives.
    return np.sign(x)*((np.abs(x)+np.where(r>0,1<<np.maximum(r-1,0),0))>>r)


def convolution(x,w,stride,dw):
    k=w.shape[-1]; p=k//2
    z=np.pad(x,((p,p),(p,p),(0,0)))
    windows=np.lib.stride_tricks.sliding_window_view(z,(k,k),axis=(0,1))[::stride,::stride]
    if dw:
        return np.einsum('hwcij,cij->hwc',windows.astype(np.int32),w[:,0].astype(np.int32),optimize=True)
    return np.einsum('hwcij,ocij->hwo',windows.astype(np.int32),w.astype(np.int32),optimize=True)


class IntegerNetwork:
    def __init__(self,path):
        path=Path(path); self.graph=json.loads((path/'graph.json').read_text())
        self.params=np.load(path/'parameters.npz'); self.last_trace=[]
    def __call__(self,rgb,trace=False):
        x=rgb.astype(np.int16)-128; values=[x]; self.last_trace=[]
        for i,layer in enumerate(self.graph['layers']):
            if layer['upsample']==2: x=x.repeat(2,0).repeat(2,1)
            w=self.params[f'w{i}']; acc=convolution(x,w,layer['stride'],layer['dw'])
            affine=acc.astype(np.int64)*self.params[f'm{i}']+self.params[f'b{i}']
            q=round_shift(affine,self.params[f'r{i}'])
            q=q.clip(0 if layer['relu'] else -128,127).astype(np.int16)
            if layer['residual']>=0:
                q=(q+values[layer['residual']]).clip(0,127).astype(np.int16)
            if trace: self.last_trace.append(dict(input=x.copy(),acc=acc,output=q.copy(),layer=layer))
            x=q; values.append(x)
        return (x+128).clip(0,255).astype(np.uint8)
