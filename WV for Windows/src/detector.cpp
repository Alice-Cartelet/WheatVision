#include "detector.h"

#include <QCoreApplication>
#include <QLibrary>
#include <QPainter>
#include <QRegularExpression>
#include <QThread>
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <vector>

#define ORT_API_MANUAL_INIT
#include <onnxruntime_cxx_api.h>

namespace {
constexpr int inputSide = 512;
constexpr int stride = 32;
constexpr int maskChannels = 32;
constexpr int attributes = 6 + maskChannels;

struct Runtime {
    QLibrary library{QCoreApplication::applicationDirPath() + "/onnxruntime"};
    std::unique_ptr<Ort::Env> env;

    Runtime() {
        library.setLoadHints(QLibrary::PreventUnloadHint);
        const auto apiBase = reinterpret_cast<decltype(&OrtGetApiBase)>(library.resolve("OrtGetApiBase"));
        if (!apiBase)
            throw std::runtime_error(QString("无法加载 ONNX Runtime：%1").arg(library.errorString()).toStdString());
        const auto api = apiBase()->GetApi(ORT_API_VERSION);
        if (!api)
            throw std::runtime_error("ONNX Runtime 版本与编译时 SDK 不兼容。");
        Ort::InitApi(api);
        env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "WheatVision");
    }
};

Runtime &runtime() {
    static Runtime instance;
    return instance;
}

struct Input {
    QImage pixels;
    QRect content;
};

struct AxisSample {
    int left;
    int right;
    float fraction;
};

std::vector<AxisSample> interpolationAxis(int target, int source) {
    std::vector<AxisSample> samples;
    samples.reserve(target);
    for (int i = 0; i < target; ++i) {
        const float position = std::clamp(float((i + 0.5) * source / target - 0.5), 0.0f, float(source - 1));
        const int left = static_cast<int>(position);
        samples.push_back({left, std::min(left + 1, source - 1), position - left});
    }
    return samples;
}

Input letterbox(const QImage &original, bool rectangular) {
    const double gain = std::min(double(inputSide) / original.width(), double(inputSide) / original.height());
    const QSize size(qBound(1, int(std::nearbyint(original.width() * gain)), inputSide),
                     qBound(1, int(std::nearbyint(original.height() * gain)), inputSide));
    const int paddingX = (inputSide - size.width()) % (rectangular ? stride : inputSide);
    const int paddingY = (inputSide - size.height()) % (rectangular ? stride : inputSide);
    const QRect content(QPoint(paddingX / 2, paddingY / 2), size);
    QImage pixels(size.width() + paddingX, size.height() + paddingY, QImage::Format_RGB888);
    pixels.fill(QColor(114, 114, 114));
    const auto source = original.convertToFormat(QImage::Format_RGB888);
    const auto xs = interpolationAxis(size.width(), source.width());
    const auto ys = interpolationAxis(size.height(), source.height());
    for (int y = 0; y < size.height(); ++y) {
        const auto v = ys[y];
        const auto *top = source.constScanLine(v.left);
        const auto *bottom = source.constScanLine(v.right);
        auto *target = pixels.scanLine(y + content.y()) + 3 * content.x();
        for (int x = 0; x < size.width(); ++x) {
            const auto u = xs[x];
            for (int c = 0; c < 3; ++c) {
                const float a = top[3 * u.left + c] * (1 - u.fraction) + top[3 * u.right + c] * u.fraction;
                const float b = bottom[3 * u.left + c] * (1 - u.fraction) + bottom[3 * u.right + c] * u.fraction;
                target[3 * x + c] = uchar(qRound(a * (1 - v.fraction) + b * v.fraction));
            }
        }
    }
    return {pixels, content};
}

struct Candidate {
    QRectF box;
    float score;
    int category;
    int index;
};

double area(const QRectF &rect) {
    return rect.width() * rect.height();
}

