from pathlib import Path

from ultralytics import YOLO


def main():
    project = Path(__file__).resolve().parent
    dataset = project / "whole-wheat-dataset" / "data.yaml"
    if not dataset.is_file():
        raise FileNotFoundError(f"找不到整株训练集：{dataset}")
    pretrained = project / "weights" / "yolo11n-seg.pt"
    model = YOLO(str(pretrained) if pretrained.is_file() else "yolo11n-seg.pt")
    model.train(
        data=str(dataset), epochs=80, imgsz=512, batch=4, workers=0, device="cpu",
        project=str(project / "runs"), name="wheat-whole",
        mosaic=0.0, hsv_h=0.0, hsv_s=0.10, hsv_v=0.10, patience=20,
    )
    print(f"最佳权重：{model.trainer.best}")


if __name__ == "__main__":
    main()
