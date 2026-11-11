import argparse
import json
from pathlib import Path

from restore_training_images import require_demo_images

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


def labeled_images(folder):
    images = sorted(
        path for path in folder.iterdir() if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    )
    if not images:
        raise ValueError(f"没有找到训练图片：{folder}")

    labels = folder.parent.parent / "labels" / folder.name
    for image in images:
        label = labels / f"{image.stem}.txt"
        if not label.is_file() or not label.read_text(encoding="utf-8").strip():
            raise ValueError(f"缺少逐叶标注：{label}")
    return images


def prepare_dataset(project):
    original = project / "demo-dataset"
    supplemental = project / "qh-dataset"
    require_demo_images(original)
    original_train = labeled_images(original / "images" / "train")
    new_train = labeled_images(supplemental / "images" / "train")
    validation = labeled_images(original / "images" / "val")
    test = labeled_images(original / "images" / "test")

    train_list = supplemental / "train.txt"
    train_list.write_text("".join(f"{image}\n" for image in original_train + new_train), encoding="utf-8")

    data_yaml = supplemental / "data.yaml"
    config = {
        "path": str(supplemental),
        "train": train_list.name,
        "val": str(original / "images" / "val"),
        "test": str(original / "images" / "test"),
        "names": {0: "healthy_leaf", 1: "yellowed_leaf"},
    }
    # JSON is valid YAML and avoids adding a configuration dependency.
    data_yaml.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"训练集 {len(original_train)} 张原图 + {len(new_train)} 张补充图，"
        f"验证集 {len(validation)} 张，留出测试图 {len(test)} 张"
    )
    return data_yaml


def main():
    parser = argparse.ArgumentParser(description="用原训练集和新增小麦图片微调已有分割模型")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--prepare-only", action="store_true", help="只生成和检查数据清单")
    args = parser.parse_args()
    if args.epochs < 1:
        parser.error("--epochs 必须至少为 1")

    project = Path(__file__).resolve().parent
    dataset = prepare_dataset(project)
    if args.prepare_only:
        print(f"训练数据配置：{dataset}")
        return

    from ultralytics import YOLO

    checkpoint = project / "runs" / "wheat-demo" / "weights" / "best.pt"
    if not checkpoint.is_file():
        checkpoint = project / "models" / "wheat-demo.pt"
    if not checkpoint.is_file():
        raise FileNotFoundError(f"找不到首轮最佳权重：{checkpoint}")

    model = YOLO(str(checkpoint))
    if model.task != "segment" or model.names != {0: "healthy_leaf", 1: "yellowed_leaf"}:
        raise ValueError("请使用类别顺序正确的小麦两类分割权重")

    model.train(
        data=str(dataset),
        epochs=args.epochs,
        imgsz=512,
        batch=4,
        device="cpu",
        workers=0,
        project=str(project / "runs"),
        name="wheat-qh",
        optimizer="AdamW",
        lr0=0.001,
        patience=12,
        hsv_h=0.0,
        hsv_s=0.08,
        hsv_v=0.12,
        mosaic=0.0,
    )
    print(f"强化训练最佳权重：{model.trainer.best}")


if __name__ == "__main__":
    main()
