"""mod_setup_file - Part of MOD_fish_processing

Read, validate and write the "Setup" file that ./fctd_epsi (the fish
acquisition program) reads at startup, plus dev1_setup.yml (the deployment's
first processing metadata) and the cruise deployment log. No GUI here - start_new_deployment.py is the window.

Rules the Setup writer follows, all from fctd_epsi's own source
(fctd_epsi_acq/fctd_epsi/main.c ReadSetupFile, file_utils.c, ctd.h, pcode.h,
fctd_epsi.c):
  - Each line is split with strtok on "=, '" (equals, comma, space, single
    quote), so a value can't contain any of those. The quotes around values
    are cosmetic.
  - '#' anywhere, and '//' anywhere, start a comment, so values can't contain
    them either (paths must not have a doubled slash).
  - A line whose first token starts with '%' is skipped; unknown keys are
    ignored (but still copied into every .modraw header).
  - Every key fctd_epsi reads does strtok(NULL, sep) then strcpy/atoi on the
    result. An empty value (KEY='') returns NULL and segfaults fctd_epsi -
    this is what crashed the earlier convert_yaml_to_setup.py output
    (CTD.fish_pc=''). So: no key that fctd_epsi reads is ever written empty.
  - Name fields are 32-byte buffers (31 characters max, no length check -
    a longer survey name silently overwrites the next field); calibration
    paths are 256 bytes.
  - The whole file is copied into every .modraw header through a 2124-byte
    stack buffer with no total-length check, so the file must stay under
    MAX_SETUP_BYTES.
  - fctd_epsi archives the Setup it reads to SetupYYYYMMDDHHMM (UTC) on every
    start; the backup this module makes of a replaced Setup is named
    Setup_replaced_YYYYMMDDHHMMSS so the two are never confused.
  - Legacy MOD_fish_lib processing finds CTD.survey= and CTD.fishflag= by
    fixed string slicing, so values are always written KEY='VALUE' with no
    spaces.

Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography
"""

import csv
import datetime
import difflib
import glob
import os
import re

MAX_SETUP_BYTES = 2000      # fctd_epsi.c str4Setupfile[2124], minus margin
NAME_MAX = 31               # char[32] fields in ctd.h / pcode.h
PATH_MAX = 255              # char[256] calibration paths in ctd.h

# AFE analog slots 1-4. Slots 5-7 are always the accelerometers a1-a3.
SENSOR_TYPES = ['fpo7', 'shear', 'fluor', 'microcond', 'none']
SENSOR_LABELS = {'fpo7': 'FP07', 'shear': 'shear', 'fluor': 'fluorometer',
                 'microcond': 'microconductivity', 'none': 'none'}
# Logical channel names, handed out in slot order per type (t1 then t2, ...)
TYPE_NAMES = {'fpo7': ['t1', 't2'], 'shear': ['s1', 's2'],
              'fluor': ['f1', 'f2'], 'microcond': ['c1', 'c2']}
DEFAULT_SLOT_NAMES = ['t1', 't2', 's1', 's2']   # standard EFE (MODsetup_default_efe.m)

# Standard EFE electrical settings for dev1_setup.yml afe.channels
AFE_CHANNEL_SETTINGS = {
    't1': (2.5, 'Unipolar'), 't2': (2.5, 'Unipolar'),
    's1': (2.5, 'Bipolar'), 's2': (2.5, 'Bipolar'),
    'a1': (1.8, 'Unipolar'), 'a2': (1.8, 'Unipolar'), 'a3': (1.8, 'Unipolar'),
    'f1': (2.5, 'Bipolar'), 'f2': (2.5, 'Bipolar'),
    'c1': (2.5, 'Bipolar'), 'c2': (2.5, 'Bipolar'),
}

