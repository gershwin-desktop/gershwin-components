# SPDX-License-Identifier: BSD-2-Clause
# Qt 5 or 6 (first argument) widget program with the menus the module has to hand over.
import sys
Q = sys.argv[1]
if Q == "5":
    from PyQt5.QtWidgets import QApplication, QMainWindow, QAction
    from PyQt5.QtCore import QTimer
    from PyQt5.QtGui import QKeySequence
else:
    from PyQt6.QtWidgets import QApplication, QMainWindow
    from PyQt6.QtGui import QAction, QKeySequence
    from PyQt6.QtCore import QTimer
app = QApplication(sys.argv)
w = QMainWindow()
bar = w.menuBar()
file = bar.addMenu("&File")
op = file.addAction("&Open")
op.setShortcut(QKeySequence("Ctrl+O"))
def opened():
    print("MENUBAR VISIBLE", bar.isVisible(), flush=True)
    print("ACTIVATED Open", flush=True)
    app.quit()
op.triggered.connect(opened)
file.addSeparator()
wrap = file.addAction("Wrap"); wrap.setCheckable(True); wrap.setChecked(True)
off = file.addAction("Disabled"); off.setEnabled(False)
count = [0]
recent = bar.addMenu("Recent")
def fill():
    count[0] += 1
    recent.clear()
    recent.addAction("Recent %d" % count[0])
recent.aboutToShow.connect(fill)
w.show()
QTimer.singleShot(int(sys.argv[2]) * 1000 if len(sys.argv) > 2 else 10000, app.quit)
app.exec() if Q == "6" else app.exec_()
