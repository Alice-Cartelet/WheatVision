#pragma once

#include <QImage>
#include <QStringList>
#include <QThread>
#include <functional>

struct BatchOptions {
    QStringList images;
    QString weights;
    QString output;
    float confidence = 0.25f;
};

struct ImageResult {
    QString annotated;
    int healthy = 0;
    int yellowed = 0;
    QString error;

    QString ratio() const;
};
Q_DECLARE_METATYPE(ImageResult)

struct BatchCallbacks {
    std::function<bool()> canceled;
    std::function<void(const QString &)> reportReady;
    std::function<void(int)> imageStarted;
    std::function<void(int, const ImageResult &)> imageDone;
};

QString defaultWeights();
QString defaultOutput();
QString imageFilter();
QStringList collectImages(const QStringList &paths);
QImage readImage(const QString &path, int previewSide = 0);
void runBatch(const BatchOptions &options, const BatchCallbacks &callbacks);

class BatchWorker final : public QThread {
    Q_OBJECT
public:
    BatchWorker(BatchOptions options, QObject *parent);

signals:
    void reportReady(const QString &path);
    void imageStarted(int row);
    void imageDone(int row, const ImageResult &result);
    void failed(const QString &error);

protected:
    void run() override;

private:
    BatchOptions options_;
};