# Every Setup key fctd_epsi's ReadSetupFile reads -> (values key, kind, max length).
# kind: 'name' = token, 'path' = absolute path, 'int' = integer.
SETUP_KEYS = {
    'TCPIPSocket.portnum':          ('tcpip_port', 'int', None),
    'UDPSocket.portnum':            ('udp_port', 'int', None),
    'CTD.survey':                   ('survey', 'name', NAME_MAX),
    'CTD.experiment':               ('experiment', 'name', NAME_MAX),
    'CTD.cruise':                   ('cruise', 'name', NAME_MAX),
    'CTD.vehicle':                  ('vehicle', 'name', NAME_MAX),
    'CTD.fish_pc':                  ('fish_pc', 'name', NAME_MAX),
    'CTD.fishflag':                 ('fish_flag', 'name', NAME_MAX),
    'CTD.SerialNum':                ('ctd_sn', 'name', NAME_MAX),
    'CTD.shear_Probecal_path':      ('shear_cal_path', 'path', PATH_MAX),
    'CTD.FPO7_Probecal_path':       ('fpo7_cal_path', 'path', PATH_MAX),
    'CTD.CTD_cal_path':             ('ctd_cal_path', 'path', PATH_MAX),
    'CTD.ch1_sn':                   ('ch1_sn', 'name', NAME_MAX),
    'CTD.ch2_sn':                   ('ch2_sn', 'name', NAME_MAX),
    'CTD.ch3_sn':                   ('ch3_sn', 'name', NAME_MAX),
    'CTD.ch4_sn':                   ('ch4_sn', 'name', NAME_MAX),
    'CTD.printData':                ('print_data', 'int', None),
    'CTD.engDispRate':              ('eng_disp_rate', 'int', None),
    'CTD.CTDPortName':              ('ctd_port', 'path', NAME_MAX),
    'CTD.CommandPortName':          ('command_port', 'path', NAME_MAX),
    'CTD.speed':                    ('speed', 'int', None),
    'CTD.CTDlength':                ('ctd_length', 'int', None),
    'PCode.PCodePortName':          ('pcode_port', 'path', NAME_MAX),
    'PCode.speed':                  ('pcode_speed', 'int', None),
    'Ascii_dataFile.runname':       ('runname', 'name', NAME_MAX),
    'Ascii_dataFile.path':          ('data_path', 'path', 1023),
    'Ascii_dataFile.dataFileSize':  ('file_size', 'int', None),
}
# Keys written to Setup but never read by fctd_epsi (safe to leave empty)
EXTRA_SETUP_KEYS = {
    'CTD.MicroCond': 'microcond_sn',
    'CTD.Compass': 'compass_sn',
    'CTD.output_format': 'output_format',
    'CTD.ch1_type': 'ch1_type', 'CTD.ch2_type': 'ch2_type',
    'CTD.ch3_type': 'ch3_type', 'CTD.ch4_type': 'ch4_type',
}
# Optional keys: commented out with % when switched off (never written empty)
OPTIONAL_FLAGS = {'pcode_port': 'pcode_in_use', 'pcode_speed': 'pcode_in_use',
                  'udp_port': 'udp_in_use'}

NAME_RE = re.compile(r'^[A-Za-z0-9_.\-+:]+$')
PATH_RE = re.compile(r'^/[A-Za-z0-9_.\-+:/]*$')
SURVEY_PART_RE = re.compile(r'^[A-Za-z0-9_\-]*$')


# --------------------------------------------------------------------------
# Small flat-YAML reader (presets/config are flat key: value files), so the
# window runs without PyYAML.
# --------------------------------------------------------------------------
def read_flat_yaml(path):
    """Read a flat 'key: value  # comment' file into a dict of strings/bools."""
    out = {}
    with open(path, 'r') as f:
        for raw in f:
            line = raw.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            if ':' not in line:
                continue
            key, val = line.split(':', 1)
            val = _strip_yaml_comment(val).strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in '\'"':
                val = val[1:-1]
            elif val.lower() in ('true', 'yes'):
                val = True
            elif val.lower() in ('false', 'no'):
                val = False
            out[key.strip()] = val
    return out


def _strip_yaml_comment(val):
    """Drop a trailing ' # comment' that isn't inside quotes."""
    quote = None
    for i, c in enumerate(val):
        if c in '\'"':
            quote = None if quote == c else (c if quote is None else quote)
        elif c == '#' and quote is None and (i == 0 or val[i - 1] in ' \t'):
            return val[:i]
    return val


def write_flat_yaml(path, d, header=''):
    lines = [header] if header else []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, bool):
            v = 'true' if v else 'false'
        lines.append("%s: '%s'" % (k, v))
    _atomic_write(path, '\n'.join(lines) + '\n')


