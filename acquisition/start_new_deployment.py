"""start_new_deployment - Part of MOD_fish_processing

The "Start New Deployment" window. Pick the vehicle (most fields fill in from
its preset), set the probes on each AFE slot, build the survey name, and
click Create Setup. That writes the Setup file ./fctd_epsi reads (after
backing up the old one), dev1_setup.yml for MOD_fish_processing,
and a row in the cruise deployment log. See mod_setup_file.py for the rules
the Setup file has to follow, and docs/workflow/start_new_deployment.md for setup.
Check CTD calibration (next to CTD SN) asks the fish for its SBE calibration
and compares it with SBE/<SN>.CAL - see ctd_calibration.py. Shear slots show
their newest calibration date.

Run:  python3 start_new_deployment.py      (or double-click
      "Start New Deployment.command")
Settings come from config.yml next to this file (override with the
START_DEPLOYMENT_CONFIG environment variable) and presets/<vehicle>.yml.

Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography
"""

import datetime
import glob
import json
import os
import re
import sys
import tkinter as tk
from tkinter import messagebox, ttk

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mod_setup_file as msf  # noqa: E402
import ctd_calibration as cc  # noqa: E402

# Settings from config.yml (deck hardware and paths), shown under Advanced,
# grouped. kind: 'port' = serial port dropdown, 'flag' = checkbox, 'entry' = text.
# Changes here apply to this window only; permanent changes go in config.yml.
ADVANCED_GROUPS = [
    ('Serial ports', [
        ('command_port', 'Command port', 'port'), ('ctd_port', 'CTD data port', 'port'),
        ('speed', 'CTD baud rate', 'entry'),
        ('pcode_in_use', 'GPS (PCode) in use', 'flag'), ('pcode_port', 'GPS port', 'port'),
        ('pcode_speed', 'GPS baud rate', 'entry')]),
    ('Network', [
        ('tcpip_port', 'TCP/IP port', 'entry'),
        ('udp_in_use', 'UDP broadcast in use', 'flag'), ('udp_port', 'UDP port', 'entry')]),
    ('CTD data and display', [
        ('ctd_length', 'CTD length', 'entry'), ('output_format', 'Output format', 'entry'),
        ('print_data', 'printData (0/1/2)', 'entry'), ('eng_disp_rate', 'engDispRate', 'entry')]),
    ('Raw files', [
        ('data_path', 'Raw data folder', 'entry'), ('file_size', 'File size [bytes]', 'entry')]),
    ('Calibrations', [
        ('calibrations_root', 'Calibrations folder', 'entry')]),
    ('dev1_setup.yml and deployment log', [
        ('processed_root', 'Processed data root', 'entry'),
        ('deployment_log', 'Deployment log', 'entry')]),
]
ADVANCED_NOTES = {
    'dev1_setup.yml and deployment log':
        'dev1_setup.yml goes in <processed data root>/<survey>/meta/.',
    'Calibrations':
        'Read by fctd_epsi (via Setup) and processing (via dev1_setup.yml); also fills the serial number lists.',
}
# config.yml keys that write_all/validate read from config, editable under Advanced
CONFIG_OVERRIDES = ['processed_root', 'deployment_log', 'calibrations_root']
REMEMBERED = ['fish_flag', 'fish_pc', 'ctd_sn', 'compass_sn', 'profiling_direction', 'alt', 'alt_sn', 'fluor',
              'fluor_sn'] + \
    ['ch%d_%s' % (i, k) for i in range(1, 5) for k in ('type', 'sn')]
TYPE_BY_LABEL = {v: k for k, v in msf.SENSOR_LABELS.items()}


