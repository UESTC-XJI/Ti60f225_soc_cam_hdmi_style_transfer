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
    """Deployment topology.

    head=0 (default): the original graph, 23 layers, unchanged.
    head=1..n: prepend a full-resolution colour head.  The RTL constrains this:
    style_row_core.sv:117 wires the non-depthwise 3x3 input to exactly three
    channels (rgb_terms = 3 taps x 9 positions), so a full-resolution 3x3 can
    only be Conv3x3(3 -> co).  Any deeper 3x3 must be depthwise.  The head is
    therefore  Conv3x3(3->8)  followed by  n  MobileNet blocks
    [DWConv3x3 + Conv1x1].  Each block adds 2 to the receptive field:
        n=1 -> RF 5,  n=2 -> RF 7 (matches the official 7x7 head).
    """
    def __init__(self, channels=24, blocks=4, head=0, head_channels=8):
        super().__init__()
        self.channels, self.blocks, self.head = channels, blocks, head
        self.head_channels = head_channels
        # full-resolution head: 3 -> head_channels, then n MobileNet blocks
        self.pre = nn.ModuleList()
        if head > 0:
            self.pre.append(Layer(3, head_channels, 3, 1))       # Conv3x3 3->hc
            self.pre[0].in_scale = 1/128
            for _ in range(head):
                self.pre.append(Layer(head_channels, head_channels, 3, 1, dw=True))
                self.pre.append(Layer(head_channels, head_channels, 1, 1))
        enc_in = head_channels if head > 0 else 3
        # RTL constraint (style_row_core.sv:117): a NON-depthwise 3x3 is wired to
        # exactly three input channels, so ci=8 forces depthwise here.
        self.enc = nn.ModuleList([Layer(enc_in, 8, 3, 2, dw=(head > 0)),
                                  Layer(8, 8, 3, 2, True),
                                  Layer(8, channels)])
        self.enc[0].in_scale = 1/128
        self.res = nn.ModuleList([nn.ModuleList([Layer(channels,channels,3,dw=True),
            Layer(channels,channels), Layer(channels,channels,3,dw=True),
            Layer(channels,channels,relu=False)]) for _ in range(blocks)])
        self.dec = nn.ModuleList([Layer(channels,channels,3,dw=True), Layer(channels,8),
                                 Layer(8,8,3,dw=True), Layer(8,3,relu=False,bn=False)])
        self.qat = False
        self.residual_scale=1/16

    def all_layers(self):
        return list(self.pre) + list(self.enc) \
            + [m for b in self.res for m in b] + list(self.dec)

    def set_scales(self,scales):
        layers=self.all_layers()
        previous=1/128
        for layer,scale in zip(layers,scales):
            layer.in_scale=previous;layer.out_scale=scale;previous=scale
        # residual_scale must follow enc.2, i.e. shift by the number of
        # full-resolution head layers (2 per block plus the first conv).
        head_layers = 1 + 2 * self.head if self.head > 0 else 0
        self.residual_scale=scales[head_layers + 2]

    def set_qat(self, enabled):
        self.qat = enabled
        for m in self.modules():
            if isinstance(m, Layer): m.qat = enabled

    def forward(self, x):
        x = (x * 255 - 128)/128
        for layer in self.pre: x = layer(x)
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