std::vector<Candidate> selectBoxes(const float *data, int count, float threshold) {
    std::vector<Candidate> candidates;
    for (int i = 0; i < count; ++i) {
        const int category = data[5 * count + i] > data[4 * count + i] ? 1 : 0;
        const float score = data[(4 + category) * count + i];
        if (score <= threshold)
            continue;
        const float w = data[2 * count + i], h = data[3 * count + i];
        if (w > 0 && h > 0)
            candidates.push_back({{data[i] - w / 2, data[count + i] - h / 2, w, h}, score, category, i});
    }
    std::stable_sort(candidates.begin(), candidates.end(), [](const auto &a, const auto &b) { return a.score > b.score; });
    std::vector<Candidate> kept;
    for (const auto &box : candidates) {
        const bool overlaps = std::any_of(kept.begin(), kept.end(), [&box](const Candidate &other) {
            if (box.category != other.category)
                return false;
            const double shared = area(box.box.intersected(other.box));
            return shared / (area(box.box) + area(other.box) - shared) > 0.7;
        });
        if (!overlaps)
            kept.push_back(box);
        if (kept.size() == 300)
            break;
    }
    return kept;
}

bool paintMask(QImage &overlay, const Candidate &candidate, const float *boxes, int boxCount,
               const float *proto, int width, int height, const std::vector<AxisSample> &xs,
               const std::vector<AxisSample> &ys) {
    const int plane = width * height;
    const double scaleX = double(width) / overlay.width(), scaleY = double(height) / overlay.height();
    std::vector<float> logits(plane, 0);
    const QRectF box(candidate.box.x() * scaleX, candidate.box.y() * scaleY,
                     candidate.box.width() * scaleX, candidate.box.height() * scaleY);
    const int left = qBound(0, int(std::ceil(box.left())), width);
    const int top = qBound(0, int(std::ceil(box.top())), height);
    const int right = qBound(0, int(std::ceil(box.right())), width);
    const int bottom = qBound(0, int(std::ceil(box.bottom())), height);
    for (int channel = 0; channel < maskChannels; ++channel) {
        const float weight = boxes[(6 + channel) * boxCount + candidate.index];
        const float *values = proto + channel * plane;
        for (int y = top; y < bottom; ++y) {
            for (int x = left; x < right; ++x)
                logits[y * width + x] += weight * values[y * width + x];
        }
    }

    const int cols = overlay.width(), rows = overlay.height();
    std::vector<unsigned char> mask(cols * rows);
    bool visible = false;
    for (int y = 0; y < rows; ++y) {
        const auto v = ys[y];
        for (int x = 0; x < cols; ++x) {
            const auto u = xs[x];
            const float a = logits[v.left * width + u.left] * (1 - u.fraction)
                          + logits[v.left * width + u.right] * u.fraction;
            const float b = logits[v.right * width + u.left] * (1 - u.fraction)
                          + logits[v.right * width + u.right] * u.fraction;
            if (a * (1 - v.fraction) + b * v.fraction > 0) {
                mask[y * cols + x] = 1;
                visible = true;
            }
        }
    }
    if (!visible)
        return false;

    const QColor color = candidate.category == 0 ? QColor(51, 186, 116) : QColor(255, 188, 59);
    const QRgb fill = qPremultiply(qRgba(color.red(), color.green(), color.blue(), 89));
    for (int y = 0; y < rows; ++y) {
        auto *output = reinterpret_cast<QRgb *>(overlay.scanLine(y));
        for (int x = 0; x < cols; ++x) {
            const int index = y * cols + x;
            if (!mask[index])
                continue;
            const bool edge = x == 0 || y == 0 || x + 1 == cols || y + 1 == rows
                || !mask[index - 1] || !mask[index + 1] || !mask[index - cols] || !mask[index + cols];
            output[x] = edge ? color.rgb() : fill;
        }
    }
    return true;
}
}

struct Detector::Engine {
    Ort::Session session{nullptr};
    std::string inputName;
    std::array<std::string, 2> outputNames;
    bool rectangular = false;

