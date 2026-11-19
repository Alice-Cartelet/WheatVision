#include "window.h"

#include <QButtonGroup>
#include <QCloseEvent>
#include <QDesktopServices>
#include <QDir>
#include <QDoubleSpinBox>
#include <QDragEnterEvent>
#include <QFileDialog>
#include <QFileInfo>
#include <QHeaderView>
#include <QLocale>
#include <QMessageBox>
#include <QMimeData>
#include <QPainter>
#include <QPainterPath>
#include <QProgressBar>
#include <QPushButton>
#include <QSet>
#include <QScreen>
#include <QSplitter>
#include <QStackedWidget>
#include <QStyledItemDelegate>
#include <QTableWidget>
#include <QUrl>
#include <QVBoxLayout>
#include <algorithm>

namespace {
enum class Icon { leaf, image, folder, play, stop, arrow, queue };

QPixmap glyph(Icon icon, const QColor &color, int size) {
    QPixmap pixmap(size * 2, size * 2);
    pixmap.setDevicePixelRatio(2);
    pixmap.fill(Qt::transparent);
    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.scale(size / 24.0, size / 24.0);
    painter.setPen(QPen(color, 1.65, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
    QPainterPath outline;
    switch (icon) {
    case Icon::leaf:
        outline.moveTo(5, 18);
        outline.cubicTo(1, 10, 8, 5, 20, 4);
        outline.cubicTo(20, 15, 15, 22, 5, 18);
        painter.drawPath(outline);
        painter.drawLine(QPointF(4, 21), QPointF(15, 10));
        break;
    case Icon::image:
        painter.drawRoundedRect(QRectF(3, 4, 18, 16), 2, 2);
        painter.drawEllipse(QPointF(8.5, 9), 1.5, 1.5);
        painter.drawPolyline(QPolygonF{{4, 16}, {9, 12}, {12, 15}, {16, 10}, {20, 14}});
        break;
    case Icon::folder:
        painter.drawPolygon(QPolygonF{{3, 6}, {10, 6}, {12, 9}, {21, 9}, {21, 19}, {3, 19}});
        break;
    case Icon::play:
        painter.setBrush(color);
        painter.drawPolygon(QPolygonF{{8, 5}, {19, 12}, {8, 19}});
        break;
    case Icon::stop:
        painter.drawRoundedRect(QRectF(7, 7, 10, 10), 1.5, 1.5);
        break;
    case Icon::arrow:
        painter.drawLine(QPointF(5, 19), QPointF(18, 6));
        painter.drawPolyline(QPolygonF{{11, 6}, {18, 6}, {18, 13}});
        break;
    case Icon::queue:
        painter.drawRoundedRect(QRectF(4, 4, 16, 16), 2, 2);
        painter.drawLine(QPointF(8, 9), QPointF(16, 9));
        painter.drawLine(QPointF(8, 14), QPointF(16, 14));
        break;
    }
    return pixmap;
}

QLabel *label(const QString &text, const char *style = "") {
    auto *widget = new QLabel(text);
    widget->setTextFormat(Qt::PlainText);
    widget->setObjectName(style);
    return widget;
}

QPushButton *button(const QString &text, const char *style = "") {
    auto *widget = new QPushButton(text);
    widget->setObjectName(style);
    return widget;
}

QFrame *panel(const char *style = "panel") {
    auto *frame = new QFrame;
    frame->setObjectName(style);
    return frame;
}

QWidget *metricCard(const QString &title, const char *tone, QLabel *&value) {
    auto *card = panel("metric");
    card->setProperty("tone", tone);
    auto *layout = new QVBoxLayout(card);
    layout->setContentsMargins(16, 10, 16, 12);
    layout->setSpacing(3);
    layout->addWidget(label(title, "metricLabel"));
    value = label("—", "metricValue");
    layout->addWidget(value);
    return card;
}

class StatusDelegate final : public QStyledItemDelegate {
public:
    using QStyledItemDelegate::QStyledItemDelegate;

    void paint(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override {
        QStyleOptionViewItem background(option);
        initStyleOption(&background, index);
        const auto text = background.text;
        background.text.clear();
        background.widget->style()->drawControl(QStyle::CE_ItemViewItem, &background, painter, background.widget);

        QColor fill("#EEF0EB"), ink("#59655D");
        if (text == "完成") {
            fill = QColor("#E1EFDD"); ink = QColor("#286043");
        } else if (text == "失败") {
            fill = QColor("#F6E4DF"); ink = QColor("#9B3528");
        } else if (text == "识别中") {
            fill = QColor("#F6EDCF"); ink = QColor("#73570D");
        }
        const auto center = option.rect.center();
        const qreal width = qMin(option.rect.width() - 8, option.fontMetrics.horizontalAdvance(text) + 15);
        const QRectF badge(center.x() - width / 2, center.y() - 11, width, 22);
        painter->save();
        painter->setRenderHint(QPainter::Antialiasing);
        painter->setPen(Qt::NoPen);
        painter->setBrush(fill);
        painter->drawRoundedRect(badge, 7, 7);
        painter->setPen(ink);
        painter->drawText(badge, Qt::AlignCenter, text);
        painter->restore();
    }
};

class ConfidenceInput final : public QDoubleSpinBox {
protected:
    void paintEvent(QPaintEvent *event) override {
        QDoubleSpinBox::paintEvent(event);
        QStyleOptionSpinBox option;
        initStyleOption(&option);
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing);
        painter.setPen(QPen(QColor(isEnabled() ? "#E5F2E2" : "#A5B8AA"), 1.2, Qt::SolidLine, Qt::RoundCap));
        for (const auto control : {QStyle::SC_SpinBoxUp, QStyle::SC_SpinBoxDown}) {
            const QPointF center = style()->subControlRect(QStyle::CC_SpinBox, &option, control, this).center();
            const qreal rise = control == QStyle::SC_SpinBoxUp ? -2 : 2;
            painter.drawPolyline(QPolygonF{center + QPointF(-2.5, 0), center + QPointF(0, rise), center + QPointF(2.5, 0)});
        }
    }
};
}

Preview::Preview() {
    setObjectName("preview");
    setMinimumSize(220, 180);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    setAccessibleName("原图与标注图预览");
}

void Preview::showImage(const QString &path) {
    if (path != path_) {
        path_ = path;
        picture_ = QPixmap();
        setToolTip({});
        if (!path.isEmpty()) {
            try {
                picture_ = QPixmap::fromImage(readImage(path, 1600));
            } catch (const std::exception &) {
                setToolTip(path);
            }
        }
    }
    update();
}

void Preview::paintEvent(QPaintEvent *) {
    QPainter painter(this);
    painter.setRenderHints(QPainter::Antialiasing | QPainter::SmoothPixmapTransform);
    QPainterPath stage;
    stage.addRoundedRect(rect(), 11, 11);
    painter.setClipPath(stage);
    painter.fillRect(rect(), QColor("#172A23"));
    if (!picture_.isNull()) {
        const QSize scaled = picture_.size().scaled(size() - QSize(24, 24), Qt::KeepAspectRatio);
        const QRect target(QPoint((width() - scaled.width()) / 2, (height() - scaled.height()) / 2), scaled);
        painter.setPen(Qt::NoPen);
        painter.setBrush(QColor("#0C1914"));
        painter.drawRoundedRect(target.adjusted(-2, -2, 2, 2), 3, 3);
        painter.drawPixmap(target, picture_, picture_.rect());
        return;
    }

    painter.setPen(QColor("#2C4439"));
    for (int y = height() / 2 % 22; y < height(); y += 22) {
        for (int x = width() / 2 % 22; x < width(); x += 22)
            painter.drawPoint(x, y);
    }
    const QPoint center(width() / 2, height() / 2 - 13);
    painter.setPen(QPen(QColor("#496657"), 1));
    painter.setBrush(QColor("#253E32"));
    painter.drawRoundedRect(QRect(center.x() - 28, center.y() - 35, 56, 56), 14, 14);
    painter.drawPixmap(QPoint(center.x() - 14, center.y() - 21), glyph(Icon::image, QColor("#C2DAB4"), 28));
    auto titleFont = font();
    titleFont.setPixelSize(16);
    titleFont.setWeight(QFont::DemiBold);
    painter.setFont(titleFont);
    painter.setPen(QColor("#E6EFE6"));
    const QString title = path_.isEmpty() ? "拖入图片或文件夹" : "无法预览此图片";
    painter.drawText(QRect(0, center.y() + 33, width(), 24), Qt::AlignCenter, title);
    if (path_.isEmpty()) {
        painter.setFont(font());
        painter.setPen(QColor("#B3C4B8"));
        painter.drawText(QRect(0, center.y() + 61, width(), 22), Qt::AlignCenter, "也可从左侧导入");
    }
}

MainWindow::MainWindow() : weights_(defaultWeights()), output_(defaultOutput()) {
    setWindowTitle("WheatVision · 小麦叶片批量识别");
    setWindowIcon(QIcon(glyph(Icon::leaf, QColor("#487253"), 32)));
    setMinimumSize(1030, 640);
    resize(QSize(1360, 830).boundedTo(screen()->availableGeometry().size() - QSize(24, 52)));
    setAcceptDrops(true);
    auto *content = new QWidget;
    content->setObjectName("workspace");
    setCentralWidget(content);
    auto *shell = new QHBoxLayout(content);
    shell->setContentsMargins(0, 0, 0, 0);
    shell->setSpacing(0);
    shell->addWidget(buildSidebar());
    auto *main = new QWidget;
    shell->addWidget(main, 1);
    auto *outer = new QVBoxLayout(main);
    outer->setContentsMargins(24, 18, 24, 16);
    outer->setSpacing(14);
    outer->addWidget(buildHeader());
    outer->addWidget(buildMetrics());
    auto *split = new QSplitter;
    split->setHandleWidth(12);
    split->setChildrenCollapsible(false);
    split->addWidget(buildPreview());
    split->addWidget(buildQueue());
    split->setStretchFactor(0, 1);
    split->setStretchFactor(1, 0);
    split->setSizes({680, 360});
    outer->addWidget(split, 1);
    outer->addWidget(buildFooter());
    refreshPreview();
    refreshControls();
}

QWidget *MainWindow::buildHeader() {
    auto *frame = new QWidget;
    auto *row = new QHBoxLayout(frame);
    row->setContentsMargins(0, 4, 0, 4);
    row->addWidget(label("小麦叶片批量识别", "pageTitle"), 1);
    start_ = button("开始识别", "primary");
    start_->setIcon(QIcon(glyph(Icon::play, QColor("#F1FAEC"), 16)));
    stop_ = button("停止识别", "stop");
    stop_->setIcon(QIcon(glyph(Icon::stop, QColor("#903C32"), 16)));
    row->addWidget(stop_);
    row->addWidget(start_);
    connect(start_, &QPushButton::clicked, this, &MainWindow::startBatch);
    connect(stop_, &QPushButton::clicked, this, &MainWindow::stopBatch);
    return frame;
}

QWidget *MainWindow::buildSidebar() {
    auto *frame = panel("sidebar");
    frame->setFixedWidth(218);
    auto *layout = new QVBoxLayout(frame);
    layout->setContentsMargins(20, 23, 20, 20);
    layout->setSpacing(10);

    auto *brand = new QHBoxLayout;
    brand->setSpacing(9);
    auto *mark = label({}, "mark");
    mark->setFixedSize(37, 37);
    mark->setAlignment(Qt::AlignCenter);
    mark->setPixmap(glyph(Icon::leaf, QColor("#203925"), 26));
    brand->addWidget(mark);
    brand->addWidget(label("WheatVision", "brand"), 1);
    layout->addLayout(brand);
    layout->addSpacing(25);
    layout->addWidget(label("导入数据", "sidebarHeading"));
    add_ = button("导入图片", "import");
    add_->setIcon(QIcon(glyph(Icon::image, QColor("#203925"), 18)));
    folder_ = button("导入文件夹", "sideButton");
    folder_->setIcon(QIcon(glyph(Icon::folder, QColor("#E6F0E8"), 18)));
    layout->addWidget(add_);
    layout->addWidget(folder_);
    connect(add_, &QPushButton::clicked, this, [this] {
        const auto paths = QFileDialog::getOpenFileNames(this, "导入待识别图片", {}, imageFilter());
        if (!paths.isEmpty())
            addPaths(paths);
    });
    connect(folder_, &QPushButton::clicked, this, [this] {
        const auto path = QFileDialog::getExistingDirectory(this, "导入待识别图片文件夹");
        if (!path.isEmpty())
            addPaths({path});
    });
    layout->addSpacing(16);
    auto *divider = panel("sideDivider");
    divider->setFixedHeight(1);
    layout->addWidget(divider);
    layout->addSpacing(5);
    layout->addWidget(label("识别设置", "sidebarHeading"));

    auto *modelRow = new QHBoxLayout;
    modelRow->addWidget(label("模型", "sideLabel"), 1);
    modelButton_ = button("更换", "sideLink");
    modelRow->addWidget(modelButton_);
    layout->addLayout(modelRow);
    modelLabel_ = label(QFileInfo(weights_).fileName(), "sideValue");
    modelLabel_->setToolTip(weights_);
    layout->addWidget(modelLabel_);
    connect(modelButton_, &QPushButton::clicked, this, [this] {
        const auto path = QFileDialog::getOpenFileName(this, "选择小麦分割模型", QFileInfo(weights_).absolutePath(), "ONNX 模型 (*.onnx)");
        if (!path.isEmpty()) {
            weights_ = path;
            modelLabel_->setText(modelLabel_->fontMetrics().elidedText(QFileInfo(path).fileName(), Qt::ElideMiddle, 154));
            modelLabel_->setToolTip(path);
        }
    });
    auto *threshold = new QHBoxLayout;
    threshold->addWidget(label("置信度", "sideLabel"), 1);
    confidence_ = new ConfidenceInput;
    confidence_->setAccessibleName("最低识别置信度");
    confidence_->setRange(0.01, 1.0);
    confidence_->setSingleStep(0.05);
    confidence_->setValue(0.25);
    confidence_->setKeyboardTracking(false);
    confidence_->setFixedWidth(78);
    threshold->addWidget(confidence_);
    layout->addLayout(threshold);
    layout->addStretch(1);

    auto *outputRow = new QHBoxLayout;
    outputRow->addWidget(label("输出目录", "sideLabel"), 1);
    outputButton_ = button("更改", "sideLink");
    outputButton_->setAccessibleName("更改输出目录");
    outputButton_->setToolTip(output_);
    outputRow->addWidget(outputButton_);
    layout->addLayout(outputRow);
    outputLabel_ = label({}, "sideValue");
    auto showOutput = [this] {
        outputLabel_->setText(outputLabel_->fontMetrics().elidedText(QDir::toNativeSeparators(output_), Qt::ElideLeft, 154));
        outputLabel_->setToolTip(QDir::toNativeSeparators(output_));
    };
    showOutput();
    layout->addWidget(outputLabel_);
    connect(outputButton_, &QPushButton::clicked, this, [this, showOutput] {
        const auto start = QFileInfo(output_).isDir() ? output_ : QFileInfo(output_).absolutePath();
        const auto path = QFileDialog::getExistingDirectory(this, "选择输出目录", start);
        if (!path.isEmpty()) {
            output_ = path;
            outputButton_->setToolTip(path);
            showOutput();
            status_->setText(QString("输出目录已设置为 %1").arg(QFileInfo(path).fileName()));
        }
    });
    return frame;
}

QWidget *MainWindow::buildMetrics() {
    auto *frame = new QWidget;
    auto *row = new QHBoxLayout(frame);
    row->setContentsMargins(0, 0, 0, 0);
    row->setSpacing(12);
    row->addWidget(metricCard("已处理图片", "neutral", processedMetric_), 1);
    row->addWidget(metricCard("正常叶", "green", healthyMetric_), 1);
    row->addWidget(metricCard("枯黄叶", "gold", yellowedMetric_), 1);
    row->addWidget(metricCard("批次枯黄占比", "neutral", ratioMetric_), 1);
    ratioMetric_->setToolTip("所有已完成图片的枯黄叶总数 ÷ 识别出的叶片总数");
    return frame;
}

QWidget *MainWindow::buildQueue() {
    auto *frame = panel();
    frame->setMinimumWidth(326);
    auto *layout = new QVBoxLayout(frame);
    layout->setContentsMargins(14, 12, 14, 12);
    layout->setSpacing(10);
    auto *top = new QHBoxLayout;
    top->addWidget(label("识别队列", "section"));
    queueCount_ = label({}, "countBadge");
    top->addWidget(queueCount_);
    top->addStretch();
    clear_ = button("清空", "quietButton");
    top->addWidget(clear_);
    layout->addLayout(top);
    table_ = new QTableWidget(0, 5);
    table_->setHorizontalHeaderLabels({"图片", "状态", "正常", "枯黄", "占比"});
    table_->verticalHeader()->hide();
    table_->verticalHeader()->setDefaultSectionSize(39);
    table_->setSelectionMode(QAbstractItemView::SingleSelection);
    table_->setSelectionBehavior(QAbstractItemView::SelectRows);
    table_->setEditTriggers(QAbstractItemView::NoEditTriggers);
    table_->setAlternatingRowColors(true);
    table_->setShowGrid(false);
    table_->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    table_->setItemDelegateForColumn(1, new StatusDelegate(table_));
    table_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
    const int widths[] = {65, 39, 39, 54};
    for (int column = 1; column < 5; ++column) {
        table_->horizontalHeader()->setSectionResizeMode(column, QHeaderView::Fixed);
        table_->setColumnWidth(column, widths[column - 1]);
    }
    connect(table_, &QTableWidget::currentCellChanged, this, &MainWindow::refreshPreview);
    queueContents_ = new QStackedWidget;
    auto *empty = panel("queueEmpty");
    auto *emptyContent = new QVBoxLayout(empty);
    emptyContent->addStretch(1);
    auto *emptyIcon = label({});
    emptyIcon->setPixmap(glyph(Icon::queue, QColor("#7B9784"), 30));
    emptyContent->addWidget(emptyIcon, 0, Qt::AlignHCenter);
    emptyContent->addWidget(label("队列为空", "muted"), 0, Qt::AlignHCenter);
    emptyContent->addStretch(1);
    queueContents_->addWidget(empty);
    queueContents_->addWidget(table_);
    layout->addWidget(queueContents_, 1);
    connect(clear_, &QPushButton::clicked, this, [this] {
        images_.clear();
        results_.clear();
        healthyLeaves_ = yellowedLeaves_ = 0;
        table_->setRowCount(0);
        status_->setText("导入待识别图片");
        refreshPreview();
        refreshControls();
    });
    return frame;
}

QWidget *MainWindow::buildPreview() {
    auto *frame = panel();
    auto *layout = new QVBoxLayout(frame);
    layout->setContentsMargins(14, 12, 14, 12);
    layout->setSpacing(10);
    auto *top = new QHBoxLayout;
    top->addWidget(label("图片预览", "section"));
    top->addStretch();
    auto *switcher = panel("switcher");
    auto *tabs = new QHBoxLayout(switcher);
    tabs->setContentsMargins(3, 3, 3, 3);
    tabs->setSpacing(2);
    original_ = button("原图", "viewTab");
    annotated_ = button("标注图", "viewTab");
    original_->setCheckable(true);
    annotated_->setCheckable(true);
    auto *group = new QButtonGroup(switcher);
    group->addButton(original_);
    group->addButton(annotated_);
    connect(original_, &QPushButton::clicked, this, [this] {
        showOriginal_ = true;
        refreshPreview();
    });
    connect(annotated_, &QPushButton::clicked, this, [this] {
        showOriginal_ = false;
        refreshPreview();
    });
    tabs->addWidget(original_);
    tabs->addWidget(annotated_);
    top->addWidget(switcher);
    layout->addLayout(top);
    preview_ = new Preview;
    layout->addWidget(preview_, 1);
    auto *details = new QHBoxLayout;
    details->setSpacing(6);
    details->addWidget(label("● 正常叶", "healthy"));
    details->addWidget(label("● 枯黄叶", "yellowed"));
    details->addStretch(1);
    detail_ = label({}, "muted");
    detail_->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    details->addWidget(detail_);
    layout->addLayout(details);
    fileName_ = label({}, "fileName");
    fileName_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
    layout->addWidget(fileName_);
    return frame;
}

QWidget *MainWindow::buildFooter() {
    auto *frame = panel();
    auto *row = new QHBoxLayout(frame);
    row->setContentsMargins(14, 8, 10, 8);
    row->setSpacing(12);
    status_ = label("导入待识别图片", "muted");
    status_->setMinimumWidth(0);
    status_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
    progress_ = new QProgressBar;
    progress_->setFixedWidth(123);
    open_ = button("打开结果", "resultButton");
    open_->setAccessibleName("打开本批结果文件夹");
    open_->setIcon(QIcon(glyph(Icon::arrow, QColor("#325A44"), 16)));
    row->addWidget(status_, 1);
    row->addWidget(progress_);
    row->addWidget(open_);
    connect(open_, &QPushButton::clicked, this, [this] {
        if (!batchOutput_.isEmpty() && !QDesktopServices::openUrl(QUrl::fromLocalFile(batchOutput_)))
            QMessageBox::warning(this, "无法打开结果文件夹", batchOutput_);
    });
    return frame;
}

void MainWindow::dragEnterEvent(QDragEnterEvent *event) {
    const auto urls = event->mimeData()->urls();
    if (!worker_ && std::any_of(urls.begin(), urls.end(), [](const QUrl &url) { return url.isLocalFile(); }))
        event->acceptProposedAction();
}

void MainWindow::dropEvent(QDropEvent *event) {
    if (worker_)
        return;
    QStringList paths;
    for (const auto &url : event->mimeData()->urls()) {
        if (url.isLocalFile())
            paths.append(url.toLocalFile());
    }
    if (!paths.isEmpty()) {
        addPaths(paths);
        event->acceptProposedAction();
    }
}

void MainWindow::addPaths(const QStringList &paths) {
    const qsizetype first = images_.size();
    const QSet<QString> existing(images_.begin(), images_.end());
    for (const auto &path : collectImages(paths)) {
        if (!existing.contains(path))
            images_.append(path);
    }
    table_->setRowCount(int(images_.size()));
    for (int row = int(first); row < images_.size(); ++row) {
        setCell(row, 0, QFileInfo(images_[row]).fileName(), images_[row]);
        setCell(row, 1, "待识别");
    }
    if (!images_.isEmpty() && table_->currentRow() < 0)
        table_->selectRow(0);
    status_->setText(images_.size() > first ? QString("已导入 %1 张图片").arg(images_.size() - first) : "没有可新增的图片");
    refreshControls();
}

void MainWindow::setCell(int row, int column, const QString &text, const QString &tooltip) {
    auto *item = new QTableWidgetItem(text);
    item->setToolTip(tooltip);
    if (column)
        item->setTextAlignment(Qt::AlignCenter);
    table_->setItem(row, column, item);
}

void MainWindow::refreshControls() {
    const bool busy = worker_ != nullptr;
    for (auto *widget : {modelButton_, outputButton_, add_, folder_})
        widget->setEnabled(!busy);
    confidence_->setEnabled(!busy);
    start_->setEnabled(!images_.isEmpty() && !busy);
    clear_->setEnabled(!images_.isEmpty() && !busy);
    stop_->setVisible(busy);
    open_->setEnabled(!batchOutput_.isEmpty());
    open_->setToolTip(batchOutput_);
    queueCount_->setText(QString("%1 张").arg(images_.size()));
    queueContents_->setCurrentIndex(images_.isEmpty() ? 0 : 1);
    refreshMetrics();
}

void MainWindow::refreshMetrics() {
    const QLocale locale;
    progress_->setRange(0, qMax(1, int(images_.size())));
    progress_->setValue(int(results_.size()));
    progress_->setFormat(images_.isEmpty() ? "—" : "%v / %m");
    processedMetric_->setText(QString("%1 / %2").arg(locale.toString(results_.size()), locale.toString(images_.size())));
    healthyMetric_->setText(locale.toString(healthyLeaves_));
    yellowedMetric_->setText(locale.toString(yellowedLeaves_));
    const auto total = healthyLeaves_ + yellowedLeaves_;
    ratioMetric_->setText(total ? QString::number(100.0 * yellowedLeaves_ / total, 'f', 1) + '%' : QString("—"));
}

void MainWindow::refreshPreview() {
    const int row = table_->currentRow();
    const auto result = results_.value(row);
    const auto source = images_.value(row);
    const bool annotated = !result.annotated.isEmpty();
    const bool useAnnotation = annotated && !showOriginal_;
    original_->setEnabled(!source.isEmpty());
    annotated_->setEnabled(annotated);
    (useAnnotation ? annotated_ : original_)->setChecked(true);
    preview_->showImage(useAnnotation ? result.annotated : source);
    fileName_->setVisible(!source.isEmpty());
    fileName_->setText(QFileInfo(source).fileName());
    fileName_->setToolTip(QDir::toNativeSeparators(source));
    if (annotated) {
        const auto ratio = result.ratio();
        detail_->setText(QString("本图  正常 %1 · 枯黄 %2 · %3")
                         .arg(result.healthy).arg(result.yellowed).arg(ratio.isEmpty() ? "—" : ratio));
    } else {
        detail_->setText(result.error.isEmpty() ? "" : "识别失败，详情见队列");
    }
    detail_->setToolTip(result.error);
}

void MainWindow::startBatch() {
    if (!QFileInfo(weights_).isFile()) {
        QMessageBox::warning(this, "缺少模型", QString("找不到 ONNX 模型。\n%1").arg(weights_));
        return;
    }
    results_.clear();
    healthyLeaves_ = yellowedLeaves_ = 0;
    batchOutput_.clear();
    batchFailed_ = false;
    showOriginal_ = false;
    for (int row = 0; row < images_.size(); ++row) {
        setCell(row, 1, "待识别");
        for (int column = 2; column < 5; ++column)
            setCell(row, column, {});
    }
    status_->setText(QString("正在加载模型 %1…").arg(QFileInfo(weights_).fileName()));
    refreshPreview();
    worker_ = new BatchWorker({images_, weights_, output_, float(confidence_->value())}, this);
    connect(worker_, &BatchWorker::reportReady, this, [this](const QString &path) {
        batchOutput_ = path;
        refreshControls();
    });
    connect(worker_, &BatchWorker::imageStarted, this, [this](int row) {
        setCell(row, 1, "识别中");
        if (!worker_->isInterruptionRequested())
            status_->setText(QString("正在识别第 %1 张，共 %2 张").arg(row + 1).arg(images_.size()));
    });
    connect(worker_, &BatchWorker::imageDone, this, &MainWindow::recordResult);
    connect(worker_, &BatchWorker::failed, this, [this](const QString &error) {
        batchFailed_ = true;
        status_->setText("批次中断，请检查模型或输出目录");
        if (!closeAfterBatch_)
            QMessageBox::warning(this, "识别批次中断", error);
    });
    connect(worker_, &QThread::finished, this, &MainWindow::finishBatch);
    stop_->setEnabled(true);
    refreshControls();
    worker_->start();
}

void MainWindow::recordResult(int row, const ImageResult &result) {
    results_.insert(row, result);
    if (result.error.isEmpty()) {
        healthyLeaves_ += result.healthy;
        yellowedLeaves_ += result.yellowed;
        setCell(row, 1, "完成");
        setCell(row, 2, QString::number(result.healthy));
        setCell(row, 3, QString::number(result.yellowed));
        setCell(row, 4, result.ratio().isEmpty() ? "—" : result.ratio());
    } else {
        setCell(row, 1, "失败", result.error);
    }
    refreshMetrics();
    if (row == table_->currentRow())
        refreshPreview();
}

void MainWindow::stopBatch() {
    worker_->requestInterruption();
    stop_->setEnabled(false);
    status_->setText("正在停止，等待当前操作完成…");
}

void MainWindow::finishBatch() {
    worker_->deleteLater();
    worker_ = nullptr;
    const auto errors = std::count_if(results_.cbegin(), results_.cend(), [](const ImageResult &r) { return !r.error.isEmpty(); });
    const auto pending = images_.size() - results_.size();
    for (int row = int(results_.size()); row < images_.size(); ++row)
        setCell(row, 1, "未处理");
    if (!batchFailed_)
        status_->setText(QString("%1 · 成功 %2 张 · 失败 %3 张 · 未处理 %4 张")
                         .arg(pending ? "已停止" : "批次完成").arg(results_.size() - errors).arg(errors).arg(pending));
    refreshControls();
    if (closeAfterBatch_)
        close();
}

void MainWindow::closeEvent(QCloseEvent *event) {
    if (worker_) {
        closeAfterBatch_ = true;
        stopBatch();
        event->ignore();
    } else {
        QMainWindow::closeEvent(event);
    }
}
