
# 🌾 WheatVision

**Wheat Leaf Segmentation & Yellowing Analysis · 小麦叶片识别与黄化统计**

[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20iOS-blue)](https://github.com/Alice-Cartelet/WheatVision)
[![Model](https://img.shields.io/badge/Model-YOLO11-green)](https://github.com/Alice-Cartelet/WheatVision/tree/main/models)
[![Inference](https://img.shields.io/badge/Inference-ONNX%20Runtime%20%7C%20Core%20ML-orange)](https://github.com/Alice-Cartelet/WheatVision)

WheatVision 是一个面向小麦表型观察的图像分析项目。通过 **YOLO11 实例分割**，识别照片中可见的小麦叶片，将其分类为**正常叶片**与**枯黄叶片**，统计叶片数量和枯黄占比，辅助开展小麦黄化表型记录。

项目提供 **Windows 桌面版**、**iOS 版**以及用于训练、预测和模型导出的 **Python 工具链**。应用端支持本地推理，无需上传待识别图像到服务器。

> [!IMPORTANT]
> 项目仍处于研究辅助和功能演示阶段，不能替代人工表型测定。尤其是叶片遮挡、交叠、复杂背景以及光照变化较大的场景，建议人工核对结果。

## ✨ 功能

| 功能 | Windows 桌面版 | iOS 版 |
| --- | --- | --- |
| 图片识别 | ✅ 单图或批量导入 | ✅ 拍照与相册导入 |
| 实时相机识别 | — | ✅ |
| 正常叶与枯黄叶计数 | ✅ | ✅ |
| 枯黄叶数量占比 | ✅ | ✅ |
| 分割结果可视化 | ✅ 原图/标注图预览 | ✅ 分割标注叠加 |
| 人工修正结果 | — | ✅ 类别更正、补标、删除误检 |
| 保存结果 | ✅ CSV 和标注图片 | ✅ 本机历史记录 |
| 本地推理 | ONNX Runtime | Core ML |

### 统计指标

本项目统计的是**可见叶片的数量占比**，而不是黄化像素面积比例：

\[
\text{枯黄叶占比}=\frac{\text{枯黄叶片数}}{\text{正常叶片数}+\text{枯黄叶片数}}\times100\%
\]

例如：识别到正常叶 6 片、枯黄叶 2 片，则枯黄叶占比为 **25.0%**。没有识别到叶片时，不计算比例。

模型类别：

- `0` — `healthy_leaf`：正常叶片
- `1` — `yellowed_leaf`：可见黄化或干枯的叶片

**注意：**类别基于整片叶的标注，不意味着模型自动测量叶面黄化面积，也不意味着软件按照固定的叶面积百分比阈值判定。

## 📱 iOS 版

基于 **SwiftUI、AVFoundation 和 Core ML**，支持：

- 相机实时识别、拍照和相册导入；
- 显示正常叶、枯黄叶和枯黄占比；
- 对待复核候选叶片作提示，待复核结果暂不计入占比；
- 在照片分析页更正类别、删除误检或手动补标；
- 将标注图和结果保存至本机历史，支持查看和删除。

### 运行

1. 在 Mac 上安装 Xcode。
2. 打开 [`WV for iOS17+/WPD.xcodeproj`](WV%20for%20iOS17%2B/WPD.xcodeproj)。
3. 选择 `WPD` Scheme，使用 **iOS 17.2 或更新版本**的 iPhone 或模拟器。
4. 真机运行时，在 **Signing & Capabilities** 中选择开发团队，并设置可用的 Bundle Identifier。
5. 编译运行。模拟器没有后置摄像头，可通过相册导入图片测试。

项目已内置 `WheatLeaf.mlpackage`，App 识别无需联网。内置模型输入为 **512 × 512**，来源和输出张量约定详见 [`model-contract.json`](WV%20for%20iOS17%2B/ModelExport/model-contract.json)。

更多说明见 [iOS 子项目 README](WV%20for%20iOS17%2B/README.md)。

## 🖥️ Windows 桌面版

使用 **C++17 + Qt 6 Widgets + ONNX Runtime** 开发，面向批量实验图片的本地分析。

功能包括拖放或导入图片/文件夹、递归发现图片、设置置信度和模型路径、批量分析进度展示、原图和标注图切换、整批统计，以及导出逐图 CSV 汇总。

支持扩展名：`jpg`、`jpeg`、`png`、`bmp`、`tif`、`tiff`、`webp`。

### 编译与运行

Windows 版目前提供源代码，编译环境要求：

- Windows x64；
- **CMake 3.21+**；
- **Qt 6.5+（Widgets）**；
- 支持 C++17 的编译器，例如 Visual Studio 2022 MSVC x64；
- ONNX Runtime C++ 依赖（仓库 `WV for Windows/.cpp-deps/ort` 已包含所需头文件和 Windows DLL）。

以 Visual Studio 2022 为例，在 PowerShell 中运行：

```powershell
git clone https://github.com/Alice-Cartelet/WheatVision.git
cd WheatVision

cmake -S "WV for Windows" -B "build/windows" -G "Visual Studio 17 2022" -A x64 -DCMAKE_PREFIX_PATH="C:/Qt/6.8.3/msvc2022_64"
cmake --build "build/windows" --config Release
```

将示例中的 `CMAKE_PREFIX_PATH` 替换为实际的 Qt 安装目录，确保 Qt 与所用编译器一致。成功构建后，可执行程序通常位于：

```text
build/windows/Release/WheatVision.exe
```

CMake 会将模型 `wheat-qh.onnx` 和 `onnxruntime.dll` 复制到程序目录。**若要在其他 Windows 电脑上分发运行**，还需通过 Qt 的 `windeployqt` 部署 Qt 依赖库，不是仅复制 `.exe` 即可。

### 命令行批量分析

```powershell
.\build\windows\Release\WheatVision.exe --batch "samples\batch-test" --output "results" --confidence 0.25
```

还可通过 `--model` 指定兼容的两类 YOLO11 分割 ONNX 模型。上述 exe 路径适用于示例的 Visual Studio Release 构建；其他生成器输出位置可能不同。

每次分析生成独立的结果目录：

```text
results/
└── wheat-YYYYMMDD-HHmmss-XXXXXX/
    ├── 识别汇总.csv
    └── 标注图/
        ├── 00001_xxx.jpg
        └── ...
```

`识别汇总.csv` 包含原图路径、处理状态、正常叶数、枯黄叶数、总叶数、枯黄占比、标注图路径和错误信息。可使用 [`samples/batch-test`](samples/batch-test) 中的合成图片测试批量分析流程。

## 🧠 模型训练与 Python 推理

Python 脚本位于 [`models/`](models)，使用 **Ultralytics YOLO11 实例分割**，包含基础训练、强化训练、整株训练、模型评估和 Core ML 导出工具。

### 准备环境

推荐 Python 3.12：

```bash
python -m venv .venv
# macOS / Linux:
source .venv/bin/activate
# Windows PowerShell:
# .\.venv\Scripts\Activate.ps1

python -m pip install -r models/requirements.txt
```

### 直接预测图片

仓库提供 Python 推理权重 `models/wheat-qh.pt`，在**仓库根目录**执行：

```bash
python models/predict_wheat.py samples/wheat_generated_C.png --weights models/wheat-qh.pt
```

可使用 `--conf` 调整置信度，默认值为 `0.25`。程序在终端输出正常叶数、枯黄叶数和枯黄比例，标注图默认保存至 `models/runs/wheat-qh/predictions/`。

### 数据与训练

| 目录 | 用途 |
| --- | --- |
| [`models/demo-dataset`](models/demo-dataset) | 基础单叶数据与逐叶分割标注 |
| [`models/qh-dataset`](models/qh-dataset) | 基础数据的补充训练素材 |
| [`models/whole-wheat-dataset`](models/whole-wheat-dataset) | 合成整株小麦苗及实例分割标注 |
| [`models/yellow-wheat-dataset`](models/yellow-wheat-dataset) | 黄尖、黄斑等情形的合成补充数据 |
| [`samples/batch-test`](samples/batch-test) | 批量导入、预览和导出的测试图片 |

基础本地数据共涉及 **40 张图片**，其中 33 张真实照片来自 [Kaggle Wheat Leaf dataset](https://www.kaggle.com/datasets/olyadgetch/wheat-leaf-dataset)。真实照片未随 Git 仓库再分发；仓库保留相应标注和来源清单，以及 7 张合成图。获得原始数据集 ZIP 后，可恢复所需真实图片：

```bash
python models/restore_training_images.py "/path/to/wheat-leaf-dataset.zip"
```

基础与强化训练：

```bash
python models/train_wheat.py
python models/qh.py
```

整株训练路线：

```bash
python models/train_whole_wheat.py
python models/strengthen_whole_wheat.py
python models/train_yellow_wheat.py --prepare-only
```

`--prepare-only` 只检查并生成黄化强化训练清单。真正运行 `train_yellow_wheat.py` 训练之前，还需要按脚本要求准备 `models/runs/wheat-whole-refined-512/weights/best-count.pt`；首次克隆仓库后**不能假定该文件存在**。

整株数据和黄化补充数据共 **34 张合成图**。可以用以下命令在留出图上评估：

```bash
python models/evaluate_whole_wheat.py "模型权重路径" --mask-dedup
```

> 首次执行基础训练可能需要联网下载通用 YOLO11 预训练权重。训练脚本默认在 CPU 上运行，训练数据规模较小；演示结果不能直接代表实际田间识别精度。

### 导出 iOS Core ML 模型

在 macOS 上运行：

```bash
python -m pip install -r models/requirements-export.txt
python models/export_coreml.py --weights "models/runs/wheat-yellow/weights/best.pt"
```

默认生成 `models/exports/WheatLeaf.mlpackage`。在替换 iOS 工程中同名模型之前，请检查导出结果与 App 解码器的输入输出约定是否一致。现有约定记录在 [`WV for iOS17+/ModelExport/model-contract.json`](WV%20for%20iOS17%2B/ModelExport/model-contract.json)。

## 📁 目录结构

```text
WheatVision/
├── README.md
├── WV for Windows/            # C++ / Qt Windows 应用
│   ├── src/
│   ├── models/                # ONNX 模型文件
│   ├── .cpp-deps/ort/         # ONNX Runtime 依赖
│   └── CMakeLists.txt
├── WV for iOS17+/             # SwiftUI / Core ML iPhone 应用
│   ├── WPD.xcodeproj
│   ├── WPD/
│   ├── WPDTests/
│   └── ModelExport/
├── models/                    # Python 训练、预测、导出与数据
│   ├── demo-dataset/
│   ├── qh-dataset/
│   ├── whole-wheat-dataset/
│   ├── yellow-wheat-dataset/
│   ├── wheat-qh.pt
│   └── *.py
└── samples/                   # 演示及测试素材
    └── batch-test/
```

## 🔬 局限性与科研使用建议

1. **指标范围：**本项目输出的是“可见枯黄叶片数量比例”，不是叶面积黄化率、植株存活率或综合耐盐碱指数。
2. **遮挡与误检：**细长叶片相交、叶片重叠、复杂背景、反光和阴影均可能造成漏检、误检及重复计数。
3. **数据限制：**整株数据以合成图为主；正式评估需使用独立实拍图像及人工标注进行验证。
4. **人工复核：**iOS 版支持修正照片识别结果；Windows 导出的批量统计建议用于科研前逐图或抽样核对。
5. **采集一致性：**比较不同品系、处理或时间点时，建议统一拍摄距离、角度、光照、生长时期和黄化判定标准。

## 📜 数据来源与第三方许可

- 基础数据中的真实图片来自 [Wheat Leaf dataset（Kaggle）](https://www.kaggle.com/datasets/olyadgetch/wheat-leaf-dataset)，原始照片未在本仓库重新发布。使用或再分发前请确认其授权与署名要求。
- 合成图的生成提示词、来源和标注清单保存在各数据目录中。
- YOLO11 模型与训练工具涉及 Ultralytics：参见 [`models/licenses/Ultralytics-AGPL-3.0.txt`](models/licenses/Ultralytics-AGPL-3.0.txt) 和 [官方许可说明](https://www.ultralytics.com/license)。
- Windows 版使用 Qt 与 ONNX Runtime，构建和分发时还须遵守相应许可。
- **当前仓库未设置统一的根目录 `LICENSE` 文件**。第三方许可证文本不表示整个 WheatVision 项目已经以相同条款开源授权。

---

**Maintainer:** [@Alice-Cartelet](https://github.com/Alice-Cartelet) · [GitHub Repository](https://github.com/Alice-Cartelet/WheatVision)

*WheatVision — 让小麦叶片表型观察更加直观、可复核。*
