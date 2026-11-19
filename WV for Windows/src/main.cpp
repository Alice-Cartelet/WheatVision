#include "window.h"

#include <QApplication>
#include <QCommandLineParser>
#include <QFile>
#include <QTextStream>
#include <cmath>
#include <cstdio>

namespace {
int runCommandLine(QApplication &app) {
    QCommandLineParser parser;
    parser.setApplicationDescription("WheatVision 小麦叶片批量识别");
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addOption({"batch", "批量识别图片或文件夹。"});
    parser.addOption({{"o", "output"}, "结果目录。", "目录", defaultOutput()});
    parser.addOption({{"m", "model"}, "YOLO11 两类分割模型。", "ONNX", defaultWeights()});
    parser.addOption({{"c", "confidence"}, "置信度阈值。", "0.01–1", "0.25"});
    parser.addPositionalArgument("图片或文件夹", "要识别的图片或文件夹。", "[路径...]");
    parser.process(app);
    QTextStream error(stderr);
    if (!parser.isSet("batch")) {
        error << parser.helpText() << Qt::endl;
        return 2;
    }
    const auto images = collectImages(parser.positionalArguments());
    bool valid = false;
    const float threshold = parser.value("confidence").toFloat(&valid);
    if (!valid || !std::isfinite(threshold) || threshold < 0.01f || threshold > 1.0f || images.isEmpty()) {
        error << "请提供待识别图片，并使用 0.01 到 1.00 的置信度。" << Qt::endl;
        return 2;
    }
    int failures = 0;
    QTextStream output(stdout);
    try {
        runBatch({images, parser.value("model"), parser.value("output"), threshold}, {
            [] { return false; },
            [&output](const QString &path) { output << path << Qt::endl; },
            [](int) {},
            [&failures](int, const ImageResult &result) { failures += !result.error.isEmpty(); },
        });
    } catch (const std::exception &exception) {
        error << QString::fromUtf8(exception.what()) << Qt::endl;
        return 2;
    }
    return failures ? 1 : 0;
}
}

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    app.setApplicationName("WheatVision");
    app.setApplicationVersion("1.0");
    if (app.arguments().size() > 1)
        return runCommandLine(app);
    app.setStyle("Fusion");
    QFile style(":/style.qss");
    if (style.open(QIODevice::ReadOnly))
        app.setStyleSheet(QString::fromUtf8(style.readAll()));
    MainWindow window;
    window.show();
    return app.exec();
}
