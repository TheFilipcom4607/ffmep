import torch, torch.nn.functional as F

def deform_forward(self, x):
    """DeformableConv2d.forward using grid_sample, which Core ML supports (stride 1, dilation 1)."""
    N, C, H, W = x.shape
    weight = self.regular_conv.weight
    kh, kw = weight.shape[2:]
    K = kh * kw
    pad = self.padding if isinstance(self.padding, int) else self.padding[0]
    offset = self.offset_conv(x).view(N, K, 2, H, W)
    modulator = 2. * torch.sigmoid(self.modulator_conv(x))            # N,K,H,W
    ys = torch.arange(H, dtype=x.dtype).view(1, 1, H, 1)
    xs = torch.arange(W, dtype=x.dtype).view(1, 1, 1, W)
    ky = (torch.arange(kh, dtype=x.dtype) - pad).repeat_interleave(kw).view(1, K, 1, 1)
    kx = (torch.arange(kw, dtype=x.dtype) - pad).repeat(kh).view(1, K, 1, 1)
    py = ys + ky + offset[:, :, 0]                                    # N,K,H,W
    px = xs + kx + offset[:, :, 1]
    gy = py * (2.0 / max(H - 1, 1)) - 1.0
    gx = px * (2.0 / max(W - 1, 1)) - 1.0
    grid = torch.stack((gx, gy), dim=-1).reshape(N, K * H, W, 2)
    sampled = F.grid_sample(x, grid, mode='bilinear', padding_mode='zeros', align_corners=True)  # N,C,K*H,W
    sampled = sampled.view(N, C, K, H, W) * modulator.unsqueeze(1)
    sampled = sampled.permute(0, 2, 1, 3, 4).reshape(N, K * C, H, W)  # kernel point, then channel
    w = weight.permute(0, 2, 3, 1).reshape(weight.shape[0], K * C, 1, 1)
    return F.conv2d(sampled, w, self.regular_conv.bias)
