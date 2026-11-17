import argparse
import csv
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO


def suppress_duplicate_masks(result):
    if result.masks is None:
        return result
    masks = result.masks.data.cpu().numpy().astype(bool)
    scores = result.boxes.conf.cpu().numpy()
    areas = masks.sum(axis=(1, 2))
    kept = []
    for i in scores.argsort()[::-1]:
        is_duplicate = False
        for j in kept:
            shared = np.count_nonzero(masks[i] & masks[j])
            union = areas[i] + areas[j] - shared
            if union > 0 and shared / union > 0.60:
                is_duplicate = True
                break
        if not is_duplicate:
            kept.append(int(i))
    return result[kept]


def match_leaves(result, targets):
    height, width = result.orig_shape
    masks = result.masks.data.cpu().numpy().astype(bool) if result.masks is not None else []
    classes = result.boxes.cls.int().tolist()
    pairs = []
    for i, (category, polygon) in enumerate(targets):
        points = np.rint(polygon * [width, height]).astype(np.int32)
        raster = cv2.fillPoly(np.zeros((height, width), np.uint8), [points], 1).astype(bool)
        for j, mask in enumerate(masks):
            iou = np.count_nonzero(raster & mask) / max(1, np.count_nonzero(raster | mask))
            if iou >= 0.35:
                pairs.append((iou, i, j))
    matched_truth, matched_pred = set(), set()
    wrong = 0
    for _, i, j in sorted(pairs, reverse=True):
        if i not in matched_truth and j not in matched_pred:
            matched_truth.add(i)
            matched_pred.add(j)
            wrong += targets[i][0] != classes[j]
    return len(targets) - len(matched_truth), len(classes) - len(matched_pred), wrong


def main():
    parser = argparse.ArgumentParser(description="逐张比较整株小麦的预测计数与人工标注")
    parser.add_argument("weights", type=Path)
    parser.add_argument("--split", choices=["val", "test"], default="test")
    parser.add_argument("--imgsz", type=int, default=512)
    parser.add_argument("--conf", type=float, default=0.25)
    parser.add_argument("--mask-dedup", action="store_true", help="同 App 一样，按掩膜重叠去重")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent / "whole-wheat-dataset"
    model = YOLO(str(args.weights))
    if model.names != {0: "healthy_leaf", 1: "yellowed_leaf"}:
        parser.error("请选择两类小麦分割权重。")
    images = sorted((root / "images" / args.split).glob("*.png"))
    out = args.weights.resolve().parent.parent / f"counts-{args.split}-{args.imgsz}-{args.conf:g}"
    if args.mask_dedup:
        out = out.with_name(out.name + "-dedup")
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for image in images:
        label = root / "labels" / args.split / (image.stem + ".txt")
        targets = []
        for line in label.read_text().splitlines():
            category, *coordinates = line.split()
            targets.append((int(category), np.array(coordinates, dtype=float).reshape(-1, 2)))
        result = model.predict(
            str(image), imgsz=args.imgsz, device="cpu", conf=args.conf, retina_masks=True, verbose=False
        )[0]
        if args.mask_dedup:
            result = suppress_duplicate_masks(result)
        true_total = len(targets)
        true_yellowed = sum(category == 1 for category, _ in targets)
        predicted = result.boxes.cls.int().tolist()
        total = len(predicted)
        yellowed = predicted.count(1)
        missed, extra, wrong = match_leaves(result, targets)
        rows.append({
            "image": image.name, "true_total": true_total, "true_yellowed": true_yellowed,
            "pred_total": total, "pred_yellowed": yellowed,
            "ratio_error_pp": round(100 * abs(yellowed / total - true_yellowed / true_total), 2) if total else "",
            "unmatched_labels": missed, "unmatched_predictions": extra, "wrong_class_on_matched_leaf": wrong,
        })
        result.save(filename=str(out / f"{image.stem}.jpg"))
    with (out / "counts.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    for row in rows:
        print(row)
    print(f"计数和预测图：{out}")


if __name__ == "__main__":
    main()