    explicit Engine(const QString &weights) {
        auto &rt = runtime();
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(std::clamp(QThread::idealThreadCount() / 2, 1, 4));
#ifdef _WIN32
        const auto path = weights.toStdWString();
#else
        const auto path = weights.toUtf8();
#endif
#ifdef _WIN32
        session = Ort::Session(*rt.env, path.c_str(), options);
#else
        session = Ort::Session(*rt.env, path.constData(), options);
#endif
        Ort::AllocatorWithDefaultOptions allocator;
        if (session.GetInputCount() != 1 || session.GetOutputCount() != 2)
            throw std::runtime_error("需要输出原始检测张量和分割原型的 YOLO11 分割模型。");
        auto inputType = session.GetInputTypeInfo(0);
        auto shapeInfo = inputType.GetTensorTypeAndShapeInfo();
        const auto shape = shapeInfo.GetShape();
        if (shape.size() != 4 || shapeInfo.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
            || (shape[0] > 0 && shape[0] != 1) || shape[1] != 3
            || (shape[2] != inputSide && shape[2] > 0) || (shape[3] != inputSide && shape[3] > 0))
            throw std::runtime_error("需要尺寸 512 或动态尺寸的 RGB FP32 模型。");
        rectangular = shape[2] < 0 && shape[3] < 0;
        const auto metadata = session.GetModelMetadata();
        const auto names = metadata.LookupCustomMetadataMapAllocated("names", allocator);
        auto labels = QString::fromUtf8(names ? names.get() : "");
        labels.remove(QRegularExpression("[\\s'\"]"));
        if (labels != "{0:healthy_leaf,1:yellowed_leaf}")
            throw std::runtime_error("模型类别须为 0=healthy_leaf、1=yellowed_leaf。");
        inputName = session.GetInputNameAllocated(0, allocator).get();
        for (size_t i = 0; i < outputNames.size(); ++i)
            outputNames[i] = session.GetOutputNameAllocated(i, allocator).get();
    }
};

Detector::Detector(const QString &weights) : engine_(std::make_unique<Engine>(weights)) {}
Detector::~Detector() = default;

Prediction Detector::predict(const QImage &original, float confidence) const {
    if (original.isNull())
        throw std::runtime_error("无法读取图片。");
    const auto input = letterbox(original, engine_->rectangular);
    const int width = input.pixels.width(), height = input.pixels.height(), plane = width * height;
    std::vector<float> pixels(3 * plane);
    for (int y = 0; y < height; ++y) {
        const auto *row = input.pixels.constScanLine(y);
        for (int x = 0; x < width; ++x) {
            for (int c = 0; c < 3; ++c)
                pixels[c * plane + y * width + x] = row[x * 3 + c] / 255.0f;
        }
    }
    const std::array<int64_t, 4> dimensions{1, 3, height, width};
    const auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto tensor = Ort::Value::CreateTensor<float>(memory, pixels.data(), pixels.size(), dimensions.data(), dimensions.size());
    const char *inputName = engine_->inputName.c_str();
    const std::array<const char *, 2> outputNames{engine_->outputNames[0].c_str(), engine_->outputNames[1].c_str()};
    auto outputs = engine_->session.Run(Ort::RunOptions{nullptr}, &inputName, &tensor, 1, outputNames.data(), 2);
    if (outputs[0].GetTensorTypeAndShapeInfo().GetDimensionsCount() == 4)
        std::swap(outputs[0], outputs[1]);
    const auto boxInfo = outputs[0].GetTensorTypeAndShapeInfo(), maskInfo = outputs[1].GetTensorTypeAndShapeInfo();
    const auto boxes = boxInfo.GetShape(), proto = maskInfo.GetShape();
    if (boxes.size() != 3 || boxes[0] != 1 || boxes[1] != attributes || boxes[2] <= 0 || boxes[2] > 8400
        || proto.size() != 4 || proto[0] != 1 || proto[1] != maskChannels || proto[2] != height / 4 || proto[3] != width / 4
        || boxInfo.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
        || maskInfo.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        throw std::runtime_error("模型输出不符合 WheatVision 的 YOLO11 分割格式。");

    const float *data = outputs[0].GetTensorData<float>();
    const auto kept = selectBoxes(data, int(boxes[2]), confidence);
    Prediction result{original.convertToFormat(QImage::Format_RGB32)};
    if (kept.empty())
        return result;
    QImage overlay(width, height, QImage::Format_ARGB32_Premultiplied);
    overlay.fill(Qt::transparent);
    const auto xs = interpolationAxis(width, int(proto[3])), ys = interpolationAxis(height, int(proto[2]));
    const float *prototypes = outputs[1].GetTensorData<float>();
    for (auto it = kept.rbegin(); it != kept.rend(); ++it) {
        if (paintMask(overlay, *it, data, int(boxes[2]), prototypes, int(proto[3]), int(proto[2]), xs, ys)) {
            if (it->category == 0)
                ++result.healthy;
            else
                ++result.yellowed;
        }
    }
    QPainter painter(&result.annotated);
    painter.setRenderHint(QPainter::SmoothPixmapTransform);
    painter.drawImage(result.annotated.rect(), overlay, input.content);
    painter.end();
    return result;
}
