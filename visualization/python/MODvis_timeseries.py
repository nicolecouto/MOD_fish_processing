#!/usr/bin/env python3
"""
MODvis_timeseries.py

Browse a folder of *.mat files (L0, L1, L2, or Profile - any file whose
structures carry a dnum field) and plot up to 6 signals simultaneously.
Python/PyQt5 + matplotlib replacement for MODvis_timeseries.m.
Formerly named L0ExplorerApp.py.

Key advantage: ax.set_position() in matplotlib is absolute and permanent —
no layout manager can override it, so all 6 axes have identical left edges
at all times, even after zoom/pan.

Usage:
    python MODvis_timeseries.py [folder]

Dependencies:
    pip install PyQt5 matplotlib scipy numpy
"""

import sys
import os
import numpy as np
from datetime import datetime
from pathlib import Path

from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QHBoxLayout, QVBoxLayout,
    QLabel, QPushButton, QListWidget, QComboBox, QLineEdit,
    QCheckBox, QSlider, QSizePolicy, QFileDialog, QMessageBox,
    QAbstractItemView, QFrame,
)
from PyQt5.QtCore import Qt

import matplotlib
matplotlib.use('Qt5Agg')
from matplotlib.figure import Figure
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg as FigureCanvas
from matplotlib.backends.backend_qt5agg import NavigationToolbar2QT as NavigationToolbar
import matplotlib.dates as mdates

try:
    from scipy.io import loadmat
    SCIPY_OK = True
except ImportError:
    SCIPY_OK = False

# ── Constants ─────────────────────────────────────────────────────────────────

# Identical rect for ALL six axes: [left, bottom, width, height] in figure coords.
# Because we use fig.add_axes() with an explicit rect and call set_position()
# after every cla(), these values are permanent — no layout manager can fight us.
AXES_RECT = [0.14, 0.15, 0.82, 0.78]

# MATLAB datenum → matplotlib datenum offset.
# MATLAB datenum(2000,1,1) == 730486; compute matplotlib's equivalent at runtime
# so the code is correct regardless of matplotlib version / epoch setting.
_MATLAB_MPL_OFFSET = mdates.date2num(datetime(2000, 1, 1)) - 730486.0

N_ROWS = 6

# Preferred ordering of top-level struct names
STRUCT_PREF = ["epsi", "ctd", "gps", "alt", "act", "seg", "spec",
               "fluor", "ttv", "vnav", "isap", "apf"]

# Default per-row selections on startup
DEFAULT_STRUCTS = ["epsi", "epsi", "epsi", "epsi", "ctd",   "ctd"]
DEFAULT_SIGNALS = ["t1_volt", "t2_volt", "s1_volt", "s2_volt", "z", "T"]

# y-axis is reversed for these signal keys (depth / pressure)
REVERSE_Y_KEYS = {"p", "p_raw", "z"}

