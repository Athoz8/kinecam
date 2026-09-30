import os, signal, subprocess, sys
from pathlib import Path
from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QAction, QColor, QIcon, QImage, QPainter, QPixmap
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

BIN = Path(__file__).resolve().parent.parent / "camera" / "kinect2v4l2_multi"
DEVS = ["/dev/video10", "/dev/video11", "/dev/video12", "/dev/video13"]


def make_icon(color):
    pm = QPixmap(64, 64)
    pm.fill(QColor(0, 0, 0, 0))
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setBrush(QColor(color))
    p.setPen(QColor("#222222"))
    p.drawEllipse(6, 6, 52, 52)
    p.setBrush(QColor("#ffffff"))
    p.drawEllipse(24, 24, 16, 16)
    p.end()
    return QIcon(pm)


LOGO = Path(__file__).resolve().parent.parent / "assets" / "logo.png"


def load_icons():
    pm = QPixmap(str(LOGO))
    if pm.isNull():
        return make_icon("#2ecc71"), make_icon("#7f8c8d")
    pm = pm.scaled(128, 128, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    img = pm.toImage().convertToFormat(QImage.Format.Format_ARGB32)
    for y in range(img.height()):
        for x in range(img.width()):
            c = img.pixelColor(x, y)
            g = int(0.299 * c.red() + 0.587 * c.green() + 0.114 * c.blue())
            img.setPixelColor(x, y, QColor(g, g, g, int(c.alpha() * 0.6)))
    return QIcon(pm), QIcon(QPixmap.fromImage(img))


class Tray:
    def __init__(self, app):
        self.app = app
        self.proc = None
        self.on_icon, self.off_icon = load_icons()
        self.tray = QSystemTrayIcon(self.off_icon)
        self.menu = QMenu()
        self.toggle = QAction("Start Kinect cameras")
        self.toggle.triggered.connect(self.on_toggle)
        self.quit = QAction("Quit (stop cameras)")
        self.quit.triggered.connect(app.quit)
        self.menu.addAction(self.toggle)
        self.menu.addSeparator()
        self.menu.addAction(self.quit)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.on_activated)
        self.tray.show()
        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(1000)
        app.aboutToQuit.connect(self.stop)

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        if self.running():
            return
        env = dict(os.environ, LIBVA_DRIVER_NAME="nonexistent")
        self.proc = subprocess.Popen([str(BIN)] + DEVS, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.refresh()

    def stop(self):
        if self.proc is not None:
            if self.proc.poll() is None:
                self.proc.send_signal(signal.SIGINT)
                try:
                    self.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
            self.proc = None
        self.refresh()

    def on_toggle(self):
        if self.running():
            self.stop()
        else:
            self.start()

    def on_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.on_toggle()

    def refresh(self):
        if self.proc is not None and self.proc.poll() is not None:
            self.proc = None
        if self.running():
            self.tray.setIcon(self.on_icon)
            self.tray.setToolTip("Kinect cameras: running")
            self.toggle.setText("Stop Kinect cameras")
        else:
            self.tray.setIcon(self.off_icon)
            self.tray.setToolTip("Kinect cameras: stopped")
            self.toggle.setText("Start Kinect cameras")


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    signal.signal(signal.SIGINT, lambda *a: app.quit())
    signal.signal(signal.SIGTERM, lambda *a: app.quit())
    t = Tray(app)
    t.start()
    sys.exit(app.exec())


main()
