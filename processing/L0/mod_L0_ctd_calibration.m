function cal = mod_L0_ctd_calibration(text, source)
% mod_L0_ctd_calibration        Part of MOD_fish_processing
%
% cal = mod_L0_ctd_calibration(text, source)
%
% DESCRIPTION
%   Reads SBE49 calibration coefficients into one struct, from either:
%     - a .modraw $DCAL block: what the SBE itself reports (the SOM's
%       sbe.dcal command), e.g. "SERIAL NO. 0387", "temperature:  03-mar-25",
%       "    TA0 = 8.436138e-04", ...
%     - an SBE .CAL file (calibrations_root/SBE/<SN>.CAL): "SERIALNO=0387",
%       "TCALDATE=03-Mar-25", "TA0= 8.436138e-004", ...
%   Coefficients are found by name, not line order. The SBE calibration
%   block copied into the .modraw header ("as in Fish calibration file") is
%   never read: it's a copy of the computer's .CAL file, wrong whenever that
%   file wasn't updated.
%
% INPUTS
%   text   - the $DCAL block or the .CAL file's contents (char)
%   source - where it came from, kept as cal.source, e.g. '.modraw $DCAL'
%            or 'calibrations folder: <path>'
%
% OUTPUTS
%   cal - struct: SN (4 digits, e.g. '0387'); TempCal_date, CondCal_date,
%         PresCal_date (datetime); ta0-ta3, toffset; g, h, i, j, tcor, pcor,
%         cslope; pa0-pa2, ptca0-ptca2, ptcb0-ptcb2, ptempa0-ptempa2,
%         poffset; source; text (as read). A .CAL file has no toffset,
%         cslope or poffset: 0, 1, 0 (no correction).
%
% CALLED BY
%   MODprocess_single_modraw_to_L0.m ($DCAL), MODprocess_all_modraw_to_L0.m
%   (.CAL file, for a raw file without $DCAL)
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

text = char(text);
cal = struct();
sn = regexp(text, 'SERIAL\s*NO\.?\s*=?\s*''?(\d+)', 'tokens', 'once', 'ignorecase');
if isempty(sn)
    error('mod_L0_ctd_calibration:noSerialNumber', 'No SBE serial number in the calibration from %s.', source);
end
cal.SN = sprintf('%04d', str2double(sn{1}));

% $DCAL: "temperature:  03-mar-25"; .CAL: "TCALDATE=03-Mar-25"
cal.TempCal_date = cal_date(text, {'temperature:\s*', 'TCALDATE\s*=\s*'}, source);
cal.CondCal_date = cal_date(text, {'conductivity:\s*', 'CCALDATE\s*=\s*'}, source);
cal.PresCal_date = cal_date(text, {'pressure[^\n]*?:\s*', 'PCALDATE\s*=\s*'}, source);

% field name -> names in the text ($DCAL first, then .CAL)
names = { ...
    'ta0', {'TA0'}; 'ta1', {'TA1'}; 'ta2', {'TA2'}; 'ta3', {'TA3'}; ...
    'g', {'G', 'CG'}; 'h', {'H', 'CH'}; 'i', {'I', 'CI'}; 'j', {'J', 'CJ'}; ...
    'tcor', {'CTCOR'}; 'pcor', {'CPCOR'}; ...
    'pa0', {'PA0'}; 'pa1', {'PA1'}; 'pa2', {'PA2'}; ...
    'ptca0', {'PTCA0'}; 'ptca1', {'PTCA1'}; 'ptca2', {'PTCA2'}; ...
    'ptcb0', {'PTCB0'}; 'ptcb1', {'PTCB1'}; 'ptcb2', {'PTCB2'}; ...
    'ptempa0', {'PTEMPA0'}; 'ptempa1', {'PTEMPA1'}; 'ptempa2', {'PTEMPA2'}};
for k = 1:size(names, 1)
    cal.(names{k, 1}) = coefficient(text, names{k, 2}, source, NaN);
end
cal.toffset = coefficient(text, {'TOFFSET'}, source, 0);
cal.cslope  = coefficient(text, {'CSLOPE'}, source, 1);
cal.poffset = coefficient(text, {'POFFSET'}, source, 0);

cal.source = source;
cal.text = text;
end %end function

%% "NAME = value" or "NAME= value" at the start of a line; default when
% missing (NaN = required)
function v = coefficient(text, keys, source, default)
for k = 1:numel(keys)
    tok = regexp(text, ['(?m)^\s*' keys{k} '\s*=\s*([-+0-9.eE]+)'], 'tokens', 'once');
    if ~isempty(tok)
        v = str2double(tok{1});
        return
    end
end
if isnan(default)
    error('mod_L0_ctd_calibration:missingCoefficient', 'No %s in the SBE calibration from %s.', keys{1}, source);
end
v = default;
end

%% calibration date (dd-mmm-yy, any case) after one of the patterns
function d = cal_date(text, patterns, source)
for k = 1:numel(patterns)
    tok = regexp(text, [patterns{k} '(\d{1,2}-[A-Za-z]{3}-\d{2,4})'], 'tokens', 'once', 'ignorecase');
    if ~isempty(tok)
        p = strsplit(tok{1}, '-');
        p{2} = [upper(p{2}(1)) lower(p{2}(2:3))]; % 03-mar-25 -> 03-Mar-25
        fmt = 'd-MMM-yy';
        if numel(p{3}) == 4
            fmt = 'd-MMM-yyyy';
        end
        d = datetime(strjoin(p, '-'), 'InputFormat', fmt, 'Locale', 'en_US');
        return
    end
end
error('mod_L0_ctd_calibration:missingDate', 'No calibration date (%s) in the SBE calibration from %s.', ...
    patterns{end}, source);
end