SIGNAL_COLORS = {
    "a1_g":     (129/255,  27/255, 112/255),
    "a2_g":     (235/255,  64/255,  61/255),
    "a3_g":     (245/255, 199/255, 118/255),
    "s1_volt":  ( 60/255, 134/255,  76/255),
    "s2_volt":  (173/255, 215/255, 136/255),
    "t1_volt":  ( 29/255,  78/255, 140/255),
    "t2_volt":  ( 78/255, 173/255, 173/255),
    "s1_count": ( 60/255, 134/255,  76/255),
    "s2_count": (173/255, 215/255, 136/255),
    "t1_count": ( 29/255,  78/255, 140/255),
    "t2_count": ( 78/255, 173/255, 173/255),
    "P":        (0.0,    0.0,    0.0   ),
    "P_raw":    (0.0,    0.0,    0.0   ),
    "dPdt":     (0.4,    0.4,    0.4   ),
    "T":        (0.8941, 0.1020, 0.1098),
    "T_raw":    (0.8941, 0.1020, 0.1098),
    "S":        (0.2157, 0.4941, 0.7216),
    "S_raw":    (0.2157, 0.4941, 0.7216),
    "alt":      (0.0,    0.0,    1.0   ),
    "gyro1":    (129/255,  27/255, 112/255),
    "gyro2":    (235/255,  64/255,  61/255),
    "gyro3":    (245/255, 199/255, 118/255),
    "compass1": (0.0,    0.0,    0.543 ),
    "compass2": (185/255, 38/255,  26/255),
    "compass3": (0.0,    0.0,    0.0   ),
    "chla":     (0.1059, 0.6196, 0.4667),
    "bb":       (0.4000, 0.6510, 0.1176),
    "fdom":     (0.9020, 0.6706, 0.0078),
    "ucond":    (0.7373, 0.5020, 0.7412),
    "channel1": (0.3686, 0.3098, 0.6353),
    "channel2": (0.3127, 0.6971, 0.6726),
    "channel3": (0.7616, 0.9058, 0.6299),
    "channel4": (0.9500, 0.9500, 0.7116),
    "channel5": (0.9942, 0.7583, 0.4312),
    "channel6": (0.9288, 0.3634, 0.2749),
    "channel7": (0.6196, 0.0039, 0.2588),
}
DEFAULT_COLOR = (0.3, 0.3, 0.3)


# ── .mat loading ───────────────────────────────────────────────────────────────

def load_mat_file(filepath):
    """Load a .mat file; return nested plain-Python dicts + numpy arrays."""
    if not SCIPY_OK:
        raise ImportError("scipy not found — install with:  pip install scipy")
    raw = loadmat(str(filepath), squeeze_me=True, struct_as_record=False)
    return {k: _convert_mat(v) for k, v in raw.items() if not k.startswith('_')}


def _convert_mat(obj):
    """Recursively convert scipy mat_struct objects to plain dicts."""
    if hasattr(obj, '_fieldnames'):                          # mat_struct
        return {f: _convert_mat(getattr(obj, f, None)) for f in obj._fieldnames}
    if isinstance(obj, np.ndarray) and obj.ndim == 0 and obj.dtype.kind == 'O':
        return _convert_mat(obj.item())                      # 0-d object array
    return obj


def matlab_dnum_to_mpl(dnum):
    """Convert MATLAB datenum scalar or array to matplotlib datenum."""
    return np.asarray(dnum, dtype=float) + _MATLAB_MPL_OFFSET


# ── Data helpers ───────────────────────────────────────────────────────────────

def get_by_dot_path(d, path):
    """Access a nested dict using a dot-separated path, e.g. 'chan1.voltage'."""
    val = d
    for part in path.split('.'):
        if not isinstance(val, dict) or part not in val:
            raise KeyError(f"Key '{part}' not found in path '{path}'")
        val = val[part]
    return val


def list_numeric_signals(d, prefix=''):
    """Recursively list dot-paths of numeric 1-D vector fields."""
    signals = []
    if not isinstance(d, dict):
        return signals
    for key, val in d.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(val, dict):
            signals.extend(list_numeric_signals(val, path))
        elif (isinstance(val, np.ndarray) and val.ndim == 1
              and val.size > 1 and np.issubdtype(val.dtype, np.number)):
            signals.append(path)
    return signals


def _scan_for_dnum(d):
    """Recursively search a dict for a usable 'dnum' field (≥2 finite values)."""
    if not isinstance(d, dict):
        return None
    for key, val in d.items():
        if key.lower() == 'dnum' and isinstance(val, np.ndarray):
            arr = val.ravel()
            arr = arr[np.isfinite(arr)]
            if arr.size >= 2:
                return arr
        result = _scan_for_dnum(val)
        if result is not None:
            return result
    return None


