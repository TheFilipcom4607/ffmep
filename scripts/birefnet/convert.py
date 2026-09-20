# Converts BiRefNet (MIT, https://huggingface.co/ZhengPeng7/BiRefNet) to Core ML.
# Usage (Python 3.12):
#   uv venv -p 3.12 .venv && uv pip install -p .venv/bin/python torch==2.7.0 torchvision coremltools==9.0 transformers timm kornia einops huggingface_hub
#   .venv/bin/python -c "from huggingface_hub import snapshot_download; snapshot_download('ZhengPeng7/BiRefNet', local_dir='BiRefNet')"
#   .venv/bin/python scripts/birefnet/convert.py   # writes BiRefNet.mlpackage (~446 MB)
# Runs on CPU or GPU only: the Neural Engine fails to build a plan for it, so load with .cpuAndGPU.
import sys, time, torch
import coremltools as ct
from transformers import AutoModelForImageSegmentation
sys.path.insert(0, __import__("os").path.dirname(__file__))
from deform import deform_forward

m = AutoModelForImageSegmentation.from_pretrained('BiRefNet', trust_remote_code=True, dtype=torch.float32).eval()
for mod in m.modules():
    if type(mod).__name__ == 'DeformableConv2d':
        type(mod).forward = deform_forward
        break

# Swin's window_reverse computes the batch size with int(tensor), which Core ML can't trace; batch is always 1.
def window_reverse(windows, window_size, H, W):
    x = windows.view(1, H // window_size, W // window_size, window_size, window_size, -1)
    return x.permute(0, 1, 3, 2, 4, 5).contiguous().view(1, H, W, -1)
birefnet_module = sys.modules[type(m).__module__]
birefnet_module.window_reverse = window_reverse

# BasicLayer builds its shifted-window mask from tensor math on H/W. The input size is fixed, so
# build it with plain ints and let tracing bake it in as a constant.
import math
def basic_layer_forward(self, x, H, W):
    ws, ss = self.window_size, self.shift_size
    H, W = int(H), int(W)
    Hp, Wp = math.ceil(H / ws) * ws, math.ceil(W / ws) * ws
    img_mask = torch.zeros((1, Hp, Wp, 1))
    cnt = 0
    for h in (slice(0, -ws), slice(-ws, -ss), slice(-ss, None)):
        for w in (slice(0, -ws), slice(-ws, -ss), slice(-ss, None)):
            img_mask[:, h, w, :] = cnt
            cnt += 1
    mask_windows = img_mask.view(1, Hp // ws, ws, Wp // ws, ws, 1).permute(0, 1, 3, 2, 4, 5).reshape(-1, ws * ws)
    attn_mask = mask_windows.unsqueeze(1) - mask_windows.unsqueeze(2)
    attn_mask = attn_mask.masked_fill(attn_mask != 0, -100.0).masked_fill(attn_mask == 0, 0.0).to(x.dtype).detach()
    for blk in self.blocks:
        blk.H, blk.W = H, W
        x = blk(x, attn_mask)
    if self.downsample is not None:
        return x, H, W, self.downsample(x, H, W), (H + 1) // 2, (W + 1) // 2
    return x, H, W, x, H, W
birefnet_module.BasicLayer.forward = basic_layer_forward

class Wrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer('mean', torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))
    def forward(self, image):  # RGB in 0...1
        return self.net((image - self.mean) / self.std)[-1].sigmoid()

wrapped = Wrapper(m).eval()
example = torch.rand(1, 3, 1024, 1024)
t = time.time()
with torch.no_grad():
    traced = torch.export.export(wrapped, (example,), strict=False).run_decompositions({})
print('traced', round(time.time() - t, 1))
t = time.time()
ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name='image', shape=(1, 3, 1024, 1024), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.ImageType(name='mask', color_layout=ct.colorlayout.GRAYSCALE_FLOAT16)],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
)
ml.short_description = 'BiRefNet (MIT) dichotomous image segmentation, 1024x1024'
ml.save('BiRefNet.mlpackage')
print('converted', round(time.time() - t, 1))
