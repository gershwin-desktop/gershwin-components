# SPDX-License-Identifier: BSD-2-Clause
# Qt 5 or 6 (first argument) program whose menu bar is in a plain QWidget, not a QMainWindow.
import sys
Q = sys.argv[1]
if Q == "5":
    from PyQt5.QtWidgets import QApplication, QWidget, QVBoxLayout, QMenuBar, QLabel
    from PyQt5.QtCore import QTimer
else:
    from PyQt6.QtWidgets import QApplication, QWidget, QVBoxLayout, QMenuBar, QLabel
    from PyQt6.QtCore import QTimer
app = QApplication(sys.argv)
w = QWidget()
layout = QVBoxLayout(w)
bar = QMenuBar()
menu = bar.addMenu("&Plain")
act = menu.addAction("Plain Item")
def triggered():
    print("MENUBAR VISIBLE", bar.isVisible(), flush=True)
    print("ACTIVATED Plain", flush=True)
    app.quit()
act.triggered.connect(triggered)
layout.addWidget(bar)
layout.addWidget(QLabel("body"))
w.show()
QTimer.singleShot(int(sys.argv[2]) * 1000 if len(sys.argv) > 2 else 10000, app.quit)
app.exec() if Q == "6" else app.exec_()