# --------------------------------------------------------------------------
# Parse an existing Setup the same way fctd_epsi does
# --------------------------------------------------------------------------
def _strip_c_comments(text):
    """Mimic getchar_ignore_comments_f: '#' and '//' to end of line, /* */ blocks."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '#' or text.startswith('//', i):
            while i < n and text[i] != '\n':
                i += 1
            continue
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def parse_setup(path):
    """Return {setup_key: value} for every non-comment KEY=VALUE line, read
    with fctd_epsi's tokenizer. Lines starting with '%' are reported in
    '_commented' (so e.g. a disabled PCode line is still known)."""
    with open(path, 'r', errors='replace') as f:
        text = _strip_c_comments(f.read())
    vals, commented = {}, {}
    for line in text.split('\n'):
        line = line.strip()
        if not line:
            continue
        target = vals
        if line.startswith('%'):
            line = line[1:].strip()
            target = commented
        toks = [t for t in re.split(r"[=, ']+", line) if t]
        if not toks:
            continue
        target[toks[0]] = toks[1] if len(toks) > 1 else ''
    vals['_commented'] = commented
    return vals


def setup_to_values(parsed):
    """Map a parse_setup() result onto the values dict used by the window."""
    v = {}
    commented = parsed.get('_commented', {})
    for key, (name, _, _) in SETUP_KEYS.items():
        if key in parsed:
            v[name] = parsed[key]
        elif key in commented:
            v[name] = commented[key]
    for key, name in EXTRA_SETUP_KEYS.items():
        if key in parsed:
            v[name] = parsed[key]
    v['pcode_in_use'] = 'PCode.PCodePortName' in parsed
    v['udp_in_use'] = 'UDPSocket.portnum' in parsed
    return v


# --------------------------------------------------------------------------
# Channels
# --------------------------------------------------------------------------
def slot_names(values):
    """Logical names for AFE slots 1-4 from their types, in slot order. A slot
    with type 'none' keeps its standard EFE name (t1/t2/s1/s2) so slot
    positions stay fixed for processing."""
    used = {t: 0 for t in TYPE_NAMES}
    names = []
    for i in range(4):
        t = values.get('ch%d_type' % (i + 1), 'none')
        if t in TYPE_NAMES and used[t] < len(TYPE_NAMES[t]):
            names.append(TYPE_NAMES[t][used[t]])
            used[t] += 1
        else:
            names.append(None)
    taken = set(n for n in names if n)
    for i, n in enumerate(names):
        if n is None:
            d = DEFAULT_SLOT_NAMES[i]
            names[i] = d if d not in taken else 'x%d' % (i + 1)
            taken.add(names[i])
    return names


def microcond_sn(values):
    """CTD.MicroCond comes from the microconductivity slot, if there is one."""
    for i in range(1, 5):
        if values.get('ch%d_type' % i) == 'microcond':
            return values.get('ch%d_sn' % i, '')
    return values.get('microcond_sn', '')


def _slot_sn_for_setup(values, i):
    if values.get('ch%d_type' % i, 'none') == 'none':
        return '000'
    return values.get('ch%d_sn' % i, '')


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------
def build_survey(date_str, vehicle, description):
    parts = [p for p in (date_str, (vehicle or '').lower(), description) if p]
    return '_'.join(parts)


def setup_values(values):
    """The values exactly as they go into Setup (derived fields filled in)."""
    v = dict(values)
    for i in range(1, 5):
        v['ch%d_sn' % i] = _slot_sn_for_setup(values, i)
        v.setdefault('ch%d_type' % i, 'none')
    v['microcond_sn'] = microcond_sn(values)
    v['runname'] = raw_file_prefix(values)
    v.update(calibration_paths(values.get('calibrations_root', '')))
    return v


# What goes inside the one calibrations folder: (Setup key, subfolder, files,
# what). Same names processing (MODsetup_read_yaml.m) and the
# MOD_fish_calibrations repo use. The window's description of the folder is
# built from this table, so renaming a subfolder here changes it everywhere
# in acquisition/ (planned: SHEAR_PROBES -> SHEAR, along with processing and
# MOD_fish_calibrations).
CAL_LAYOUT = [
    ('ctd_cal_path', 'SBE', '<SN>.CAL', 'CTD'),
    ('shear_cal_path', 'SHEAR_PROBES', '<SN>/Calibration_<SN>.txt', 'shear probes'),
    ('fpo7_cal_path', 'FPO7', '<SN>/Calibration_<SN>.txt', 'FP07 probes'),
]
CAL_SUBFOLDERS = {key: sub for key, sub, _, _ in CAL_LAYOUT}
# FP07 calibration files aren't normally used, so a missing one isn't warned about
NO_CAL_WARNING = {'fpo7_cal_path'}
# Not used by fctd_epsi, but processing needs it for shear epsilon: the shear
# charge-amp electronics response (MODsetup_define_filters.m reads it from here)
SHEAR_CHARGEAMP_FILE = os.path.join('SHEAR', 'cap1nFres200Meg_5KohmInput.mat')


def calibration_layout_text():
    """The calibrations folder's contents, one aligned line per subfolder."""
    w1 = max(len(sub) for _, sub, _, _ in CAL_LAYOUT) + 1
    w2 = max(len(f) for _, _, f, _ in CAL_LAYOUT)
    return '\n'.join('%-*s %-*s  %s' % (w1, sub + '/', w2, f, what) for _, sub, f, what in CAL_LAYOUT)