def find_dnum(struct_dict, top_data):
    """
    Find a dnum vector for the given struct.
    Search order: struct.dnum → top-level dnum → auto-scan.
    Returns (dnum_as_mpl_datenum, source_string) or (None, '').
    """
    def _try(d, label):
        if isinstance(d, dict) and 'dnum' in d:
            v = d['dnum']
            if isinstance(v, np.ndarray) and v.ndim == 1:
                arr = v[np.isfinite(v)]
                if arr.size >= 2:
                    return matlab_dnum_to_mpl(arr), label
        return None, ''

    result, src = _try(struct_dict, 'struct.dnum')
    if result is not None:
        return result, src

    result, src = _try(top_data, 'top-level dnum')
    if result is not None:
        return result, src

    arr = _scan_for_dnum(struct_dict) or _scan_for_dnum(top_data)
    if arr is not None:
        return matlab_dnum_to_mpl(arr), 'auto-scanned dnum'

    return None, ''


def get_struct_candidates(data):
    """Return ordered list of top-level struct (dict) keys."""
    structs = [k for k, v in data.items()
               if isinstance(v, dict) and k != 'raw_file_info']
    ordered = [p for p in STRUCT_PREF if p in structs]
    rest    = [s for s in structs if s not in ordered]
    return ordered + rest


def signal_color(sig_path):
    return SIGNAL_COLORS.get(sig_path.split('.')[-1], DEFAULT_COLOR)


def should_reverse_y(sig_path):
    return sig_path.split('.')[-1].lower() in REVERSE_Y_KEYS


# ── Compact navigation toolbar ─────────────────────────────────────────────────

class _CompactToolbar(NavigationToolbar):
    """NavigationToolbar with only Home / Pan / Zoom, reduced height."""
    toolitems = [t for t in NavigationToolbar.toolitems
                 if t[0] in ('Home', 'Pan', 'Zoom')]

    def __init__(self, canvas, parent):
        super().__init__(canvas, parent)
        self.setMaximumHeight(26)
        self.setStyleSheet("QToolBar { padding: 0px; spacing: 1px; }")


# ── RowWidget ──────────────────────────────────────────────────────────────────

class RowWidget(QWidget):
    """
    One row of the right panel: a matplotlib FigureCanvas (left) +
    struct/signal dropdowns, y-limit controls, fix-y checkbox (right).
    """

    def __init__(self, row_idx, parent=None):
        super().__init__(parent)
        self.row_idx = row_idx

        # ── Figure with EXPLICIT axes position ──────────────────────────────
        # fig.add_axes(rect) bypasses any subplot/layout manager.
        # After every ax.cla() we call ax.set_position(AXES_RECT) again —
        # that's literally all it takes to keep all axes perfectly aligned.
        self.fig = Figure(figsize=(8, 1.5), tight_layout=False)
        self.fig.patch.set_facecolor('#ECECEC')
        self.ax  = self.fig.add_axes(AXES_RECT)
        self.ax.set_facecolor('white')
        self.ax.tick_params(labelsize=9)
        self.ax.grid(True, linewidth=0.4, alpha=0.6)

        self.canvas = FigureCanvas(self.fig)
        self.canvas.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.canvas.setMinimumHeight(80)

        self.toolbar = _CompactToolbar(self.canvas, self)

        # ── Qt controls ─────────────────────────────────────────────────────
        self.struct_combo = QComboBox()
        self.struct_combo.setSizeAdjustPolicy(
            QComboBox.AdjustToMinimumContentsLengthWithIcon)

        self.signal_combo = QComboBox()
        self.signal_combo.setSizeAdjustPolicy(
            QComboBox.AdjustToMinimumContentsLengthWithIcon)
        self.signal_combo.setToolTip(
            "Signal path (supports nested fields, e.g. chan1.voltage)")

        self.ymin_edit = QLineEdit()
        self.ymin_edit.setPlaceholderText("min")
        self.ymin_edit.setMaximumWidth(68)

        self.ymax_edit = QLineEdit()
        self.ymax_edit.setPlaceholderText("max")
        self.ymax_edit.setMaximumWidth(68)

        self.ylock_check = QCheckBox("fix y")

        # ── Layout ──────────────────────────────────────────────────────────
        outer = QHBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(4)

        # Canvas + toolbar stacked vertically
        canvas_col = QVBoxLayout()
        canvas_col.setContentsMargins(0, 0, 0, 0)
        canvas_col.setSpacing(0)
        canvas_col.addWidget(self.toolbar)
        canvas_col.addWidget(self.canvas, stretch=1)
        outer.addLayout(canvas_col, stretch=1)

        # Right control panel (fixed width)
        ctrl = QWidget()
        ctrl.setFixedWidth(210)
        ctrl_vbox = QVBoxLayout(ctrl)
        ctrl_vbox.setContentsMargins(4, 4, 4, 4)
        ctrl_vbox.setSpacing(5)

        def _lbl(text):
            l = QLabel(text)
            l.setFixedWidth(44)
            return l

        r1 = QHBoxLayout()
        r1.addWidget(_lbl("Struct"))
        r1.addWidget(self.struct_combo, 1)
        ctrl_vbox.addLayout(r1)

        r2 = QHBoxLayout()
        r2.addWidget(_lbl("Signal"))
        r2.addWidget(self.signal_combo, 1)
        ctrl_vbox.addLayout(r2)

        r3 = QHBoxLayout()
        r3.addWidget(_lbl("Y-lim"))
        r3.addWidget(self.ymin_edit)
        r3.addWidget(self.ymax_edit)
        ctrl_vbox.addLayout(r3)

        r4 = QHBoxLayout()
        r4.addStretch()
        r4.addWidget(self.ylock_check)
        ctrl_vbox.addLayout(r4)

        ctrl_vbox.addStretch()
        outer.addWidget(ctrl)

    def ymin(self):
        try:    return float(self.ymin_edit.text())
        except: return None

    def ymax(self):
        try:    return float(self.ymax_edit.text())
        except: return None


