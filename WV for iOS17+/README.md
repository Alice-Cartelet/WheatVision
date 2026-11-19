# WheatVision / WPD

离线统计可见小麦叶片数和枯黄比例。打开 `WPD.xcodeproj`，选择 WPD scheme。最低 iOS 17.2。真机需在 Xcode 选择签名团队。

- **识别**支持实时相机、拍照和相册导入。粉色候选需人工复核，暂不计入占比。照片页可更正类别、删除误检或补标，然后点「保存」。
- **历史**按时间查看保存的标注图和计数，可滑动删除。原有历史可读取。

实时预览由 AVFoundation 直接显示。单独的识别队列一次处理一帧，正常模式间隔至少 120 ms，低电量或高温时至少 400 ms。实际识别刷新率与预览帧率需在真机上测量。

相机、拍照和相册使用内置的 `WPD/WheatLeaf.mlpackage`。该模型来自项目根目录的 `runs/wheat-yellow/weights/best.pt`，输入 512×512。转换来源和张量信息见 `ModelExport/model-contract.json`。模型用于演示，类别和遮挡场景的计数仍需人工核对。

模拟器无后置摄像头，可用相册验证照片识别。命令行可使用：

```sh
DEVELOPER_DIR=/Applications/Xcode-15.app/Contents/Developer \
  xcodebuild -project WPD.xcodeproj -scheme WPD -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test
```