def calibration_paths(cal_root):
    """Setup's three calibration paths, all inside the one calibrations folder,
    so fctd_epsi and processing read the same files."""
    root = str(cal_root or '').rstrip('/')
    return {k: (root + '/' + sub if root else '') for k, sub in CAL_SUBFOLDERS.items()}


def raw_file_prefix(values):
    """Raw files start with the fish type: EPSI... for a Mako, FCTD... for an FCTD."""
    return values.get('fish_flag') if values.get('fish_flag') in ('EPSI', 'FCTD') else values.get('runname', '')


FIELD_LABELS = {
    'survey': 'Survey name', 'experiment': 'Experiment', 'cruise': 'Cruise', 'vehicle': 'Vehicle',
    'fish_pc': 'Pressure case', 'fish_flag': 'Fish type', 'ctd_sn': 'CTD SN',
    'ctd_port': 'CTD data port', 'command_port': 'Command port', 'pcode_port': 'GPS (PCode) port',
    'runname': 'Raw file prefix', 'data_path': 'Raw data folder',
}


def _label(name, key, values):
    m = re.match(r'^ch(\d)_sn$', name)
    if m:
        i = int(m.group(1))
        return 'Slot %d (%s) serial number' % (i, slot_names(values)[i - 1])
    return '%s (%s)' % (FIELD_LABELS.get(name, name), key)


