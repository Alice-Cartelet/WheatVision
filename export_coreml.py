"""Export a two-class checkpoint for the bundled iOS decoder."""
import argparse
import os
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, default=root / "models" / "wheat-qh.pt")
    parser.add_argument("--output", type=Path, default=root / "exports" / "WheatLeaf.mlpackage")
    args = parser.parse_args()
    output = args.output.resolve()
    if not args.weights.is_file() or output.exists() or output.suffix != ".mlpackage":
        parser.error("请指定存在的权重和一个未使用的 .mlpackage 输出路径。")

    os.environ["YOLO_AUTOINSTALL"] = "false"
    import setuptools  # Initializes distutils compatibility on Python 3.12.
    from coremltools.proto import Model_pb2
    from ultralytics import YOLO

    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent) as scratch:
        staging = Path(scratch) / "WheatLeaf.pt"
        shutil.copyfile(args.weights, staging)
        model = YOLO(str(staging))
        if model.task != "segment" or model.names != {0: "healthy_leaf", 1: "yellowed_leaf"}:
            parser.error("权重必须是正常/枯黄两类叶片分割模型。")
        exported = model.export(format="coreml", imgsz=512, batch=1, dynamic=False, nms=False, device="cpu")
        # Ultralytics may put the original absolute dataset path in the description.
        spec_file = Path(exported) / "Data" / "com.apple.CoreML" / "model.mlmodel"
        spec = Model_pb2.Model()
        spec.ParseFromString(spec_file.read_bytes())
        spec.description.metadata.shortDescription = "WheatVision two-class wheat leaf instance segmentation"
        spec_file.write_bytes(spec.SerializeToString())
        shutil.move(exported, output)
    print(output)


if __name__ == "__main__":
    main()