class StartNewDeployment:

    def __init__(self, root, config_path):
        self.root = root
        self.config_path = config_path
        self.config = msf.read_flat_yaml(config_path)
        self.last_used_path = os.path.join(os.path.dirname(config_path), 'last_used.json')
        self.presets = self.load_presets()
        self.vars = {}
        self.sn_boxes = []
        self.name_labels = []
        self.cal_labels = []
        self.loading = False
        self.loaded_vehicle = None

        root.title('Start New Deployment')
        root.minsize(720, 600)
        self.build()
        # Start from the current Setup; fall back to the first preset if there isn't one
        if os.path.isfile(os.path.join(self.config.get('setup_dir', ''), 'Setup')):
            self.load_current_setup()
        else:
            names = sorted(self.presets)
            if names:
                self.vars['vehicle'].set(names[0])
                self.on_vehicle()
            self.refresh()
        # The winch spool is the same for every vehicle until it's changed:
        # start from the one used at the last Create Setup
        if not self.vars['winch_spool'].get():
            self.vars['winch_spool'].set(self.previous_winch_spool())
        # ON THE WINCH SPOOL or LAB TEST is remembered the same way
        self.vars['on_winch_spool'].set(bool(self.read_last_used().get('_cruise', {}).get('on_winch_spool', True)))

    # ------------------------------------------------------------------ data
    def load_presets(self):
        presets = {}
        for p in sorted(glob.glob(os.path.join(HERE, 'presets', '*.yml'))):
            d = msf.read_flat_yaml(p)
            if d.get('vehicle'):
                presets[d['vehicle']] = d
        return presets

    def read_last_used(self):
        try:
            with open(self.last_used_path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def previous_winch_spool(self):
        """Winch spool in use: the last row of the cruise spool_swap_log.csv, or
        else the one used at the last Create Setup (any vehicle)."""
        shown = {k: self.vars[k].get().strip() for k in CONFIG_OVERRIDES if k in self.vars}
        return (msf.last_logged_spool(self.effective_config(dict(self.config, **shown)))
                or self.read_last_used().get('_cruise', {}).get('winch_spool', ''))

    def save_last_used(self, values):
        """Remember this vehicle's probes etc. (filled in next time it's picked),
        the winch spool for the cruise (one spool for every vehicle) and
        whether it's in use, and add each slot's serial number to that sensor
        type's dropdown list."""
        data = self.read_last_used()
        data[values['vehicle']] = {k: values.get(k) for k in REMEMBERED}
        cruise = data.setdefault('_cruise', {})
        cruise['on_winch_spool'] = bool(values.get('on_winch_spool'))
        if values.get('on_winch_spool'):
            cruise['winch_spool'] = values.get('winch_spool', '')
        history = data.setdefault('_sn_history', {})
        for i in range(1, 5):
            t, sn = values.get('ch%d_type' % i), values.get('ch%d_sn' % i)
            if t and t != 'none' and sn and sn != '000' and sn not in history.setdefault(t, []):
                history[t].append(sn)
        try:
            with open(self.last_used_path, 'w') as f:
                json.dump(data, f, indent=1, sort_keys=True)
        except OSError:
            pass
        self.vehicle_box.config(values=self.vehicle_names())

    def var(self, name, kind=tk.StringVar, value=''):
        if name not in self.vars:
            self.vars[name] = kind(value=value)
            self.vars[name].trace_add('write', lambda *a: self.refresh())
        return self.vars[name]

    def values(self):
        v = dict(self.config)
        for k, var in self.vars.items():
            val = var.get()
            v[k] = val.strip() if isinstance(val, str) else val
        for i in range(1, 5):
            v['ch%d_type' % i] = TYPE_BY_LABEL.get(v.get('ch%d_type' % i), v.get('ch%d_type' % i, 'none'))
        v['survey'] = msf.build_survey(v.get('survey_date', ''), v.get('vehicle', ''), v.get('survey_desc', ''))
        v['previous_winch_spool'] = self.previous_winch_spool()
        return v

    def set_values(self, d):
        """Fill the window from a dict (preset, last-used, or a parsed Setup)."""
        self.loading = True
        for k, val in d.items():
            if k in self.vars:
                if isinstance(self.vars[k], tk.BooleanVar):
                    self.vars[k].set(bool(val) and str(val).lower() not in ('false', '0'))
                elif k.endswith('_type') and k.startswith('ch'):
                    self.vars[k].set(msf.SENSOR_LABELS.get(val, val))
                else:
                    self.vars[k].set('' if val is None else str(val))
        self.loading = False
        self.refresh()

    # ------------------------------------------------------------------ layout
    def build(self):
        pad = {'padx': 6, 'pady': 3}
        outer = ttk.Frame(self.root, padding=10)
        outer.pack(fill='both', expand=True)

        self.banner = tk.Label(outer, text='', fg='white', bg='#b00020', anchor='w', justify='left',
                               font=('TkDefaultFont', 13, 'bold'), padx=8, pady=4)

        # On the winch spool or a lab test: decides whether this deployment is
        # in the cruise twist count (on_winch_spool), whatever it's called
        mode = tk.Frame(outer)
        mode.pack(fill='x', padx=6, pady=(3, 8))
        on_spool = self.var('on_winch_spool', tk.BooleanVar, True)
        for value, label in ((True, 'ON THE WINCH SPOOL'), (False, 'LAB TEST (not on a spool)')):
            tk.Radiobutton(mode, text=label, variable=on_spool, value=value, indicatoron=0,
                           font=('TkDefaultFont', 15, 'bold'), padx=16, pady=8, width=24,
                           selectcolor='#cfe8d2' if value else '#f3dcb0').pack(side='left', padx=(0, 8))
        on_spool.trace_add('write', lambda *a: self.on_mode())
        self.sea_values = {}

        # Deployment
        dep = ttk.LabelFrame(outer, text='Deployment', padding=8)
        dep.pack(fill='x', **pad)
        ttk.Label(dep, text='Vehicle').grid(row=0, column=0, sticky='w', **pad)
        # Pick a vehicle or type a new one; picking/leaving the box loads that
        # vehicle's preset and remembered values
        name_ok = (self.root.register(lambda s: re.match(r'^[A-Za-z0-9_\-]*$', s) is not None), '%P')
        self.vehicle_box = ttk.Combobox(dep, textvariable=self.var('vehicle'), values=self.vehicle_names(),
                                        width=14, validate='key', validatecommand=name_ok)
        self.vehicle_box.grid(row=0, column=1, sticky='w', **pad)
        for ev in ('<<ComboboxSelected>>', '<Return>', '<FocusOut>'):
            self.vehicle_box.bind(ev, lambda e: self.on_vehicle())
        ttk.Label(dep, text='Fish type').grid(row=0, column=2, sticky='e', **pad)
        ff = ttk.Frame(dep)
        ff.grid(row=0, column=3, sticky='w', **pad)
        for t in ('EPSI', 'FCTD'):
            ttk.Radiobutton(ff, text=t, value=t, variable=self.var('fish_flag')).pack(side='left')
        self.prefix_label = ttk.Label(ff, text='', foreground='#777')
        self.prefix_label.pack(side='left', padx=10)

        ttk.Label(dep, text='Survey name').grid(row=1, column=0, sticky='w', **pad)
        sv = ttk.Frame(dep)
        sv.grid(row=1, column=1, columnspan=3, sticky='w', **pad)
        okchars = (self.root.register(lambda s: re.match(r'^[A-Za-z0-9_\-]*$', s) is not None), '%P')
        ttk.Entry(sv, textvariable=self.var('survey_date', value=datetime.datetime.utcnow().strftime('%y_%m%d')),
                  width=8, validate='key', validatecommand=okchars).pack(side='left')
        ttk.Label(sv, text='_').pack(side='left')
        self.veh_part = ttk.Label(sv, text='', foreground='#555')
        self.veh_part.pack(side='left')
        ttk.Label(sv, text='_').pack(side='left')
        ttk.Entry(sv, textvariable=self.var('survey_desc'), width=22, validate='key',
                  validatecommand=okchars).pack(side='left')
        ttk.Label(sv, text='  (date YY_MMDD UTC, then a short description)', foreground='#777').pack(side='left')
        self.survey_preview = tk.Label(dep, text='', font=('TkFixedFont', 15, 'bold'), anchor='w')
        self.survey_preview.grid(row=2, column=1, columnspan=3, sticky='w', **pad)

        ttk.Label(dep, text='Experiment').grid(row=3, column=0, sticky='w', **pad)
        ttk.Entry(dep, textvariable=self.var('experiment', value=self.config.get('experiment', '')),
                  width=22).grid(row=3, column=1, sticky='w', **pad)
        ttk.Label(dep, text='Cruise').grid(row=3, column=2, sticky='e', **pad)
        ttk.Entry(dep, textvariable=self.var('cruise', value=self.config.get('cruise', '')),
                  width=16).grid(row=3, column=3, sticky='w', **pad)

        # Instruments
        ins = ttk.LabelFrame(outer, text='Instruments', padding=8)
        ins.pack(fill='x', **pad)
        ttk.Label(ins, text='Pressure case').grid(row=0, column=0, sticky='w', **pad)
        ttk.Entry(ins, textvariable=self.var('fish_pc'), width=14).grid(row=0, column=1, sticky='w', **pad)
        ttk.Label(ins, text='CTD SN').grid(row=0, column=2, sticky='e', **pad)
        ctd = ttk.Frame(ins)
        ctd.grid(row=0, column=3, sticky='w', **pad)
        self.ctd_box = ttk.Combobox(ctd, textvariable=self.var('ctd_sn'), width=10)
        self.ctd_box.pack(side='left')
        ttk.Button(ctd, text='Check CTD calibration', command=self.check_ctd_calibration).pack(side='left', padx=(6, 0))
        ttk.Label(ins, text='Profiling').grid(row=0, column=4, sticky='e', **pad)
        prof = ttk.Frame(ins)
        prof.grid(row=0, column=5, sticky='w', **pad)
        ttk.Combobox(prof, textvariable=self.var('profiling_direction', value='down'), values=['down', 'up', 'both'],
                     state='readonly', width=6).pack(anchor='w')
        ttk.Label(prof, text='direction to compute spectra', foreground='#777').pack(anchor='w')
        ttk.Label(ins, text='Winch spool').grid(row=0, column=6, sticky='e', **pad)
        self.spool_entry = ttk.Entry(ins, textvariable=self.var('winch_spool'), width=12)
        self.spool_entry.grid(row=0, column=7, sticky='w', **pad)

        ttk.Label(ins, text='AFE slot', font=('TkDefaultFont', 12, 'bold')).grid(row=1, column=0, sticky='w', **pad)
        ttk.Label(ins, text='Sensor', font=('TkDefaultFont', 12, 'bold')).grid(row=1, column=1, sticky='w', **pad)
        ttk.Label(ins, text='Name', font=('TkDefaultFont', 12, 'bold')).grid(row=1, column=2, sticky='w', **pad)
        ttk.Label(ins, text='Serial number', font=('TkDefaultFont', 12, 'bold')).grid(row=1, column=3, sticky='w', **pad)
        ttk.Label(ins, text='Calibrated', font=('TkDefaultFont', 12, 'bold')).grid(row=1, column=4, columnspan=2,
                                                                                  sticky='w', **pad)
        for i in range(1, 5):
            r = i + 1
            ttk.Label(ins, text='Slot %d (%s)' % (i, msf.BOARD_SLOT_NAMES[i - 1])).grid(
                row=r, column=0, sticky='w', **pad)
            cb = ttk.Combobox(ins, textvariable=self.var('ch%d_type' % i, value='none'), state='readonly', width=16,
                              values=[msf.SENSOR_LABELS[t] for t in msf.SENSOR_TYPES])
            cb.grid(row=r, column=1, sticky='w', **pad)
            nl = ttk.Label(ins, text='', width=4)
            nl.grid(row=r, column=2, sticky='w', **pad)
            self.name_labels.append(nl)
            sn = ttk.Combobox(ins, textvariable=self.var('ch%d_sn' % i), width=16)
            sn.grid(row=r, column=3, sticky='w', **pad)
            self.sn_boxes.append(sn)
            cl = tk.Label(ins, text='', anchor='w')
            cl.grid(row=r, column=4, columnspan=3, sticky='w', **pad)
            self.cal_labels.append(cl)
        ttk.Label(ins, text='Slots 5-7 are always the accelerometers a1-a3.',
                  foreground='#777').grid(row=6, column=0, columnspan=4, sticky='w', **pad)
        chk = ttk.Frame(ins)
        chk.grid(row=7, column=0, columnspan=6, sticky='w', **pad)
        self.extra_sn_entries = {}
        for k, label in (('fluor', 'Digital fluorometer'), ('alt', 'Altimeter')):
            ttk.Checkbutton(chk, text=label, variable=self.var(k, tk.BooleanVar, False)).pack(side='left', padx=(8, 2))
            ttk.Label(chk, text='SN').pack(side='left')
            e = ttk.Entry(chk, textvariable=self.var(k + '_sn'), width=12)
            e.pack(side='left', padx=(2, 16))
            self.extra_sn_entries[k] = e
        ttk.Label(ins, text='Latitude').grid(row=8, column=0, sticky='w', **pad)
        ttk.Entry(ins, textvariable=self.var('latitude', value=self.config.get('latitude', '')),
                  width=8).grid(row=8, column=1, sticky='w', **pad)
        ttk.Label(ins, text='Compass SN').grid(row=8, column=2, sticky='e', **pad)
        ttk.Entry(ins, textvariable=self.var('compass_sn'), width=12).grid(row=8, column=3, sticky='w', **pad)

        # Advanced (collapsed), in groups laid out two per row
        self.adv_shown = tk.BooleanVar(value=False)
        ttk.Checkbutton(outer, text='Show advanced settings (ports, raw files, calibration and processing paths)',
                        variable=self.adv_shown, command=self.toggle_advanced).pack(anchor='w', **pad)
        self.adv = ttk.LabelFrame(outer, padding=6,
                                  text='Advanced - normally left alone. Defaults from config.yml; '
                                       'changes here apply to this window only')
        ports = msf.list_serial_ports()
        for n, (title, fields) in enumerate(ADVANCED_GROUPS):
            wide = title.startswith(('Calibration', 'Processing', 'Raw'))
            grp = ttk.LabelFrame(self.adv, text=title, padding=4)
            grp.grid(row=n // 2, column=n % 2, sticky='nsew', padx=4, pady=3)
            for r, (k, label, kind) in enumerate(fields):
                if kind == 'flag':
                    ttk.Checkbutton(grp, text=label, variable=self.var(k, tk.BooleanVar, bool(self.config.get(k, True)))
                                    ).grid(row=r, column=0, columnspan=2, sticky='w', padx=4, pady=1)
                    continue
                ttk.Label(grp, text=label).grid(row=r, column=0, sticky='w', padx=4, pady=1)
                var = self.var(k, value=self.config.get(k, ''))
                if kind == 'port':
                    w = ttk.Combobox(grp, textvariable=var, values=ports, width=30)
                else:
                    w = ttk.Entry(grp, textvariable=var, width=44 if wide else 14)
                w.grid(row=r, column=1, sticky='w', padx=4, pady=1)
            row = len(fields)
            if title == 'Calibrations':
                ttk.Label(grp, text='Inside this folder:\n' + msf.calibration_layout_text(),
                          font=('TkFixedFont', 11), justify='left'
                          ).grid(row=row, column=0, columnspan=2, sticky='w', padx=4, pady=(4, 1))
                row += 1
            if title in ADVANCED_NOTES:
                ttk.Label(grp, text=ADVANCED_NOTES[title], foreground='#777', wraplength=380
                          ).grid(row=row, column=0, columnspan=2, sticky='w', padx=4, pady=1)

        # Messages + buttons
        self.msg = tk.Text(outer, height=7, wrap='word', relief='flat', background=self.root.cget('background'))
        self.msg.tag_configure('err', foreground='#b00020')
        self.msg.tag_configure('warn', foreground='#a05a00')
        self.msg.tag_configure('ok', foreground='#1b6e20')
        self.msg.pack(fill='both', expand=True, **pad)
        # Create Setup is the point of this window, so it's the one colored
        # button. A Label rather than a Button because macOS buttons ignore colors.
        self.create_btn = tk.Label(outer, text='Create Setup', font=('TkDefaultFont', 14, 'bold'),
                                   fg='white', bg='#1b6e20', padx=16, pady=4, cursor='hand2')
        self.create_btn.pack(anchor='w', padx=6, pady=(6, 2))
        self.create_btn.bind('<Button-1>', lambda e: self.create())
        ttk.Label(outer, text='Writes ' + os.path.join(self.config.get('setup_dir', '?'), 'Setup'),
                  foreground='#777').pack(anchor='w', padx=6)
        load = ttk.Frame(outer)
        load.pack(fill='x', padx=6, pady=(12, 0))
        ttk.Button(load, text='Load current Setup', command=self.load_current_setup).pack(side='left')
        ttk.Label(load, text="Fill this form from the Setup that's there now. Doesn't write or save anything.",
                  foreground='#777', wraplength=520).pack(side='left', padx=8)

    def check_ctd_calibration(self):
        """Ask the fish for its SBE calibration ($DCAL) and compare it with
        SBE/<SN>.CAL in the calibrations folder; offer to rewrite the file
        from the fish when they differ."""
        v = self.values()
        sbe_dir = msf.calibration_paths(v.get('calibrations_root', ''))['ctd_cal_path']
        self.root.config(cursor='watch')
        self.root.update()
        try:
            fish = cc.parse(cc.read_dcal_from_fish(v.get('command_port'), v.get('ctd_port'), v.get('speed')))
        except (RuntimeError, ValueError) as err:
            messagebox.showerror('Check CTD calibration', "Couldn't get the calibration from the fish:\n\n%s" % err)
            return
        finally:
            self.root.config(cursor='')
        path = os.path.join(sbe_dir, fish['sn'] + '.CAL')
        disk, problem = None, ''
        if not os.path.isfile(path):
            problem = 'There is no %s.' % path
        else:
            try:
                disk = cc.read_cal_file(path)
            except (OSError, ValueError) as err:
                problem = "Can't read %s: %s" % (path, err)
        rows = cc.compare(fish, disk) if disk else []

        dlg = tk.Toplevel(self.root)
        dlg.title('Check CTD calibration')
        dlg.transient(self.root)
        f = ttk.Frame(dlg, padding=10)
        f.pack(fill='both', expand=True)
        dates = ', '.join('%s %s' % (k, fish[d].strftime('%d-%b-%y'))
                          for k, d in (('T', 'temp_date'), ('C', 'cond_date'), ('P', 'pres_date')))
        ttk.Label(f, text='The SBE on the fish: SN %s, calibrated %s' % (fish['sn'], dates),
                  font=('TkDefaultFont', 13, 'bold')).pack(anchor='w')
        form_sn = v.get('ctd_sn', '')
        form_sn = '%04d' % int(form_sn) if form_sn.isdigit() else form_sn
        if form_sn and form_sn != fish['sn']:
            tk.Label(f, text='The form says CTD SN %s - the fish has %s.' % (v['ctd_sn'], fish['sn']),
                     fg='#b00020').pack(anchor='w', pady=(6, 0))
        if problem:
            tk.Label(f, text=problem, fg='#b00020').pack(anchor='w', pady=(6, 0))
        elif rows:
            tk.Label(f, text='%s differs from the fish:' % path, fg='#b00020').pack(anchor='w', pady=(6, 2))
            # one label per cell, so the columns line up whatever the font;
            # values right-aligned so the exponents line up
            table = tk.Frame(f, bg='white', padx=8, pady=6)
            table.pack(anchor='w', fill='x')
            bold = ('TkDefaultFont', 12, 'bold')
            for c, head in enumerate(('', 'fish', 'file (%s.CAL)' % fish['sn'])):
                tk.Label(table, text=head, font=bold, bg='white').grid(row=0, column=c, sticky='w' if c == 0 else 'e',
                                                                      padx=(0, 24))
            for r, row in enumerate(rows, start=1):
                for c, val in enumerate(row):
                    tk.Label(table, text=val, bg='white', font=('Menlo', 12) if c else ('TkDefaultFont', 12)
                             ).grid(row=r, column=c, sticky='w' if c == 0 else 'e', padx=(0, 24))
        else:
            tk.Label(f, text='%s matches the fish.' % path, fg='#1b6e20').pack(anchor='w', pady=(6, 0))
        extra = cc.offsets(fish)
        if extra:
            tk.Label(f, text='The fish also has %s - a .CAL file has no place for these; processing takes '
                             "them from the raw files' $DCAL." % ', '.join('%s = %s' % e for e in extra),
                     fg='#a05a00', wraplength=560, justify='left').pack(anchor='w', pady=(6, 0))
        b = ttk.Frame(dlg, padding=8)
        b.pack(fill='x')
        ttk.Button(b, text='Close', command=dlg.destroy).pack(side='right')
        if (problem and not disk and os.path.isdir(sbe_dir)) or rows:
            ttk.Button(b, text='Write %s.CAL from the fish' % fish['sn'],
                       command=lambda: self.write_ctd_calibration(dlg, fish, sbe_dir)).pack(side='right', padx=8)
        if form_sn != fish['sn']:
            ttk.Button(b, text='Use CTD SN %s' % fish['sn'],
                       command=lambda: self.vars['ctd_sn'].set(fish['sn'])).pack(side='right', padx=8)
        dlg.wait_visibility()
        dlg.grab_set()

    def write_ctd_calibration(self, dlg, fish, sbe_dir):
        try:
            path, backup = cc.write_cal_file(fish, sbe_dir)
        except OSError as err:
            messagebox.showerror('Check CTD calibration', 'Nothing was written:\n\n%s' % err, parent=dlg)
            return
        dlg.destroy()
        lines = ['Wrote %s from the fish.' % path, '']
        if backup:
            lines.append('The old file is kept as %s.' % os.path.basename(backup))
        else:
            lines += ['Commit it in MOD_fish_calibrations so the change is kept:',
                      '  git -C %s commit -am "%s.CAL from the fish (calibrated %s)"'
                      % (os.path.dirname(sbe_dir), fish['sn'], fish['temp_date'].strftime('%d-%b-%y'))]
        lines += ['', 'Restart ./fctd_epsi so the .modraw headers get it too (it reads the file when it starts).']
        messagebox.showinfo('Check CTD calibration', '\n'.join(lines))
        self.refresh()

    def on_mode(self):
        """Lab test: prefill cruise, experiment and profiling direction (still
        editable - fctd_epsi needs a value) and keep what was there; back on
        the spool, put those back."""
        keys = ('cruise', 'experiment', 'profiling_direction')
        if not all(k in self.vars for k in keys):
            return
        if self.vars['on_winch_spool'].get():
            for k, val in self.sea_values.items():
                self.vars[k].set(val)
            self.sea_values = {}
        elif not self.sea_values:
            self.sea_values = {k: self.vars[k].get() for k in keys}
            for k, val in (('cruise', 'lab'), ('experiment', 'lab'), ('profiling_direction', 'down')):
                self.vars[k].set(val)

    def toggle_advanced(self):
        if self.adv_shown.get():
            self.adv.pack(fill='x', padx=6, pady=3, before=self.msg)
        else:
            self.adv.pack_forget()

    # ------------------------------------------------------------------ events
    def vehicle_names(self):
        """Presets plus any typed-in vehicle that has been used before."""
        used = [k for k in self.read_last_used() if not k.startswith('_')]
        return sorted(set(self.presets) | set(used))

    def on_vehicle(self):
        name = self.vars['vehicle'].get().strip()
        known = {n.lower(): n for n in self.vehicle_names()}
        if name.lower() in known and name != known[name.lower()]:
            name = known[name.lower()]           # mako1 -> MAKO1
            self.vars['vehicle'].set(name)
        if name == self.loaded_vehicle:
            return                               # e.g. clicking in and out of the box
        self.loaded_vehicle = name
        d = dict(self.presets.get(name, {}))
        d.update({k: v for k, v in self.read_last_used().get(name, {}).items() if v is not None})
        d.pop('vehicle', None)
        known_vehicle = bool(d)
        self.set_values(d)   # the winch spool isn't per vehicle, so it's left as it is
        if not known_vehicle and name:
            self.status('New vehicle %s - fill in the fish type and instruments; they are remembered '
                        'for %s when you click Create Setup.' % (name, name))

    def load_current_setup(self):
        path = os.path.join(self.config.get('setup_dir', ''), 'Setup')
        if not os.path.isfile(path):
            messagebox.showerror('Start New Deployment', 'No Setup file at\n%s' % path)
            return
        v = msf.setup_to_values(msf.parse_setup(path))
        # Only the deployment fields come from Setup; deck hardware and paths
        # (everything under Advanced) always come from config.yml
        for _, fields in ADVANCED_GROUPS:
            for k, _, _ in fields:
                v.pop(k, None)
        for k in msf.CAL_SUBFOLDERS:     # always derived from the calibrations folder
            v.pop(k, None)
        for k in ('ch1_type', 'ch2_type', 'ch3_type', 'ch4_type'):
            v.setdefault(k, None)
        if not v.get('ch1_type'):    # file written before slot types were recorded
            default = ['fpo7', 'fpo7', 'shear', 'shear'] if v.get('fish_flag') == 'EPSI' else ['none'] * 4
            for i in range(4):
                v['ch%d_type' % (i + 1)] = default[i]
        match = [p for p in self.vehicle_names() if p.lower() == str(v.get('vehicle', '')).lower()]
        if match:
            v['vehicle'] = match[0]
        self.loaded_vehicle = v.get('vehicle')
        survey = v.pop('survey', '')
        m = re.match(r'^(\d\d_\d{4})_(.*)$', survey)
        date, rest = (m.group(1), m.group(2)) if m else (datetime.datetime.utcnow().strftime('%y_%m%d'), survey)
        veh = str(v.get('vehicle', '')).lower()
        if rest.lower().startswith(veh + '_'):
            rest = rest[len(veh) + 1:]
        v['survey_date'], v['survey_desc'] = date, rest
        self.set_values(v)
        self.status('Filled in from the current Setup (advanced settings from config.yml). '
                    'Nothing is saved until you click Create Setup.')

    def effective_config(self, v):
        """config.yml, with the paths edited under Advanced."""
        cfg = dict(self.config)
        cfg.update({k: v.get(k, '') for k in CONFIG_OVERRIDES})
        return cfg

    def status(self, text, tag='ok'):
        self.msg.config(state='normal')
        self.msg.insert('1.0', text + '\n', tag)
        self.msg.config(state='disabled')

    def refresh(self):
        if self.loading or not hasattr(self, 'msg'):
            return
        v = self.values()
        self.veh_part.config(text=v.get('vehicle', '').lower() or '<vehicle>')
        prefix = msf.raw_file_prefix(v)
        self.prefix_label.config(text='raw files: %s%s_...' % (prefix, datetime.datetime.utcnow().strftime('%y_%m_%d')))
        names = msf.slot_names(v)
        cal = msf.calibration_paths(v.get('calibrations_root', ''))
        cal_dirs = {'fpo7': cal['fpo7_cal_path'], 'shear': cal['shear_cal_path']}
        self.ctd_box.config(values=msf.list_ctd_sns(cal['ctd_cal_path']))
        history = self.read_last_used().get('_sn_history', {})
        for i in range(4):
            t = v.get('ch%d_type' % (i + 1), 'none')
            self.name_labels[i].config(text=names[i] if t != 'none' else '-')
            sns = msf.list_probe_sns(cal_dirs.get(t))
            sns = [s for s in history.get(t, []) if s not in sns] + sns
            self.sn_boxes[i].config(values=sns, state='disabled' if t == 'none' else 'normal')
            age = msf.shear_cal_age(v, i + 1)
            if age:
                when, years, old = age
                self.cal_labels[i].config(text='%s (%.1f years ago)' % (when.strftime('%d-%b-%Y'), years),
                                          fg='#a05a00' if old else '#555')
            else:
                self.cal_labels[i].config(text='')
        self.spool_entry.config(state='normal' if v.get('on_winch_spool') else 'disabled')
        for k, e in self.extra_sn_entries.items():
            e.config(state='normal' if v.get(k) else 'disabled')
        survey = v['survey']
        errors, warnings = msf.validate(v, self.effective_config(v))
        today = datetime.datetime.utcnow().strftime('%y_%m%d')
        if v.get('survey_date') != today:
            warnings.insert(0, 'Survey date is %s, not today (%s UTC) - new deployment? Update the survey name.'
                            % (v.get('survey_date') or '(blank)', today))
        survey_bad = len(survey) > msf.NAME_MAX or not msf.NAME_RE.match(survey or '-')
        self.survey_preview.config(text='%s   (%d/%d)' % (survey, len(survey), msf.NAME_MAX),
                                   fg='#b00020' if survey_bad else '#1b6e20')

        swp = os.path.exists(os.path.join(self.config.get('setup_dir', ''), '.Setup.swp'))
        if not os.path.isdir(self.config.get('setup_dir', '')):
            self.banner.config(text='Setup folder not found: %s - check setup_dir in config.yml'
                               % self.config.get('setup_dir', ''))
            self.banner.pack(fill='x', before=self.banner.master.winfo_children()[1])
        elif swp:
            self.banner.config(text='Setup is open in vi somewhere (.Setup.swp). Quit vi without saving before using this.')
            self.banner.pack(fill='x', before=self.banner.master.winfo_children()[1])
        else:
            self.banner.pack_forget()

        self.msg.config(state='normal')
        self.msg.delete('1.0', 'end')
        for e in errors:
            self.msg.insert('end', 'ERROR: ' + e + '\n', 'err')
        for w in warnings:
            self.msg.insert('end', 'Warning: ' + w + '\n', 'warn')
        if not errors:
            self.msg.insert('end', 'Ready to create Setup for %s.\n' % survey, 'ok')
        self.msg.config(state='disabled')
        self.create_enabled = not errors
        self.create_btn.config(bg='#1b6e20' if self.create_enabled else '#9e9e9e',
                               text='Create Setup' if self.create_enabled else 'Create Setup  (fix the errors above)',
                               cursor='hand2' if self.create_enabled else 'arrow')

    def create(self):
        v = self.values()
        errors, warnings = msf.validate(v, self.effective_config(v))
        if errors:
            return
        setup_path = os.path.join(self.config['setup_dir'], 'Setup')
        diff = msf.setup_diff(setup_path, msf.render_setup(v)) or '(no change)'

        dlg = tk.Toplevel(self.root)
        dlg.title('Write this Setup?')
        dlg.transient(self.root)
        # Buttons and notes are packed at the bottom first so they always
        # show; the diff gets whatever height is left, with a scrollbar.
        b = ttk.Frame(dlg, padding=8)
        b.pack(side='bottom', fill='x')
        ttk.Button(b, text='Cancel', command=dlg.destroy).pack(side='right')
        ttk.Button(b, text='Write Setup', command=lambda: self.do_write(dlg, v)).pack(side='right', padx=8)
        if warnings:
            ttk.Label(dlg, text='%d warning(s) - see the main window.' % len(warnings), foreground='#a05a00',
                      padding=(8, 0)).pack(side='bottom', anchor='w')
        cfg = self.effective_config(v)
        yml = msf.dev1_setup_yml_path(v, cfg) if cfg.get('processed_root') else ''
        note = 'Also writes %s%s' % (yml, ' (an existing one is kept as .replaced_*)' if yml and os.path.isfile(yml) else '')
        ttk.Label(dlg, text=note, padding=8, wraplength=700).pack(side='bottom', anchor='w')

        ttk.Label(dlg, text='Changes to %s:' % setup_path, padding=(8, 8, 8, 0)).pack(anchor='w')
        legend = ttk.Frame(dlg, padding=(8, 2))
        legend.pack(anchor='w')
        tk.Label(legend, text='- red: removed from the current Setup', fg='#b00020').pack(side='left')
        tk.Label(legend, text='    + green: added', fg='#1b6e20').pack(side='left')
        tk.Label(legend, text='    black: unchanged (shown for context)', fg='#555').pack(side='left')
        box = ttk.Frame(dlg)
        box.pack(fill='both', expand=True, padx=8)
        lines = diff.splitlines(True)
        fit = max(10, (self.root.winfo_screenheight() - 300) // 18)
        txt = tk.Text(box, width=100, height=min(len(lines) + 1, fit), font=('TkFixedFont', 11))
        sb = ttk.Scrollbar(box, orient='vertical', command=txt.yview)
        txt.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y')
        txt.pack(side='left', fill='both', expand=True)
        for line in lines:
            tag = 'add' if line.startswith('+') and not line.startswith('+++') else \
                  'del' if line.startswith('-') and not line.startswith('---') else ''
            txt.insert('end', line, tag)
        txt.tag_configure('add', foreground='#1b6e20')
        txt.tag_configure('del', foreground='#b00020')
        txt.config(state='disabled')
        dlg.grab_set()

    def do_write(self, dlg, v):
        dlg.destroy()
        try:
            res = msf.write_all(v, self.effective_config(v))
        except Exception as err:
            messagebox.showerror('Start New Deployment', 'Nothing more was written:\n\n%s' % err)
            return
        self.save_last_used(v)
        lines = ['Setup written for %s.' % v['survey'], '', 'Setup: ' + res['setup']]
        if res['backup']:
            lines.append('Previous Setup kept as: ' + os.path.basename(res['backup']))
        if res['yml']:
            lines.append('dev1_setup.yml: ' + res['yml'])
        if res['log']:
            lines.append('Logged in: ' + res['log'])
        if res.get('spool_log'):
            lines.append('Winch spool change logged in: ' + res['spool_log'])
        if res.get('log_rotated'):
            lines.append('(The old log had different columns - kept as %s)' % os.path.basename(res['log_rotated']))
        lines += ['', 'Restart ./fctd_epsi to start recording with it.']
        messagebox.showinfo('Start New Deployment', '\n'.join(lines))


def main():
    config_path = os.environ.get('START_DEPLOYMENT_CONFIG') or os.path.join(HERE, 'config.yml')
    if not os.path.isfile(config_path):
        print('No config file at %s' % config_path)
        sys.exit(1)
    root = tk.Tk()
    StartNewDeployment(root, config_path)
    root.mainloop()


if __name__ == '__main__':
    main()