def validate(values, config=None):
    """Return (errors, warnings), each a list of strings. Errors block writing."""
    errors, warnings = [], []
    v = setup_values(values)
    for key, (name, kind, maxlen) in SETUP_KEYS.items():
        flag = OPTIONAL_FLAGS.get(name)
        if flag and not v.get(flag, True):
            continue
        val = str(v.get(name, '')).strip()
        label = _label(name, key, values)
        if val == '':
            errors.append('%s is empty - fctd_epsi crashes on an empty value' % label)
            continue
        if kind == 'int':
            if not re.match(r'^-?\d+$', val):
                errors.append('%s must be a whole number, got "%s"' % (label, val))
            continue
        if kind == 'path':
            if not PATH_RE.match(val):
                errors.append('%s must be an absolute path using only letters, digits and _ . - + : / (no spaces or quotes): "%s"' % (label, val))
            elif '//' in val:
                errors.append('%s has "//", which fctd_epsi reads as a comment: "%s"' % (label, val))
        elif not NAME_RE.match(val):
            errors.append('%s may only use letters, digits and _ . - + : (no spaces, quotes, commas, = or #): "%s"' % (label, val))
        if maxlen and len(val) > maxlen:
            errors.append('%s is %d characters; fctd_epsi allows at most %d' % (label, len(val), maxlen))
    for key, name in EXTRA_SETUP_KEYS.items():
        val = str(v.get(name, '')).strip()
        if val and not NAME_RE.match(val):
            errors.append('%s (%s) may only use letters, digits and _ . - + : - got "%s"' % (name, key, val))
    if v.get('fish_flag') not in ('EPSI', 'FCTD'):
        errors.append('fish type must be EPSI or FCTD')
    for i in range(1, 5):
        if v.get('ch%d_type' % i) not in SENSOR_TYPES:
            errors.append('channel %d: unknown sensor type "%s"' % (i, v.get('ch%d_type' % i)))
    names = slot_names(values)
    counts = {}
    for i in range(4):
        if values.get('ch%d_type' % (i + 1), 'none') != 'none':
            counts.setdefault(values['ch%d_type' % (i + 1)], []).append(i + 1)
    for t, slots in counts.items():
        if len(slots) > len(TYPE_NAMES[t]):
            errors.append('%d %s channels (slots %s) - at most %d' % (len(slots), SENSOR_LABELS[t], slots, len(TYPE_NAMES[t])))
    if not errors:
        size = len(render_setup(values).encode())
        if size > MAX_SETUP_BYTES:
            errors.append('Setup would be %d bytes; fctd_epsi overflows above ~%d' % (size, MAX_SETUP_BYTES))

    # Warnings
    veh, flag = str(values.get('vehicle', '')).upper(), values.get('fish_flag')
    if flag == 'FCTD' and ('MAKO' in veh or 'EPSI' in veh):
        warnings.append('Vehicle %s looks like a Mako, but fish type is FCTD' % values.get('vehicle'))
    elif flag == 'EPSI' and 'FCTD' in veh:
        warnings.append('Vehicle %s looks like an FCTD, but fish type is EPSI' % values.get('vehicle'))
    spool = str(values.get('winch_spool', '') or '').strip()
    previous_spool = str(values.get('previous_winch_spool', '') or '').strip()
    if not on_winch_spool(values):
        warnings.append('Lab test (not on the winch spool) - left out of the cruise twist count. '
                        'Switch to ON THE WINCH SPOOL for a deployment on the cable.')
    elif not spool:
        warnings.append('No winch spool set - the cruise twist count needs it')
    elif previous_spool and spool != previous_spool:
        warnings.append('Winch spool changed from %s to %s - the twist count restarts from 0 at this deployment'
                        % (previous_spool, spool))
    # Calibration files, looked up the way fctd_epsi does (ctd.c InitFishCTD):
    # slots 1-2 in the FP07 folder and slots 3-4 in the shear folder (by slot,
    # not sensor type), as <folder>/<SN>/Calibration_<SN>.txt, and the CTD as
    # <CTD folder>/<SN>.CAL. A missing file isn't fatal - fctd_epsi records
    # N/A for that probe in the .modraw header.
    v = setup_values(values)
    cal_root = str(values.get('calibrations_root', '')).rstrip('/')
    if cal_root and not os.path.isdir(cal_root):
        warnings.append('Calibrations folder not found: %s' % cal_root)
    else:
        for key, sub in CAL_SUBFOLDERS.items():
            d = v.get(key, '')
            if key in NO_CAL_WARNING:
                continue
            if d and not os.path.isdir(d):
                warnings.append('Calibrations folder has no %s/ - %s' % (sub, d))
    for i in range(1, 5):
        t, sn = v.get('ch%d_type' % i), v['ch%d_sn' % i]
        d = v.get('fpo7_cal_path' if i <= 2 else 'shear_cal_path', '')
        if t == 'shear' and d and os.path.isdir(d) \
                and not os.path.isfile(os.path.join(d, sn, 'Calibration_%s.txt' % sn)):
            warnings.append('Slot %d (%s): no %s/%s/Calibration_%s.txt - fctd_epsi will record N/A for it'
                            % (i, names[i - 1], d, sn, sn))
    if cal_root and os.path.isdir(cal_root) \
            and any(v.get('ch%d_type' % i) == 'shear' for i in range(1, 5)) \
            and not os.path.isfile(os.path.join(cal_root, SHEAR_CHARGEAMP_FILE)):
        warnings.append('No %s in the calibrations folder - processing would compute epsilon without '
                        'the shear charge-amp correction (copy it from MOD_fish_calibrations)'
                        % SHEAR_CHARGEAMP_FILE)
    # fctd_epsi and processing (MODsetup_read_yaml.m) both read <root>/SBE/<SN>.CAL
    ctd_dir, ctd_sn = v.get('ctd_cal_path', ''), v.get('ctd_sn', '')
    if ctd_dir and ctd_sn and os.path.isdir(ctd_dir) and not os.path.isfile(os.path.join(ctd_dir, ctd_sn + '.CAL')):
        warnings.append('CTD %s: no %s/%s.CAL - fctd_epsi records no CTD calibration and processing stops'
                        % (ctd_sn, ctd_dir, ctd_sn))
    if config:
        setup_dir = config.get('setup_dir', '')
        if setup_dir and os.path.exists(os.path.join(setup_dir, '.Setup.swp')):
            warnings.append('Setup is open in vi somewhere (.Setup.swp exists) - saving from vi would undo this')
        # Same survey name as the Setup being replaced - fine for a restart,
        # but usually means the name wasn't updated for a new deployment
        old = os.path.join(setup_dir, 'Setup') if setup_dir else ''
        if old and os.path.isfile(old) and values.get('survey') \
                and parse_setup(old).get('CTD.survey') == values.get('survey'):
            warnings.append('Survey name %s is the same as in the current Setup - new deployment? '
                            'Update the survey name.' % values.get('survey'))
    if os.path.isdir('/dev'):
        for name in ('ctd_port', 'command_port', 'pcode_port'):
            flag = OPTIONAL_FLAGS.get(name)
            if flag and not values.get(flag, True):
                continue
            p = values.get(name, '')
            if p.startswith('/dev/') and not os.path.exists(p):
                warnings.append('%s %s is not plugged in on this computer' % (name, p))
    return errors, warnings


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------
def _line(key, val, on=True):
    return "%s%s='%s'" % ('' if on else '%', key, val)


def _num(key, val, on=True):
    return '%s%s=%s' % ('' if on else '%', key, val)