# ── Main window ────────────────────────────────────────────────────────────────

class MODvis_timeseries(QMainWindow):

    def __init__(self, folder=None):
        super().__init__()
        self.setWindowTitle("L0 Explorer")
        self.resize(1400, 950)

        # ── application state ──────────────────────────────────────────────
        self.folder        = str(Path(folder).resolve()) if folder else str(Path.cwd())
        self.files         = []
        self.current_data  = {}
        self.current_file  = ""

        self.last_struct   = list(DEFAULT_STRUCTS)
        self.last_signal   = list(DEFAULT_SIGNALS)

        self.use_xwindow   = False
        self.xwindow_len   = 10.0    # seconds
        self.xwin_fraction = 0.0
        self.profile_tmin  = 0.0     # matplotlib datenum
        self.profile_tmax  = 0.0

        self.use_line      = False
        self._syncing_xlim = False   # re-entrancy guard for xlim linking

        self._build_ui()
        self._setup_xlim_linking()
        self.load_folder(self.folder)

    # ── UI construction ────────────────────────────────────────────────────────

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QHBoxLayout(central)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(8)

        # ── LEFT PANEL ────────────────────────────────────────────────────
        left = QWidget()
        left.setFixedWidth(240)
        lv = QVBoxLayout(left)
        lv.setContentsMargins(0, 0, 0, 0)
        lv.setSpacing(6)

        self.folder_lbl = QLabel(self.folder)
        self.folder_lbl.setWordWrap(True)
        self.folder_lbl.setAlignment(Qt.AlignTop | Qt.AlignLeft)
        self.folder_lbl.setMaximumHeight(52)
        lv.addWidget(self.folder_lbl)

        btn_choose = QPushButton("Choose folder…")
        btn_choose.clicked.connect(self._choose_folder)
        lv.addWidget(btn_choose)

        lv.addWidget(QLabel("L0 files (*.mat):"))

        btn_refresh = QPushButton("Refresh list")
        btn_refresh.clicked.connect(lambda: self.load_folder(self.folder))
        lv.addWidget(btn_refresh)

        self.file_list = QListWidget()
        self.file_list.setSelectionMode(QAbstractItemView.SingleSelection)
        self.file_list.itemClicked.connect(self._on_file_item_clicked)
        lv.addWidget(self.file_list, stretch=1)

        # Divider
        sep = QFrame()
        sep.setFrameShape(QFrame.HLine)
        sep.setFrameShadow(QFrame.Sunken)
        lv.addWidget(sep)

        # X-window: length + Full view
        xw_row = QHBoxLayout()
        xw_lbl = QLabel("X win (s):")
        xw_lbl.setFixedWidth(68)
        xw_row.addWidget(xw_lbl)
        self.xwin_len_edit = QLineEdit()
        self.xwin_len_edit.setPlaceholderText("sec")
        self.xwin_len_edit.returnPressed.connect(self._on_xwin_len_changed)
        xw_row.addWidget(self.xwin_len_edit, 1)
        btn_full = QPushButton("Full view")
        btn_full.setFixedWidth(62)
        btn_full.clicked.connect(self._on_xwin_reset)
        xw_row.addWidget(btn_full)
        lv.addLayout(xw_row)

        # Lines checkbox + position slider
        sl_row = QHBoxLayout()
        self.line_check = QCheckBox("Lines")
        self.line_check.setFixedWidth(58)
        self.line_check.stateChanged.connect(self._on_style_changed)
        sl_row.addWidget(self.line_check)
        self.xwin_slider = QSlider(Qt.Horizontal)
        self.xwin_slider.setRange(0, 1000)
        self.xwin_slider.setValue(0)
        self.xwin_slider.setEnabled(False)
        self.xwin_slider.valueChanged.connect(self._on_xwin_slider)
        sl_row.addWidget(self.xwin_slider, 1)
        lv.addLayout(sl_row)

        layout.addWidget(left)

        # ── RIGHT PANEL: 6 row widgets ────────────────────────────────────
        right = QWidget()
        rv = QVBoxLayout(right)
        rv.setContentsMargins(0, 0, 0, 0)
        rv.setSpacing(3)

        self.rows: list[RowWidget] = []
        for i in range(N_ROWS):
            rw = RowWidget(i)
            # Wire signals — use default-argument capture to avoid closure gotcha
            rw.struct_combo.currentTextChanged.connect(
                lambda _text, idx=i: self._on_struct_changed(idx))
            rw.signal_combo.currentTextChanged.connect(
                lambda _text, idx=i: self._on_signal_changed(idx))
            rw.ymin_edit.returnPressed.connect(
                lambda idx=i: self._plot_row(idx))
            rw.ymax_edit.returnPressed.connect(
                lambda idx=i: self._plot_row(idx))
            rw.ylock_check.stateChanged.connect(
                lambda _s, idx=i: self._plot_row(idx))
            self.rows.append(rw)
            rv.addWidget(rw, stretch=1)

        layout.addWidget(right, stretch=1)

    # ── X-axis linking ─────────────────────────────────────────────────────────

    def _setup_xlim_linking(self):
        for rw in self.rows:
            rw.ax.callbacks.connect('xlim_changed', self._on_xlim_changed)

    def _reconnect_xlim(self, rw: RowWidget):
        """Re-attach xlim callback after ax.cla() clears it."""
        rw.ax.callbacks.connect('xlim_changed', self._on_xlim_changed)

    def _on_xlim_changed(self, changed_ax):
        if self._syncing_xlim:
            return
        self._syncing_xlim = True
        try:
            lims = changed_ax.get_xlim()
            for rw in self.rows:
                if rw.ax is not changed_ax:
                    rw.ax.set_xlim(lims[0], lims[1], emit=False)
                    rw.canvas.draw_idle()
        finally:
            self._syncing_xlim = False

    # ── Folder / file loading ──────────────────────────────────────────────────

    def _choose_folder(self):
        d = QFileDialog.getExistingDirectory(self, "Select L0 folder", self.folder)
        if d:
            self.load_folder(d)

    def load_folder(self, folder):
        folder = str(Path(folder).resolve())
        if not os.path.isdir(folder):
            QMessageBox.warning(self, "Folder error", f"Folder not found:\n{folder}")
            return
        self.folder = folder
        self.folder_lbl.setText(folder)

        mat_files = sorted(Path(folder).glob("*.mat"))
        self.files = [f.name for f in mat_files]
        self.file_list.clear()

        if not self.files:
            self.current_data = {}
            self.current_file = ""
            self.setWindowTitle("L0 Explorer (no files)")
            self._clear_all()
            return

        self.file_list.addItems(self.files)
        self.file_list.setCurrentRow(0)
        self._load_file(self.files[0])

    def _on_file_item_clicked(self, item):
        self._load_file(item.text())

    def _load_file(self, filename):
        filepath = os.path.join(self.folder, filename)
        try:
            data = load_mat_file(filepath)
        except Exception as exc:
            QMessageBox.warning(self, "Load error",
                                f"Failed to load:\n{filepath}\n\n{exc}")
            return

        # Unwrap Profile wrapper (profiles directory format)
        if 'Profile' in data and isinstance(data['Profile'], dict):
            data = data['Profile']

        self.current_data = data
        self.current_file = filename

        # Window title — prefer raw_file_info.filename if present
        title = filename
        rfi = data.get('raw_file_info', {})
        if isinstance(rfi, dict):
            fn = rfi.get('filename', '')
            if fn and isinstance(fn, (str, np.ndarray)):
                try:    title = str(fn)
                except: pass
        self.setWindowTitle(f"L0 Explorer — {title}")

        # Time range (converted to matplotlib dnum)
        global_dnum = _scan_for_dnum(data)
        if global_dnum is not None:
            mpl = matlab_dnum_to_mpl(global_dnum)
            mpl = mpl[np.isfinite(mpl)]
            if mpl.size >= 2:
                self.profile_tmin = float(mpl.min())
                self.profile_tmax = float(mpl.max())
            else:
                self.profile_tmin = self.profile_tmax = 0.0
        else:
            self.profile_tmin = self.profile_tmax = 0.0

        structs = get_struct_candidates(data)

        # Block all dropdown signals while we update them
        for rw in self.rows:
            rw.struct_combo.blockSignals(True)
            rw.signal_combo.blockSignals(True)

        for i, rw in enumerate(self.rows):
            rw.struct_combo.clear()
            rw.struct_combo.addItems(structs)

            if not structs:
                rw.signal_combo.clear()
                continue

            # Restore last struct
            want_s = self.last_struct[i] if i < len(self.last_struct) else ''
            if want_s and want_s in structs:
                rw.struct_combo.setCurrentText(want_s)
            else:
                rw.struct_combo.setCurrentIndex(0)
                self.last_struct[i] = rw.struct_combo.currentText()

            # Populate signals for chosen struct
            signals = self._signals_for(rw.struct_combo.currentText())
            rw.signal_combo.clear()
            rw.signal_combo.addItems(signals)

            # Restore last signal
            want_sig = self.last_signal[i] if i < len(self.last_signal) else ''
            if want_sig and want_sig in signals:
                rw.signal_combo.setCurrentText(want_sig)
            elif signals:
                rw.signal_combo.setCurrentIndex(0)
                self.last_signal[i] = rw.signal_combo.currentText()

        for rw in self.rows:
            rw.struct_combo.blockSignals(False)
            rw.signal_combo.blockSignals(False)

        # Set initial x range on all axes before plotting
        if self.profile_tmin < self.profile_tmax:
            self._syncing_xlim = True
            try:
                for rw in self.rows:
                    rw.ax.set_xlim(self.profile_tmin, self.profile_tmax, emit=False)
            finally:
                self._syncing_xlim = False

        for i in range(N_ROWS):
            self._plot_row(i)

        if self.use_xwindow:
            self._apply_xwindow()

    def _signals_for(self, struct_name):
        """List numeric signal paths for a top-level struct, excluding dnum."""
        d = self.current_data.get(struct_name)
        if not isinstance(d, dict):
            return []
        sigs = list_numeric_signals(d)
        return [s for s in sigs if s.split('.')[-1].lower() != 'dnum']

    def _clear_all(self):
        for rw in self.rows:
            rw.struct_combo.clear()
            rw.signal_combo.clear()
            rw.ax.cla()
            rw.ax.set_position(AXES_RECT)
            self._reconnect_xlim(rw)
            rw.canvas.draw_idle()

    # ── Dropdown callbacks ─────────────────────────────────────────────────────

    def _on_struct_changed(self, idx):
        if not self.current_data:
            return
        rw = self.rows[idx]
        name = rw.struct_combo.currentText()
        if not name:
            return
        self.last_struct[idx] = name

        sigs = self._signals_for(name)
        rw.signal_combo.blockSignals(True)
        rw.signal_combo.clear()
        rw.signal_combo.addItems(sigs)
        rw.signal_combo.blockSignals(False)

        if sigs:
            rw.signal_combo.setCurrentIndex(0)
            self.last_signal[idx] = rw.signal_combo.currentText()
            self._plot_row(idx)

    def _on_signal_changed(self, idx):
        if not self.current_data:
            return
        rw = self.rows[idx]
        sig = rw.signal_combo.currentText()
        if sig:
            self.last_signal[idx] = sig
            self._plot_row(idx)

    # ── Core plotting ──────────────────────────────────────────────────────────

    def _plot_row(self, idx):
        if not self.current_data:
            return

        rw       = self.rows[idx]
        top_name = rw.struct_combo.currentText()
        sig_path = rw.signal_combo.currentText()

        if not top_name or not sig_path:
            return
        if top_name not in self.current_data:
            return

        top_struct = self.current_data[top_name]

        # Time vector
        dnum_mpl, dnum_src = find_dnum(top_struct, self.current_data)
        if dnum_mpl is None or dnum_mpl.size < 2:
            return

        # Signal vector
        try:
            y = get_by_dot_path(top_struct, sig_path)
        except (KeyError, TypeError):
            return

        if not isinstance(y, np.ndarray) or y.size == 0:
            return
        y = np.asarray(y, dtype=float).ravel()

        n        = min(len(dnum_mpl), len(y))
        dnum_mpl = dnum_mpl[:n]
        y        = y[:n]

        # Remember current x-limits so we can restore them
        xlim_before = rw.ax.get_xlim()
        keep_xlim   = (xlim_before[1] > xlim_before[0]
                       and xlim_before[0] > 100)   # valid mpl date > 100

        # ── Clear and reset axes ──────────────────────────────────────────
        rw.ax.cla()
        rw.ax.set_position(AXES_RECT)          # ← the whole point of this rewrite
        self._reconnect_xlim(rw)               # cla() clears callbacks; reconnect
        rw.ax.tick_params(labelsize=9)
        rw.ax.grid(True, linewidth=0.4, alpha=0.6)

        # ── Plot ──────────────────────────────────────────────────────────
        color = signal_color(sig_path)
        if self.use_line:
            rw.ax.plot(dnum_mpl, y, '-',  color=color, linewidth=0.8)
        else:
            rw.ax.plot(dnum_mpl, y, '.',  color=color, markersize=2)

        # ── X-axis date formatting ────────────────────────────────────────
        locator   = mdates.AutoDateLocator(minticks=3, maxticks=6)
        formatter = mdates.AutoDateFormatter(locator)
        rw.ax.xaxis.set_major_locator(locator)
        rw.ax.xaxis.set_major_formatter(formatter)
        # Rotate tick labels in-place (do NOT use fig.autofmt_xdate — it
        # calls subplots_adjust which would override our set_position)
        rw.ax.tick_params(axis='x', labelrotation=25, labelsize=8)

        # ── Labels ───────────────────────────────────────────────────────
        rw.ax.set_xlabel(f"time  ({dnum_src})", fontsize=8, labelpad=1)
        rw.ax.set_ylabel(f"{top_name}.{sig_path}", fontsize=8, labelpad=2)

        # ── Y direction ───────────────────────────────────────────────────
        if should_reverse_y(sig_path):
            rw.ax.invert_yaxis()

        # ── Restore / set x-limits ────────────────────────────────────────
        if keep_xlim:
            rw.ax.set_xlim(xlim_before[0], xlim_before[1], emit=False)
        elif self.profile_tmin < self.profile_tmax:
            rw.ax.set_xlim(self.profile_tmin, self.profile_tmax, emit=False)

        # ── Fixed y-limits ────────────────────────────────────────────────
        if rw.ylock_check.isChecked():
            lo, hi = rw.ymin(), rw.ymax()
            if lo is not None and hi is not None and hi > lo:
                rw.ax.set_ylim(lo, hi)

        # ── X-window ─────────────────────────────────────────────────────
        if self.use_xwindow and self.profile_tmax > self.profile_tmin:
            win_days = self.xwindow_len / 86400.0
            dur      = self.profile_tmax - self.profile_tmin
            if win_days < dur:
                ws = self.profile_tmin + self.xwin_fraction * dur
                ws = max(ws, self.profile_tmin)
                ws = min(ws, self.profile_tmax - win_days)
                rw.ax.set_xlim(ws, ws + win_days, emit=False)

        rw.canvas.draw_idle()

    # ── Plot style ─────────────────────────────────────────────────────────────

    def _on_style_changed(self, _state):
        self.use_line = self.line_check.isChecked()
        for i in range(N_ROWS):
            self._plot_row(i)

    # ── X-window controls ──────────────────────────────────────────────────────

    def _on_xwin_len_changed(self):
        text = self.xwin_len_edit.text().strip()
        try:
            val = float(text)
            if val <= 0:
                raise ValueError
        except ValueError:
            self._on_xwin_reset()
            return
        self.xwindow_len = val
        self.use_xwindow = True
        self.xwin_slider.setEnabled(True)
        self._apply_xwindow()

    def _on_xwin_slider(self, slider_val):
        if not self.use_xwindow:
            return
        self.xwin_fraction = slider_val / 1000.0
        self._apply_xwindow()

    def _on_xwin_reset(self):
        self.use_xwindow   = False
        self.xwin_fraction = 0.0
        self.xwin_slider.blockSignals(True)
        self.xwin_slider.setValue(0)
        self.xwin_slider.blockSignals(False)
        self.xwin_slider.setEnabled(False)
        self.xwin_len_edit.clear()
        if self.profile_tmin < self.profile_tmax:
            self._syncing_xlim = True
            try:
                for rw in self.rows:
                    rw.ax.set_xlim(self.profile_tmin, self.profile_tmax, emit=False)
                    rw.canvas.draw_idle()
            finally:
                self._syncing_xlim = False

    def _apply_xwindow(self):
        if not self.use_xwindow:
            return
        if not (self.profile_tmax > self.profile_tmin):
            return

        win_days = self.xwindow_len / 86400.0
        dur      = self.profile_tmax - self.profile_tmin

        if win_days >= dur:
            # Window covers the whole profile — same as full view
            self._syncing_xlim = True
            try:
                for rw in self.rows:
                    rw.ax.set_xlim(self.profile_tmin, self.profile_tmax, emit=False)
                    rw.canvas.draw_idle()
            finally:
                self._syncing_xlim = False
            self.xwin_slider.blockSignals(True)
            self.xwin_slider.setValue(0)
            self.xwin_slider.blockSignals(False)
            return

        max_frac = 1.0 - win_days / dur
        frac     = min(max(self.xwin_fraction, 0.0), max_frac)
        ws       = self.profile_tmin + frac * dur

        self._syncing_xlim = True
        try:
            for rw in self.rows:
                rw.ax.set_xlim(ws, ws + win_days, emit=False)
                rw.canvas.draw_idle()
        finally:
            self._syncing_xlim = False

        self.xwin_slider.blockSignals(True)
        self.xwin_slider.setValue(int(frac * 1000))
        self.xwin_slider.blockSignals(False)


# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else None
    app    = QApplication(sys.argv)
    app.setStyle('Fusion')
    win    = MODvis_timeseries(folder)
    win.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
