#pragma once

#include "batch.h"

#include <QHash>
#include <QLabel>
#include <QMainWindow>

class QDoubleSpinBox;
class QProgressBar;
class QPushButton;
class QStackedWidget;
class QTableWidget;

class Preview final : public QWidget {
public:
    Preview();
    void showImage(const QString &path);

protected:
    void paintEvent(QPaintEvent *event) override;

private:
    QString path_;
    QPixmap picture_;
};

class MainWindow final : public QMainWindow {
public:
    MainWindow();

protected:
    void closeEvent(QCloseEvent *event) override;
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;

private:
    QWidget *buildHeader();
    QWidget *buildSidebar();
    QWidget *buildMetrics();
    QWidget *buildQueue();
    QWidget *buildPreview();
    QWidget *buildFooter();
    void addPaths(const QStringList &paths);
    void setCell(int row, int column, const QString &text, const QString &tooltip = {});
    void refreshControls();
    void refreshMetrics();
    void refreshPreview();
    void startBatch();
    void stopBatch();
    void finishBatch();
    void recordResult(int row, const ImageResult &result);

    QString weights_;
    QString output_;
    QString batchOutput_;
    QStringList images_;
    QHash<int, ImageResult> results_;
    BatchWorker *worker_ = nullptr;
    bool batchFailed_ = false;
    bool closeAfterBatch_ = false;
    bool showOriginal_ = false;
    qint64 healthyLeaves_ = 0;
    qint64 yellowedLeaves_ = 0;

    QLabel *modelLabel_;
    QLabel *outputLabel_;
    QLabel *queueCount_;
    QLabel *fileName_;
    QLabel *detail_;
    QLabel *status_;
    QLabel *processedMetric_;
    QLabel *healthyMetric_;
    QLabel *yellowedMetric_;
    QLabel *ratioMetric_;
    QDoubleSpinBox *confidence_;
    QTableWidget *table_;
    QStackedWidget *queueContents_;
    QProgressBar *progress_;
    Preview *preview_;
    QPushButton *start_;
    QPushButton *stop_;
    QPushButton *modelButton_;
    QPushButton *outputButton_;
    QPushButton *add_;
    QPushButton *folder_;
    QPushButton *clear_;
    QPushButton *original_;
    QPushButton *annotated_;
    QPushButton *open_;
};