def render_setup(values):
    """Setup text in fctd_epsi's format. Same key order as the hand-edited
    files; one comment line only (provenance), because the whole file goes
    into every .modraw header (MAX_SETUP_BYTES)."""
    v = setup_values(values)
    pcode_on = bool(v.get('pcode_in_use', True))
    udp_on = bool(v.get('udp_in_use', True))
    L = [
        '% Written by start_new_deployment.py ' + datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')
        + ' - edit with the Start New Deployment window',
        _num('TCPIPSocket.portnum', v['tcpip_port']),
        _num('UDPSocket.portnum', v['udp_port'], udp_on),
        _line('CTD.survey', v['survey']),
        _line('CTD.experiment', v['experiment']),
        _line('CTD.cruise', v['cruise']),
        _line('CTD.vehicle', v['vehicle']),
        _line('CTD.fish_pc', v['fish_pc']),
        _line('CTD.fishflag', v['fish_flag']),
        _line('CTD.SerialNum', v['ctd_sn']),
        _line('CTD.shear_Probecal_path', v['shear_cal_path']),
        _line('CTD.FPO7_Probecal_path', v['fpo7_cal_path']),
        _line('CTD.CTD_cal_path', v['ctd_cal_path']),
        _line('CTD.MicroCond', v.get('microcond_sn', '')),
        _line('CTD.Compass', v.get('compass_sn', '')),
    ]
    for i in range(1, 5):
        L.append(_line('CTD.ch%d_type' % i, v['ch%d_type' % i]))
        L.append(_line('CTD.ch%d_sn' % i, v['ch%d_sn' % i]))
    L += [
        _num('CTD.printData', v['print_data']),
        _num('CTD.engDispRate', v['eng_disp_rate']),
        _line('CTD.CTDPortName', v['ctd_port']),
        _line('CTD.CommandPortName', v['command_port']),
        _num('CTD.speed', v['speed']),
        _num('CTD.CTDlength', v['ctd_length']),
        _num('CTD.output_format', v['output_format']),
        _line('PCode.PCodePortName', v['pcode_port'], pcode_on),
        _num('PCode.speed', v['pcode_speed'], pcode_on),
        _line('Ascii_dataFile.runname', v['runname']),
        _line('Ascii_dataFile.path', v['data_path']),
        _num('Ascii_dataFile.dataFileSize', v['file_size']),
    ]
    return '\n'.join(L) + '\n'


def render_dev1_setup_yml(values, config):
    """dev1_setup.yml: what's on the vehicle, written on DEV1 when the
    deployment starts - the first piece of the processing metadata (read with
    MODsetup_read_yaml.m), not the full set (no PROCESS parameters). All 7 AFE
    slots are listed in order - PROCESS.channels is positional - and a slot
    with no sensor keeps its standard name with type: none."""
    survey = values['survey']
    data_root = config.get('processed_root', '').rstrip('/') + '/' + survey
    names = slot_names(values)
    now = datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')

    def yq(s):
        return "'%s'" % str(s).replace("'", "''")

    L = [
        '# dev1_setup.yml - written on DEV1 by start_new_deployment.py %s for survey %s.' % (now, survey),
        '# The deployment\'s first processing metadata; processing parameters are not in here.',
        '# Same values as the Setup file fctd_epsi recorded into each .modraw header.',
        '# data_root is the only path in this file - raw/, L0/, L1/, meta/ are derived from it.',
        'data_root: %s' % yq(data_root),
        'calibrations_root: %s' % yq(str(values.get('calibrations_root', '')).rstrip('/')),
        'survey_name: %s' % yq(survey),
        'cruise: %s' % yq(values.get('cruise', '')),
        'experiment: %s' % yq(values.get('experiment', '')),
        'vehicle_name: %s' % yq(values.get('vehicle', '')),
        'winch_spool: %s # one spool for every vehicle; twist restarts when it changes'
        % yq(values.get('winch_spool', '') if on_winch_spool(values) else ''),
        'on_winch_spool: %s # false: a lab test, left out of the cruise twist count'
        % ('true' if on_winch_spool(values) else 'false'),
        'pressure_case: %s' % yq(values.get('fish_pc', '')),
        'fish_flag: %s # EPSI or FCTD' % values['fish_flag'],
        'profiling_direction: %s # for turbulence data, up or down' % values.get('profiling_direction', 'down'),
        'latitude: %s # used for ctd.z when no GPS fix is available' % values.get('latitude', '0'),
        '',
        'instrument_manifest:',
        '  ctd:',
        '    sn: %s' % yq(values.get('ctd_sn', '')),
        '  afe:',
    ]
    for i in range(4):
        t = values.get('ch%d_type' % (i + 1), 'none')
        sn = values.get('ch%d_sn' % (i + 1), '') if t != 'none' else ''
        entry = '{name: %s, type: %s' % (names[i], t)
        if sn:
            entry += ', sn: %s' % yq(sn)
        L.append('    channel_%d: %s}' % (i + 1, entry))
    for i, n in enumerate(['a1', 'a2', 'a3']):
        L.append('    channel_%d: {name: %s, type: acc}' % (i + 5, n))
    for flag in ('alt', 'fluor'):
        if values.get(flag):
            L.append('  %s: true' % flag)
    L += ['', 'afe:', '  channels:']
    for n in names + ['a1', 'a2', 'a3']:
        fr, conf = AFE_CHANNEL_SETTINGS.get(n, (2.5, 'Bipolar'))
        L.append('    %s: {full_range: %s, ADCconf: %s}' % (n, fr, conf))
    return '\n'.join(L) + '\n'


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------
def _atomic_write(path, text):
    tmp = path + '.tmp_%d' % os.getpid()
    with open(tmp, 'w') as f:
        f.write(text)
    os.replace(tmp, path)


