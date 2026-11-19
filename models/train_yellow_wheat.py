import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE = ROOT / "whole-wheat-dataset"
EXTRA = ROOT / "yellow-wheat-dataset"
CLASSES = {0: "healthy_leaf", 1: "yellowed_leaf"}
CHECKPOINT = ROOT / "runs" / "wheat-whole-refined-512" / "weights" / "best-count.pt"


def labeled_images(dataset, split):
    image_dir = dataset / "images" / split
    images = sorted(p for p in image_dir.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg"})
    if not images:
        raise ValueError(f"没有找到图片：{image_dir}")
    for image in images:
        label = dataset / "labels" / split / (image.stem + ".txt")
        if not label.is_file() or not label.read_text(encoding="utf-8").strip():
            raise ValueError(f"缺少叶片标注：{label}")
    return images


def prepare():
    splits = {
        "train": labeled_images(BASE, "train") + labeled_images(EXTRA, "train"),
        "val": labeled_images(BASE, "val") + labeled_images(EXTRA, "val"),
        "test": labeled_images(BASE, "test"),
    }
    seen = {}
    config = {"path": str(EXTRA), "names": CLASSES}
    for split, images in splits.items():
        for image in images:
            digest = hashlib.sha256(image.read_bytes()).hexdigest()
            if digest in seen:
                raise ValueError(f"重复图片：{image} 与 {seen[digest]}")
            seen[digest] = image
        image_list = EXTRA / f"{split}.txt"
        image_list.write_text("".join(f"{p}\n" for p in images), encoding="utf-8")
        config[split] = image_list.name
        print(f"{split}: {len(images)} 张整株图")
    dataset = EXTRA / "data.yaml"
    dataset.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return dataset


def main():
    parser = argparse.ArgumentParser(description="强化整株模型对黄尖、黄斑和嫩绿叶的区分")
    parser.add_argument("--epochs", type=int, default=25)
    parser.add_argument("--prepare-only", action="store_true", help="检查数据并生成清单")
    args = parser.parse_args()
    if args.epochs < 1:
        parser.error("--epochs 必须至少为 1")

    dataset = prepare()
    if args.prepare_only:
        return
    if not CHECKPOINT.is_file():
        raise FileNotFoundError(f"找不到当前整株权重：{CHECKPOINT}")

    from ultralytics import YOLO

    model = YOLO(str(CHECKPOINT))
    if model.task != "segment" or model.names != CLASSES:
        raise ValueError("现有权重与正常/黄化两类分割不匹配")
    model.train(
        data=str(dataset), epochs=args.epochs, imgsz=512, batch=4, workers=0,
        device="cpu", project=str(ROOT / "runs"), name="wheat-yellow",
        optimizer="AdamW", lr0=0.00015, warmup_epochs=0.5, freeze=10,
        mask_ratio=2, overlap_mask=True, cls=0.65, save_period=5, patience=12,
        mosaic=0.0, degrees=7.0, scale=0.12, translate=0.06,
        hsv_h=0.0, hsv_s=0.03, hsv_v=0.08,
    )
    print(f"最佳权重：{model.trainer.best}")
    print(f'验证留出整株图：python evaluate_whole_wheat.py "{model.trainer.best}" --mask-dedup')


if __name__ == "__main__":
    main()
