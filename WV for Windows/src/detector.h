#pragma once

#include <QImage>
#include <QString>
#include <memory>

struct Prediction {
    QImage annotated;
    int healthy = 0;
    int yellowed = 0;
};

class Detector {
public:
    explicit Detector(const QString &weights);
    ~Detector();
    Prediction predict(const QImage &original, float confidence) const;

private:
    struct Engine;
    std::unique_ptr<Engine> engine_;
};
