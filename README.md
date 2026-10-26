# LUT Cam（CameraLUT）

给 iPhone 14 Pro 用的**实时 LUT 相机**：取景框里直接看到成片效果，拍照套 LUT 直出，支持实况照片。

> ⚠️ **关于 Apple Log**：14 Pro **做不到**官方 Apple Log。Apple 官方文档明确写「Apple Log 是 iPhone 15 Pro 系列及后续 Pro 机型可用的选项」，而且 `isLogVideoSupported` 在 A16 上返回 false，第三方 App 无法开启。这是硬件 + 系统白名单限制，不是权限问题。
> 想要类似的宽容度，后续可以加「仿 Log 曲线」（ProRAW 或高比特素材 + log 映射），这条路是通的。

---

## 一、v1 做了什么

| 功能 | 状态 |
|---|---|
| 实时 LUT 预览（所见即所得） | ✅ |
| 导入 `.cube` LUT（3D LUT） | ✅ |
| 拍照套 LUT 直出 | ✅ |
| 实况照片拍摄 | ✅ |
| 实况视频逐帧套 LUT（可切换） | ✅ |
| LUT 开关（一键回原始色彩） | ✅ |

### 实况照片的两种 LUT 模式

在设置里随时切换：

| 模式 | 效果 | 代价 |
|---|---|---|
| **只套静态帧** | 保存快 | 实况播放时会有轻微跳色 |
| **视频也逐帧套** | 播放颜色一致 | 保存慢 1–3 秒，发热明显 |

---

## 二、技术实现

```
CameraLUT/
├── Sources/
│   ├── CameraLUTApp.swift
│   ├── Camera/
│   │   ├── CameraSession.swift      # AVCaptureSession、预览帧、拍照
│   │   ├── CameraModel.swift        # 状态编排、拍照→处理→保存
│   │   └── MovieLUTRenderer.swift   # 实况视频逐帧套 LUT
│   ├── Render/
│   │   ├── LUT.swift                # .cube 解析 + CIColorCube
│   │   └── MetalPreview.swift       # CIImage → MTKView
│   ├── Support/
│   │   └── PhotoSaver.swift         # 套 LUT + 存入相册（含实况配对）
│   └── Views/
│       ├── CameraView.swift
│       └── SettingsSheet.swift
└── .github/workflows/build-ipa.yml
```

**管线**：

```
摄像头 → AVCaptureVideoDataOutput (BGRA)
       → CIImage → CIColorCube(LUT) → MTKView 预览

快门 → AVCapturePhotoOutput
     → HEIC/JPEG 数据 → CIImage(applyOrientation) → CIColorCube → JPEG
     → (实况) 视频 → AVAssetReader → 逐帧 CIColorCube → AVAssetWriter
     → PHAssetCreationRequest(.photo + .pairedVideo) → 相册
```

---

## 三、发布步骤

### 1. GitHub 建空仓库 `CameraLUT`（public，不要勾 README）

### 2. 推送

```bash
cd "iOS-CameraLUT"
git init
git add .
git commit -m "init: LUT Cam"
git branch -M main
git remote add origin https://github.com/use121/CameraLUT.git
git push -u origin main
```

### 3. 等 Actions（3–6 分钟）

### 4. 下载安装

固定链接（构建成功后可用）：

```
https://github.com/use121/CameraLUT/releases/latest/download/CameraLUT.ipa
```

手机 Safari 打开 → 下载 → 全能签签名安装。

---

## 四、第一次用要注意

1. **首次启动会要两个权限**：相机、相册（写入）。都要给。
2. **LUT 从哪来**：把 `.cube` 文件存到「文件」App，然后在 App 设置里点「导入 .cube 文件」。
3. **预览有延迟是正常的**：走的是 VideoDataOutput → Metal 渲染，比原生相机预览多几十毫秒。
4. **发热**：逐帧套 LUT 会明显发热，长时间拍注意让手机歇一下。

---

## 五、已知限制 / 下一步

- [ ] 手动控制（快门速度、ISO、白平衡、对焦）还没做
- [ ] 仿 Log 曲线（ProRAW + log 映射）还没做
- [ ] 前摄切换没做
- [ ] LUT 强度（0–100% 混合）没做
- [ ] 逐帧处理只保留视频轨，实况视频本身没有音轨，所以无影响

---

## 六、排错

**预览全黑**
检查相机权限；或者看 Xcode 日志里有没有 `AVCaptureSession` 报错。可能需要在真机上重新授权。

**导入 LUT 后颜色没变**
确认顶部 LUT 开关是开着的（绿点）。另外 `.cube` 必须是 **3D LUT**（含 `LUT_3D_SIZE`），1D LUT 不支持。

**实况照片保存失败**
大概率是相册写入权限没给。到设置里检查。

**逐帧模式很慢**
正常。1.5 秒 1080p 视频约 45 帧，每帧一次 Core Image 渲染。A16 大概 1–3 秒。
