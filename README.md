# WheatVision

iOS 演示项目。用相机或照片识别可见小麦叶片，统计正常叶、枯黄叶和枯黄数量占比。可复核结果并保存到本机历史。

## 运行 App

打开 `WPD/WPD.xcodeproj`，选择 `WPD` scheme 和 iOS 17.2 或更新的 iPhone 或模拟器。运行真机前，在 Signing & Capabilities 选自己的团队，并设置该团队可用的 Bundle Identifier。Core ML 权重已随工程提供，App 识别无需联网。

## 训练数据

完整本地数据有 40 张图片及逐叶 YOLO 实例分割标注。类别 `0` 为正常叶，`1` 为枯黄叶。基础数据在 `demo-dataset`，新增的 4 张强化训练图在 `qh-dataset`。两个数据目录中的生成提示词记录了合成图的来源。

Git 中包含 7 张合成图、全部标签和来源清单。33 张真实照片来自 [Wheat Leaf dataset](https://www.kaggle.com/datasets/olyadgetch/wheat-leaf-dataset)，来源注明图片版权归原作者。真实照片在本地目录保留，并由 `.gitignore` 排除。克隆后可从来源下载原始 ZIP，在仓库根目录运行：

```bash
python restore_training_images.py "/path/to/wheat-leaf-dataset.zip"
```

脚本按清单恢复对应图片，并去掉拍摄元数据。验证集 10 张真实照片，独立的演示测试图 1 张合成图。真实照片以单叶近照为主，演示结果不能代表遮挡条件下的统计准确率。

## 训练和预测

建议 Python 3.12，在虚拟环境中执行：

```bash
python -m pip install -r requirements.txt
python predict_wheat.py
python train_wheat.py
python qh.py
```

Intel Mac 如遇 OpenCV 源码编译，使用 `python -m pip install --only-binary=:all: -c constraints-macos-intel.txt -r requirements.txt`。训练脚本默认用 CPU。首次基础训练需要下载 Ultralytics 预训练权重。预测脚本默认使用清理过本机元数据的强化版权重，结果写入 `runs/`。也可用 `python predict_wheat.py "/path/to/photo.jpg" --weights models/wheat-demo.pt` 预测任意照片。

## 整株训练与 App 模型

`whole-wheat-dataset` 和 `yellow-wheat-dataset` 提供共 34 张合成整株图及逐叶标注。用 `python train_whole_wheat.py` 开始整株训练，`python strengthen_whole_wheat.py` 可在首轮最佳权重上继续训练。`python train_yellow_wheat.py --prepare-only` 检查图片和标注并生成数据清单。执行黄化强化训练还需先在 `runs/wheat-whole-refined-512/weights/best-count.pt` 放入选定的两类分割权重。可用 `python evaluate_whole_wheat.py <权重路径> --mask-dedup` 在整株留出图上评估。

App 内置的 Core ML 模型来自黄化强化训练。重新导出时，在 Mac 安装 `requirements-export.txt`，运行 `python export_coreml.py --weights runs/wheat-yellow/weights/best.pt`。检查导出结果后，再用新的 `WheatLeaf.mlpackage` 替换 App 内的同名模型。内置模型来源和输出约定见 `WPD/ModelExport/model-contract.json`。

## 第三方许可

训练和模型基于 Ultralytics YOLO11。上游许可证文本见 `licenses/Ultralytics-AGPL-3.0.txt`，许可选择见 [Ultralytics 许可说明](https://www.ultralytics.com/license)。在公开分发带权重的工程前，请确认所采用的上游许可及相应的项目许可。上述第三方文本仅记录上游条款。
