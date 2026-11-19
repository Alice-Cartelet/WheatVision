from pathlib import Path

from ultralytics import YOLO

from restore_training_images import require_demo_images


def main():
    project = Path(__file__).resolve().parent
    dataset = project / "demo-dataset" / "data.yaml"
    if not dataset.is_file():
        raise FileNotFoundError(f"找不到数据配置：{dataset}")

    require_demo_images(dataset.parent)
    local_weights = project / "weights" / "yolo11n-seg.pt"
    model = YOLO(str(local_weights) if local_weights.is_file() else "yolo11n-seg.pt")
    model.train(
        data=str(dataset),
        epochs=50,
        imgsz=512,
        batch=4,
        device="cpu",
        workers=0,
        project=str(project / "runs"),
        name="wheat-demo",
    )
    print(f"最佳权重：{model.trainer.best}")


if __name__ == "__main__":
    main()