def _unused_path(path):
    """path, or path_2, path_3, ... if it already exists (never overwrite a backup)."""
    out, k = path, 2
    while os.path.exists(out):
        out, k = '%s_%d' % (path, k), k + 1
    return out


def setup_diff(setup_path, new_text):
    old = ''
    if os.path.isfile(setup_path):
        with open(setup_path, 'r', errors='replace') as f:
            old = f.read()
    return ''.join(difflib.unified_diff(old.splitlines(True), new_text.splitlines(True),
                                        'current Setup', 'new Setup'))


def check_roundtrip(setup_path, values):
    """Re-read a written Setup with the fctd_epsi tokenizer; return mismatches."""
    parsed = parse_setup(setup_path)
    v = setup_values(values)
    bad = []
    for key, (name, _, _) in SETUP_KEYS.items():
        flag = OPTIONAL_FLAGS.get(name)
        if flag and not v.get(flag, True):
            continue
        if parsed.get(key) != str(v.get(name, '')):
            bad.append('%s: wrote "%s", reads back as "%s"' % (key, v.get(name), parsed.get(key)))
    return bad


def dev1_setup_yml_path(values, config):
    """dev1_setup.yml goes in <processed_root>/<survey>/meta/. processed_root is a
    network path (e.g. /Volumes/DEV3_HD/...) that's the same from every computer."""
    return os.path.join(config['processed_root'], values['survey'], 'meta', 'dev1_setup.yml')


def on_winch_spool(values):
    """Whether this deployment is on the winch spool (the window's box); a
    value from before the switch existed counts as on the spool."""
    v = values.get('on_winch_spool', True)
    return str(v).strip().lower() not in ('false', '0', 'no', '')


SPOOL_LOG_FIELDS = ['datetime_utc', 'spool_id', 'spool_length_m', 'notes']
SPOOL_LOG_COMMENT = ('# Winch spool changes for the cruise (one winch, one spool at a time, every vehicle). '
                     'Start New Deployment adds a row when the spool changes; add a row by hand for a change '
                     'made mid-deployment.')


def spool_log_path(config):
    """Cruise-wide spool_swap_log.csv, next to the survey folders."""
    root = config.get('processed_root', '')
    return os.path.join(root, 'spool_swap_log.csv') if root else ''


def last_logged_spool(config):
    """spool_id of the last row in the cruise spool_swap_log.csv ('' if none)."""
    path = spool_log_path(config)
    if not path or not os.path.isfile(path):
        return ''
    with open(path, newline='') as f:
        rows = [r for r in csv.reader(f) if r and not r[0].startswith('#')]
    if len(rows) < 2 or rows[0][:2] != SPOOL_LOG_FIELDS[:2]:
        return ''
    return rows[-1][1].strip()


