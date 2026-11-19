#include "batch.h"
#include "detector.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QImageReader>
#include <QSaveFile>
#include <QSet>
#include <QTemporaryDir>
#include <stdexcept>

namespace {
const QStringList extensions{"jpg", "jpeg", "png", "bmp", "tif", "tiff", "webp"};

void appendImages(const QFileInfo &info, QStringList &paths) {
    if (info.isFile() && extensions.contains(info.suffix().toLower())) {
        const auto path = info.canonicalFilePath();
        if (!path.isEmpty())
            paths.append(path);
    } else if (info.isDir() && !info.isSymLink()) {
        const QDir folder(info.absoluteFilePath());
        if (folder.exists("识别汇总.csv") && folder.exists("标注图"))
            return;
        const auto entries = folder.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot,
                                                  QDir::DirsLast | QDir::Name | QDir::IgnoreCase);
        for (const auto &entry : entries)
            appendImages(entry, paths);
    }
}

void writeRow(QFile &file, QStringList fields) {
    for (auto &field : fields)
        field = '"' + field.replace('"', "\"\"") + '"';
    const auto bytes = (fields.join(',') + "\r\n").toUtf8();
    if (file.write(bytes) != bytes.size() || !file.flush())
        throw std::runtime_error(QString("无法写入 CSV：%1").arg(file.errorString()).toStdString());
}
}

QString ImageResult::ratio() const {
    const int total = healthy + yellowed;
    return total ? QString::number(100.0 * yellowed / total, 'f', 1) + '%' : QString();
}

QString defaultWeights() {
    return QCoreApplication::applicationDirPath() + "/models/wheat-qh.onnx";
}

QString defaultOutput() {
    return QCoreApplication::applicationDirPath() + "/results";
}

QString imageFilter() {
    QStringList patterns;
    for (const auto &extension : extensions)
        patterns.append("*." + extension);
    return "图片 (" + patterns.join(' ') + ')';
}

QStringList collectImages(const QStringList &paths) {
    QStringList images;
    for (const auto &path : paths)
        appendImages(QFileInfo(path), images);
    images.removeDuplicates();
    return images;
}

QImage readImage(const QString &path, int previewSide) {
    QImageReader reader(path);
    reader.setAutoTransform(true);
    if (previewSide) {
        const auto size = reader.size();
        if (size.width() > previewSide || size.height() > previewSide)
            reader.setScaledSize(size.scaled(previewSide, previewSide, Qt::KeepAspectRatio));
    }
    auto image = reader.read();
    if (image.isNull())
        throw std::runtime_error(QString("无法读取图片：%1").arg(reader.errorString()).toStdString());
    return image;
}

void runBatch(const BatchOptions &options, const BatchCallbacks &callbacks) {
    if (!QFileInfo(options.weights).isFile())
        throw std::runtime_error(QString("找不到模型：%1").arg(options.weights).toStdString());
    if (callbacks.canceled())
        return;
    const Detector detector(options.weights);
    if (callbacks.canceled())
        return;
    if (!QDir().mkpath(options.output))
        throw std::runtime_error("无法创建输出目录。");
    const QDir root(options.output);
    const auto prefix = "wheat-" + QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss") + "-XXXXXX";
    QTemporaryDir batch(root.absoluteFilePath(prefix));
    if (!batch.isValid() || !QDir(batch.path()).mkdir("标注图"))
        throw std::runtime_error("无法创建本批结果目录。");
    const QDir output(batch.path());
    QFile report(output.filePath("识别汇总.csv"));
    if (!report.open(QIODevice::WriteOnly) || report.write("\xEF\xBB\xBF", 3) != 3)
        throw std::runtime_error("无法创建 CSV 文件。");
    writeRow(report, {"图片", "原图路径", "状态", "正常叶", "枯黄叶", "总叶数", "枯黄占比", "标注图", "错误"});
    batch.setAutoRemove(false);
    callbacks.reportReady(output.path());

    for (int row = 0; row < options.images.size() && !callbacks.canceled(); ++row) {
        callbacks.imageStarted(row);
        const QFileInfo source(options.images[row]);
        const auto relative = QString("标注图/%1_%2.jpg").arg(row + 1, 5, 10, QChar('0'))
                             .arg(source.completeBaseName().left(55));
        const auto destination = output.filePath(relative);
        ImageResult result;
        try {
            const auto prediction = detector.predict(readImage(source.filePath()), options.confidence);
            QSaveFile file(destination);
            if (!file.open(QIODevice::WriteOnly) || !prediction.annotated.save(&file, "JPG", 92) || !file.commit())
                throw std::runtime_error(QString("无法保存标注图：%1").arg(file.errorString()).toStdString());
            result = {destination, prediction.healthy, prediction.yellowed, {}};
        } catch (const std::exception &error) {
            result.error = QString::fromUtf8(error.what());
        }
        if (result.error.isEmpty()) {
            writeRow(report, {source.fileName(), source.filePath(), "完成", QString::number(result.healthy),
                QString::number(result.yellowed), QString::number(result.healthy + result.yellowed), result.ratio(), relative, {}});
        } else {
            writeRow(report, {source.fileName(), source.filePath(), "失败", {}, {}, {}, {}, {}, result.error});
        }
        callbacks.imageDone(row, result);
    }
}

BatchWorker::BatchWorker(BatchOptions options, QObject *parent) : QThread(parent), options_(std::move(options)) {}

void BatchWorker::run() {
    try {
        runBatch(options_, {
            [this] { return isInterruptionRequested(); },
            [this](const QString &path) { emit reportReady(path); },
            [this](int row) { emit imageStarted(row); },
            [this](int row, const ImageResult &result) { emit imageDone(row, result); },
        });
    } catch (const std::exception &error) {
        emit failed(QString::fromUtf8(error.what()));
    }
}
