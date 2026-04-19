
import torch
import torch.nn as nn
import torch.nn.functional as F

def systolic_gemm_torch(A, B, P=16, Q=16, Kb=16):
    """
    A: (M x K) torch tensor
    B: (K x N) torch tensor
    Returns: (M x N)
    """
    A_np = A.detach().cpu().numpy()
    B_np = B.detach().cpu().numpy()

    C_np = systolic_gemm(A_np, B_np, P=P, Q=Q, Kb=Kb)

    return torch.from_numpy(C_np).to(A.device)

class SystolicConv2d(nn.Module):
    def __init__(self, in_channels, out_channels, weights, biases,
                 kernel_size=3, stride=1, padding=1,
                 bias=True, P=16, Q=16, Kb=21):
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.stride = stride
        self.padding = padding
        self.kernel_size = kernel_size
        self.P = P
        self.Q = Q
        self.Kb = Kb

        # Same parameters as nn.Conv2d
        self.weight = weights
        self.bias = biases if bias else None

    def forward(self, x):
        N, C, H, W = x.shape
        Kh = Kw = self.kernel_size

        # ---- 1. im2col using PyTorch unfold ----
        cols = F.unfold(
            x,
            kernel_size=self.kernel_size,
            stride=self.stride,
            padding=self.padding
        )  # shape: (N, C*Kh*Kw, H_out*W_out)

        # ---- 2. Reshape weights to (out_channels, K) ----
        W_mat = self.weight.reshape(self.weight.size(0), -1)  # (O, K)

        # ---- 3. For each batch item, run systolic GEMM ----
        outputs = []
        for b in range(N):
            print(W_mat.shape, cols[b].shape)
            C_out = systolic_gemm_torch(
                W_mat,                      # (O x K)
                cols[b],                    # (K x N_patches)
                P=self.P, Q=self.Q, Kb=self.Kb
            )  # → (O x N_patches)

            if self.bias is not None:
                C_out += self.bias[:, None]

            outputs.append(C_out)

        # ---- 4. Stack and fold back to image ----
        out = torch.stack(outputs, dim=0)  # (N, O, N_patches)
        H_out = (H + 2*self.padding - Kh) // self.stride + 1
        W_out = (W + 2*self.padding - Kw) // self.stride + 1

        out = out.view(N, -1, H_out, W_out).to(x.device)
        return out
# ===== Function to recursively replace Conv2d =====
def replace_conv_with_custom(module):
    for name, child in module.named_children():
        if isinstance(child, nn.Conv2d):
            # Replace with custom conv preserving parameters
            new_conv = SystolicConv2d(
                in_channels=child.in_channels,
                out_channels=child.out_channels,
                weights=child.weight.data.clone(),  # Correct position
                biases=child.bias.data.clone() if child.bias is not None else None,  # Correct position
                kernel_size=child.kernel_size,  # Correct position
                stride=child.stride,
                padding=child.padding,
                bias=(child.bias is not None)
            )
            setattr(module, name, new_conv)
        else:
            replace_conv_with_custom(child)

import torch
import torch.nn as nn
import torch.optim as optim
import torchvision
from torch.utils.data import DataLoader
from torchvision import models, transforms
from datasets import load_dataset
from PIL import Image
import numpy as np

# ----------------------------
# 1. Device configuration
# ----------------------------
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"Using device: {device}")

# ----------------------------
# 2. Load ImageNet from Hugging Face
# ----------------------------
# This requires authentication for ImageNet-1k
# Make sure you have accepted the dataset license on HF
dataset = load_dataset("timm/mini-imagenet", split={"train": "train", "val": "validation"})

# ----------------------------
# 3. Define preprocessing transforms
# ----------------------------
transform = transforms.Compose([
    transforms.Resize(256),
    transforms.CenterCrop(224),
    transforms.ToTensor(),
    transforms.Normalize(
        mean=[0.485, 0.456, 0.406],  # ImageNet mean
        std=[0.229, 0.224, 0.225]    # ImageNet std
    )
])

# ----------------------------
# 4. Transform wrapper for HF dataset
# ----------------------------
def transform_batch(example):
    example["pixel_values"] = transform(example["image"].convert("RGB"))
    return example

dataset["train"] = dataset["train"].map(transform_batch)
dataset["val"] = dataset["val"].map(transform_batch)

# Remove original image column to avoid memory overhead
dataset["train"].set_format(type="torch", columns=["pixel_values", "label"])
dataset["val"].set_format(type="torch", columns=["pixel_values", "label"])

# ----------------------------
# 5. DataLoaders
# ----------------------------
train_loader = DataLoader(dataset["train"], batch_size=64, shuffle=True, num_workers=4, pin_memory=True)
val_loader = DataLoader(dataset["val"], batch_size=64, shuffle=False, num_workers=4, pin_memory=True)

# ----------------------------
# 6. Model setup
# ----------------------------
model = models.resnet18(weights=models.ResNet18_Weights.IMAGENET1K_V1)  # Pretrained
# If training from scratch: models.resnet18(weights=None)
replace_conv_with_custom(model)
# Adjust final layer for ImageNet-1k (1000 classes)
model.fc = nn.Linear(model.fc.in_features, 1000)
model = model.to(device)

# ----------------------------
# 7. Loss & Optimizer
# ----------------------------
criterion = nn.CrossEntropyLoss()
optimizer = optim.Adam(model.parameters(), lr=1e-4)

# ----------------------------
# 8. Training & Validation Loop
# ----------------------------
def train_one_epoch(epoch):
    model.train()
    running_loss, correct, total = 0.0, 0, 0

    for batch in train_loader:
        inputs, labels = batch["pixel_values"].to(device), batch["label"].to(device)

        optimizer.zero_grad()
        outputs = model(inputs)
        loss = criterion(outputs, labels)
        loss.backward()
        optimizer.step()

        running_loss += loss.item() * inputs.size(0)
        _, predicted = outputs.max(1)
        total += labels.size(0)
        correct += predicted.eq(labels).sum().item()

    epoch_loss = running_loss / total
    epoch_acc = 100.0 * correct / total
    print(f"Epoch {epoch} | Train Loss: {epoch_loss:.4f} | Train Acc: {epoch_acc:.2f}%")

def validate(epoch):
    model.eval()
    running_loss, correct, total = 0.0, 0, 0

    with torch.no_grad():
        for batch in val_loader:
            inputs, labels = batch["pixel_values"].to(device), batch["label"].to(device)
            outputs = model(inputs)
            loss = criterion(outputs, labels)

            running_loss += loss.item() * inputs.size(0)
            _, predicted = outputs.max(1)
            total += labels.size(0)
            correct += predicted.eq(labels).sum().item()

    epoch_loss = running_loss / total
    epoch_acc = 100.0 * correct / total
    print(f"Epoch {epoch} | Val Loss: {epoch_loss:.4f} | Val Acc: {epoch_acc:.2f}%")

# ----------------------------
# 9. Run training
# ----------------------------
EPOCHS = 5
for epoch in range(1, EPOCHS + 1):
    train_one_epoch(epoch)
    validate(epoch)

# ----------------------------
# 10. Save model
# ----------------------------
torch.save(model.state_dict(), "resnet18_imagenet_systolic.pth")
print("Model saved to resnet18_imagenet_systolic.pth")
