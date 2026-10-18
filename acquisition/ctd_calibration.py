"""ctd_calibration - Part of MOD_fish_processing

Checks the SBE49 calibration in the calibrations folder (SBE/<SN>.CAL, what
fctd_epsi copies into every .modraw header) against the calibration the SBE
on the fish reports, and shear probe calibration dates. No GUI here -
start_new_deployment.py has the button; mod_setup_file.py uses shear_cal_date
for the shear calibration age warning.

The fish is asked with the SOM's sbe.dcal command (as MODSOM_liveplot does):
it's written to the command port and the $DCAL block comes back with the
data on the CTD port, both at CTD.speed (fctd_epsi opens both ports at that
speed). fctd_epsi must not be running - it holds the ports.

The parser is the Python twin of processing/L0/mod_L0_ctd_calibration.m:
coefficients by name, from either a $DCAL block ("SERIAL NO. 0387",
"TA0 = 8.436138e-04") or a .CAL file ("SERIALNO=0387", "TA0= 8.436138e-004").
"""

import datetime
import os
import re
import shutil
import subprocess
import time

# .CAL file keys in file order, with the field name the parser gives each
# (same names as mod_L0_ctd_calibration.m)
CAL_KEYS = [('TA0', 'ta0'), ('TA1', 'ta1'), ('TA2', 'ta2'), ('TA3', 'ta3'),
            ('CG', 'g'), ('CH', 'h'), ('CI', 'i'), ('CJ', 'j'), ('CTCOR', 'tcor'), ('CPCOR', 'pcor'),
            ('PA0', 'pa0'), ('PA1', 'pa1'), ('PA2', 'pa2'),
            ('PTCA0', 'ptca0'), ('PTCA1', 'ptca1'), ('PTCA2', 'ptca2'),
            ('PTCB0', 'ptcb0'), ('PTCB1', 'ptcb1'), ('PTCB2', 'ptcb2'),
            ('PTEMPA0', 'ptempa0'), ('PTEMPA1', 'ptempa1'), ('PTEMPA2', 'ptempa2')]
# names in a $DCAL block, where they differ from the .CAL file
DCAL_NAMES = {'g': 'G', 'h': 'H', 'i': 'I', 'j': 'J'}
# $DCAL only (no place for them in a .CAL file); value = no correction
EXTRA = {'toffset': ('TOFFSET', 0.0), 'cslope': ('CSLOPE', 1.0), 'poffset': ('POFFSET', 0.0)}
DATES = [('temp_date', r'temperature:\s*', r'TCALDATE\s*=\s*'),
         ('cond_date', r'conductivity:\s*', r'CCALDATE\s*=\s*'),
         ('pres_date', r'pressure[^\n]*?:\s*', r'PCALDATE\s*=\s*')]
DATE_LABELS = {'temp_date': 'temperature date', 'cond_date': 'conductivity date', 'pres_date': 'pressure date'}
# coefficients agreeing to this (relative) are the same number printed with
# different rounding ($DCAL vs .CAL print 7 digits each)
REL_TOL = 1e-6
DCAL_RE = re.compile(rb'\$DCAL[\s\S]+?\*[0-9A-Fa-f]{2}\r\n')


def parse(text):
    """SBE calibration from a $DCAL block or a .CAL file -> dict: sn, the three
    dates (datetime.date), coefficients (float). Raises ValueError if anything
    is missing."""
    cal = {}
    m = re.search(r"SERIAL\s*NO\.?\s*=?\s*'?(\d+)", text, re.I)
    if not m:
        raise ValueError('no SBE serial number')
    cal['sn'] = '%04d' % int(m.group(1))
    for key, dcal_pat, cal_pat in DATES:
        for pat in (dcal_pat, cal_pat):
            m = re.search(pat + r'(\d{1,2})-([A-Za-z]{3})-(\d{2,4})', text, re.I)
            if m:
                year = int(m.group(3))
                year += 2000 if year < 100 else 0
                cal[key] = datetime.datetime.strptime('%s-%s-%d' % (m.group(1), m.group(2).title(), year),
                                                      '%d-%b-%Y').date()
                break
        else:
            raise ValueError('no %s' % DATE_LABELS[key])
    for cal_name, field in CAL_KEYS:
        v = _number(text, (DCAL_NAMES.get(field, cal_name), cal_name))
        if v is None:
            raise ValueError('no %s' % cal_name)
        cal[field] = v
    for field, (name, default) in EXTRA.items():
        v = _number(text, (name,))
        cal[field] = default if v is None else v
    return cal


def _number(text, names):
    for name in names:
        m = re.search(r'(?m)^\s*%s\s*=\s*([-+0-9.eE]+)' % name, text)
        if m:
            return float(m.group(1))
    return None


def read_cal_file(path):
    with open(path, 'r', errors='replace') as f:
        return parse(f.read())


def compare(fish, disk):
    """Differences between the fish's calibration and the .CAL file, as
    (what, fish value, file value) rows; [] = same."""
    rows = []
    if fish['sn'] != disk['sn']:
        rows.append(('serial number', fish['sn'], disk['sn']))
    for key, _, _ in DATES:
        if fish[key] != disk[key]:
            rows.append((DATE_LABELS[key], _date_text(fish[key]), _date_text(disk[key])))
    for cal_name, field in CAL_KEYS:
        a, b = fish[field], disk[field]
        if abs(a - b) > REL_TOL * max(abs(a), abs(b)):
            rows.append((cal_name, '%.6e' % a, '%.6e' % b))
    return rows