def log_spool_change(values, config, survey):
    """Append a row to the cruise spool_swap_log.csv when the winch spool
    differs from its last row (or it's the first spool logged). Returns the
    path written, or ''. The twist count restarts at this time."""
    path = spool_log_path(config)
    spool = str(values.get('winch_spool', '') or '').strip()
    if not path or not spool or not on_winch_spool(values):
        return ''
    previous = last_logged_spool(config)
    if spool == previous:
        return ''
    new_file = not os.path.isfile(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'a', newline='') as f:
        if new_file:
            f.write(SPOOL_LOG_COMMENT + '\n')
            csv.writer(f).writerow(SPOOL_LOG_FIELDS)
        note = ('changed from %s by Start New Deployment, survey %s' % (previous, survey) if previous
                else 'first spool logged, by Start New Deployment, survey %s' % survey)
        csv.writer(f).writerow([datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'), spool, '', note])
    return path


LOG_FIELDS = ['utc_written', 'survey', 'vehicle', 'winch_spool', 'on_winch_spool', 'fish_flag', 'fish_pc', 'ctd_sn',
              'ch1_type', 'ch1_sn', 'ch2_type', 'ch2_sn', 'ch3_type', 'ch3_sn',
              'ch4_type', 'ch4_sn', 'microcond_sn', 'experiment', 'cruise',
              'setup_backup', 'dev1_setup_yml']


def write_all(values, config, write_yml=True):
    """Back up the current Setup, write the new one (atomically), check it
    reads back correctly, write dev1_setup.yml and append to the
    deployment log. Returns a dict describing what was written. Raises
    ValueError if validation fails or the Setup doesn't read back."""
    errors, _ = validate(values, config)
    if errors:
        raise ValueError('\n'.join(errors))
    setup_dir = config['setup_dir']
    setup_path = os.path.join(setup_dir, 'Setup')
    text = render_setup(values)
    stamp = datetime.datetime.utcnow().strftime('%Y%m%d%H%M%S')
    result = {'setup': setup_path, 'backup': '', 'yml': '', 'log': '', 'spool_log': ''}

    if os.path.isfile(setup_path):
        backup = _unused_path(os.path.join(setup_dir, 'Setup_replaced_' + stamp))
        with open(setup_path, 'rb') as f:
            old = f.read()
        with open(backup, 'wb') as f:
            f.write(old)
        result['backup'] = backup
    _atomic_write(setup_path, text)
    bad = check_roundtrip(setup_path, values)
    if bad:
        raise ValueError('Setup was written but does not read back correctly:\n' + '\n'.join(bad))

    if write_yml and config.get('processed_root'):
        yml_path = dev1_setup_yml_path(values, config)
        os.makedirs(os.path.dirname(yml_path), exist_ok=True)
        if os.path.isfile(yml_path):
            os.replace(yml_path, _unused_path(yml_path + '.replaced_' + stamp))
        _atomic_write(yml_path, render_dev1_setup_yml(values, config))
        result['yml'] = yml_path

    log_path = config.get('deployment_log', '')
    if log_path:
        v = setup_values(values)
        row = {k: v.get(k, '') for k in LOG_FIELDS}
        row['utc_written'] = datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')
        row['setup_backup'] = os.path.basename(result['backup'])
        row['dev1_setup_yml'] = result['yml']
        row['on_winch_spool'] = 'true' if on_winch_spool(v) else 'false'
        if not on_winch_spool(v):
            row['winch_spool'] = ''  # as in dev1_setup.yml
        d = os.path.dirname(log_path)
        if d:
            os.makedirs(d, exist_ok=True)
        # An existing log with different columns (e.g. from before winch_spool was
        # added) is set aside, so rows never land under the wrong headers
        if os.path.isfile(log_path):
            with open(log_path, newline='') as f:
                header = next(csv.reader(f), None)
            if header != LOG_FIELDS:
                old = _unused_path(log_path[:-4] + '_old_columns.csv' if log_path.endswith('.csv')
                                   else log_path + '_old_columns')
                os.replace(log_path, old)
                result['log_rotated'] = old
        new_file = not os.path.isfile(log_path)
        with open(log_path, 'a', newline='') as f:
            w = csv.DictWriter(f, fieldnames=LOG_FIELDS)
            if new_file:
                w.writeheader()
            w.writerow(row)
        result['log'] = log_path
    result['spool_log'] = log_spool_change(values, config, values['survey'])
    return result


# --------------------------------------------------------------------------
# Lists for dropdowns
# --------------------------------------------------------------------------
def list_probe_sns(d):
    """Probe serial numbers = the subfolders of a calibration folder."""
    if not d or not os.path.isdir(d):
        return []
    return sorted((n for n in os.listdir(d) if os.path.isdir(os.path.join(d, n)) and not n.startswith('.')),
                  key=lambda s: (len(s), s))


def list_ctd_sns(sbecal_dir):
    if not sbecal_dir or not os.path.isdir(sbecal_dir):
        return []
    return sorted(os.path.splitext(n)[0] for n in os.listdir(sbecal_dir) if n.upper().endswith('.CAL'))


def list_serial_ports():
    return sorted(glob.glob('/dev/tty.usbserial-*'))
