from pathlib import Path

from ultralytics import YOLO


def main():
    project = Path(__file__).resolve().parent
    checkpoint = project / "runs" / "wheat-whole" / "weights" / "best.pt"
    dataset = project / "whole-wheat-dataset" / "data.yaml"
    for path in (checkpoint, dataset):
        if not path.is_file():
            raise FileNotFoundError(path)

    model = YOLO(str(checkpoint))
    model.train(
        data=str(dataset), epochs=15, imgsz=512, batch=4, workers=0, device="cpu",
        project=str(project / "runs"), name="wheat-whole-refined-512",
        optimizer="AdamW", lr0=0.00015, warmup_epochs=0.5, patience=0, freeze=10, save_period=3,
        mask_ratio=2, overlap_mask=True, cls=0.5,
        mosaic=0.0, degrees=8.0, scale=0.18, translate=0.08,
        hsv_h=0.0, hsv_s=0.08, hsv_v=0.12,
    )
    print(f"最佳权重：{model.trainer.best}", flush=True)


if __name__ == "__main__":
    main()
