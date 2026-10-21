"""Deployment topology: explicit BN, zero padding, nearest resize, signed activations."""
import torch
from torch import nn
from torch.nn import functional as F


def fake(x, scale):
    v=(x/scale).clamp(-128,127)
    q=torch.sign(v)*torch.floor(torch.abs(v)+.5)
    return (v+(q-v).detach())*scale


class Layer(nn.Module):
    def __init__(self, ci, co, k=1, stride=1, dw=False, relu=True, bn=True):
        super().__init__()
        self.conv = nn.Conv2d(ci, co, k, stride, k//2, groups=ci if dw else 1, bias=not bn)
        self.bn = nn.BatchNorm2d(co) if bn else nn.Identity()
        self.relu, self.qat = relu, False
        self.in_scale, self.out_scale = 1/16, 1/16 if bn else 1/128

    def forward(self, x):
        w = self.conv.weight
        if self.qat:
            s = w.detach().abs().flatten(1).amax(1).clamp_min(1e-8)/127
            w = fake(w, s[:, None, None, None])
            x = fake(x, self.in_scale)
        y = self.bn(F.conv2d(x, w, self.conv.bias, self.conv.stride,
                            self.conv.padding, groups=self.conv.groups))
        if self.relu:
            y = F.relu(y)
        if self.qat:
            y = fake(y, self.out_scale)
        return y


class Student(nn.Module):
    def __init__(self, channels=24, blocks=4):
        super().__init__()
        self.channels, self.blocks = channels, blocks
        self.enc = nn.ModuleList([Layer(3,8,3,2), Layer(8,8,3,2,True), Layer(8,channels)])
        self.enc[0].in_scale = 1/128
        self.res = nn.ModuleList([nn.ModuleList([Layer(channels,channels,3,dw=True),
            Layer(channels,channels), Layer(channels,channels,3,dw=True),
            Layer(channels,channels,relu=False)]) for _ in range(blocks)])
        self.dec = nn.ModuleList([Layer(channels,channels,3,dw=True), Layer(channels,8),
                                 Layer(8,8,3,dw=True), Layer(8,3,relu=False,bn=False)])
        self.qat = False
        self.residual_scale=1/16

    def set_scales(self,scales):
        layers=list(self.enc)+[m for b in self.res for m in b]+list(self.dec)
        previous=1/128
        for layer,scale in zip(layers,scales):
            layer.in_scale=previous;layer.out_scale=scale;previous=scale
        self.residual_scale=scales[2]

    def set_qat(self, enabled):
        self.qat = enabled
        for m in self.modules():
            if isinstance(m, Layer): m.qat = enabled

    def forward(self, x):
        x = (x * 255 - 128)/128
        for layer in self.enc: x = layer(x)
        for block in self.res:
            skip = x
            for layer in block: x = layer(x)
            x = F.relu(x + skip)
            if self.qat: x = fake(x, self.residual_scale)
        x = F.interpolate(x, scale_factor=2, mode='nearest')
        x = self.dec[1](self.dec[0](x))
        x = F.interpolate(x, scale_factor=2, mode='nearest')
        x = self.dec[3](self.dec[2](x))
        return ((x.clamp(-1,127/128) * 128 + 128)/255).clamp(0,1)


class Teacher(nn.Module):
    def __init__(self):
        super().__init__()
        def conv(ci,co,k=3,s=1):
            return nn.Sequential(nn.Conv2d(ci,co,k,s,k//2), nn.InstanceNorm2d(co,affine=True), nn.ReLU())
        self.enc = nn.Sequential(conv(3,32,9),conv(32,64,s=2),conv(64,128,s=2))
        self.res = nn.ModuleList([nn.Sequential(conv(128,128),nn.Conv2d(128,128,3,padding=1),
                                 nn.InstanceNorm2d(128,affine=True)) for _ in range(4)])
        self.dec = nn.Sequential(nn.Upsample(scale_factor=2,mode='nearest'),conv(128,64),
            nn.Upsample(scale_factor=2,mode='nearest'),conv(64,32),nn.Conv2d(32,3,9,padding=4))

    def forward(self,x):
        y = self.enc(x)
        for r in self.res: y = y+r(y)
        return torch.sigmoid(self.dec(y))