def offsets(cal):
    """The $DCAL-only offsets that aren't 'no correction', as (name, value)
    rows - shown for information: a .CAL file can't hold them, and processing
    takes them from the survey's $DCAL."""
    return [(name, '%g' % cal[field]) for field, (name, default) in EXTRA.items() if cal[field] != default]


def _date_text(d):
    return d.strftime('%d-%b-%y')


def _cal_number(v):
    """8.436138e-004 style, as in the SBE .CAL files: sign or space, 3-digit exponent."""
    mant, exp = ('%.6e' % abs(v)).split('e')
    return '%s%se%s%03d' % ('-' if v < 0 else ' ', mant, exp[0], abs(int(exp)))


def render_cal_file(cal):
    """A .CAL file (SBE's own layout, CRLF) for this calibration - same keys and
    order as the existing files, which fctd_epsi reads."""
    lines = ['SERIALNO=%s' % cal['sn']]
    for cal_name, field in CAL_KEYS:
        if cal_name == 'TA0':
            lines.append('TCALDATE=%s' % _date_text(cal['temp_date']))
        elif cal_name == 'CG':
            lines.append('CCALDATE=%s' % _date_text(cal['cond_date']))
        elif cal_name == 'PA0':
            lines.append('PCALDATE=%s' % _date_text(cal['pres_date']))
        lines.append('%s=%s' % (cal_name, _cal_number(cal[field])))
    return '\r\n'.join(lines) + '\r\n'


def write_cal_file(cal, sbe_dir):
    """Write <sbe_dir>/<SN>.CAL from cal. Returns (path, backup): backup is
    where the old file was kept (outside a git repo only - in
    MOD_fish_calibrations git has it), else ''."""
    path = os.path.join(sbe_dir, cal['sn'] + '.CAL')
    tmp = path + '.tmp'
    with open(tmp, 'w', newline='') as f:   # written first: a failed write leaves the old file
        f.write(render_cal_file(cal))
    backup = ''
    if os.path.isfile(path) and not _in_git_repo(sbe_dir):
        backup = path + '.bak'
        shutil.copy2(path, backup)
    os.replace(tmp, path)
    return path, backup


def _in_git_repo(d):
    try:
        return subprocess.run(['git', '-C', d, 'rev-parse', '--is-inside-work-tree'], capture_output=True,
                              text=True, timeout=10).stdout.strip() == 'true'
    except (OSError, subprocess.SubprocessError):
        return False


def read_dcal_from_fish(command_port, ctd_port, speed, timeout_s=5.0):
    """Ask the fish for its SBE calibration (sbe.dcal) and return the $DCAL
    block's text. Raises RuntimeError saying what went wrong."""
    try:
        import serial  # pyserial
    except ImportError:
        raise RuntimeError('This python3 has no pyserial - install it with: python3 -m pip install pyserial')
    if not command_port or not ctd_port:
        raise RuntimeError('No command or CTD data port set (Advanced: Serial ports)')
    try:
        speed = int(speed)
    except (TypeError, ValueError):
        raise RuntimeError('The CTD baud rate (Advanced: Serial ports) is not a number: %r' % speed)
    ports = []
    try:
        try:
            data = serial.Serial(ctd_port, speed, timeout=0.1, write_timeout=2, exclusive=True)
            ports.append(data)
            cmd = data
            if command_port != ctd_port:
                cmd = serial.Serial(command_port, speed, timeout=0.1, write_timeout=2, exclusive=True)
                ports.append(cmd)
        except (serial.SerialException, OSError, ValueError) as err:
            raise RuntimeError("Couldn't open the serial ports (is fctd_epsi running? quit it first): %s" % err)
        for p in ports:
            p.reset_input_buffer()
        try:
            cmd.write(b'sbe.dcal\r\n')  # no flush(): it waits for the port to drain, forever if it's stuck
        except serial.SerialTimeoutException:
            raise RuntimeError("Couldn't send sbe.dcal on %s (the port didn't take it)" % command_port)
        got = b''
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            for p in ports:
                got += p.read(4096)
            m = DCAL_RE.search(got)
            if m:
                return m.group(0).decode('ascii', errors='replace')
        raise RuntimeError('No $DCAL from the fish within %g s (is the fish powered and connected? %d bytes '
                           'came back)' % (timeout_s, len(got)))
    finally:
        for p in ports:
            p.close()


def shear_cal_date(cal_file):
    """Date of a probe's newest calibration: the last dated line of
    Calibration_<SN>.txt ("Tue Jan 16 14:49:46 2024, 39.50, 838.0"), or None."""
    try:
        with open(cal_file, 'r', errors='replace') as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        m = re.search(r'([A-Z][a-z]{2})\s+(\d{1,2})\s+[\d:]+\s+(\d{4})', line)
        if m:
            try:
                return datetime.datetime.strptime('%s %s %s' % m.groups(), '%b %d %Y').date()
            except ValueError:
                continue
    return None
