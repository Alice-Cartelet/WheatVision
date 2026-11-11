import argparse
from pathlib import Path

from ultralytics import YOLO


def main():
    project = Path(__file__).resolve().parent
    run = project / "runs" / "wheat-qh"
    demo = project / "demo-dataset" / "images" / "test" / "wheat_generated_C.png"

    trained = run / "weights" / "best.pt"
    bundled = project / "models" / "wheat-qh.pt"
    parser = argparse.ArgumentParser(description="统计照片中可见的小麦叶片和黄化叶片")
    parser.add_argument("image", nargs="?", type=Path, default=demo, help="待识别照片路径")
    parser.add_argument("--weights", type=Path, default=trained if trained.is_file() else bundled)
    parser.add_argument("--conf", type=float, default=0.25, help="最低识别置信度")
    args = parser.parse_args()

    for path in (args.image, args.weights):
        if not path.is_file():
            parser.error(f"找不到文件：{path}")
    if not 0 < args.conf <= 1:
        parser.error("--conf 必须大于 0 且不超过 1")

    model = YOLO(str(args.weights))
    if model.task != "segment" or model.names != {0: "healthy_leaf", 1: "yellowed_leaf"}:
        parser.error("请使用训练好的两类小麦叶片分割权重")

    result = model.predict(
        source=str(args.image), imgsz=512, conf=args.conf, device="cpu", retina_masks=True
    )[0]
    classes = result.boxes.cls.int().tolist()
    healthy = classes.count(0)
    yellowed = classes.count(1)
    total = healthy + yellowed
    ratio = f"{yellowed / total:.1%}" if total else "无法计算（未识别到叶片）"

    output = run / "predictions" / f"{args.image.stem}_prediction.jpg"
    output.parent.mkdir(parents=True, exist_ok=True)
    result.save(filename=str(output))

    print(f"正常叶片 {healthy} 片，黄化叶片 {yellowed} 片，总计 {total} 片")
    print(f"可见叶片黄化比例 {ratio}")
    print(f"标注图：{output}")


if __name__ == "__main__":
    main()
