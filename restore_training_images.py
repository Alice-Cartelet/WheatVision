"""Restore the annotated subset from the original Kaggle download."""
import argparse
import csv
import io
from pathlib import Path
from zipfile import ZipFile

from PIL import Image, ImageOps


def real_rows(dataset):
    with (dataset / "manifest.csv").open(encoding="utf-8-sig", newline="") as manifest:
        return [row for row in csv.DictReader(manifest) if row["origin"] == "Kaggle Wheat Leaf dataset"]


def image_path(dataset, row):
    return dataset / "images" / row["split"] / row["file"]


def require_demo_images(dataset):
    missing = [row for row in real_rows(dataset) if not image_path(dataset, row).is_file()]
    if missing:
        raise FileNotFoundError(
            f"缺少 {len(missing)} 张真实照片。请按 README 从原始 ZIP 恢复训练图片。"
        )


def restore(dataset, archive):
    missing = [row for row in real_rows(dataset) if not image_path(dataset, row).is_file()]
    with ZipFile(archive) as z:
        members = {name.replace("\\", "/").removeprefix("./"): name for name in z.namelist()}
        unavailable = [row["source_file"] for row in missing if row["source_file"] not in members]
        if unavailable:
            raise ValueError(f"这份 ZIP 缺少 {len(unavailable)} 张原始照片，例如 {unavailable[0]}。")
        for row in missing:
            target = image_path(dataset, row)
            target.parent.mkdir(parents=True, exist_ok=True)
            with Image.open(io.BytesIO(z.read(members[row["source_file"]]))) as source:
                image = ImageOps.exif_transpose(source).convert("RGB")
                image.thumbnail((1440, 1440))
                # Create fresh pixels so EXIF, GPS and comments are not copied.
                Image.frombytes("RGB", image.size, image.tobytes()).save(target, quality=94)
    require_demo_images(dataset)
    print(f"已恢复 {len(missing)} 张真实照片。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Wheat Leaf dataset 原始 ZIP")
    args = parser.parse_args()
    restore(Path(__file__).resolve().parent / "demo-dataset", args.archive)
