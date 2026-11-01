function data = MODprocess_single_L0_to_L1(L0_data, metadata, external_ctd)
% MODprocess_single_L0_to_L1        Part of MOD_fish_processing
%
% data = MODprocess_single_L0_to_L1(L0_data, metadata, external_ctd)
%
% DESCRIPTION
%   Converts one file's L0 struct (raw counts/hex, from
%   MODprocess_single_modraw_to_L0.m) into physical units:
%     epsi   - re-applies setup.yml's EFE channel names/config: L0 is
%              already in volts/g using the standard EFE board (or
%              whatever metadata L0 was given), so the exact counts are
%              recovered from L0_data.epsi_conversion and reconverted
%              with this metadata (mod_efe_counts_to_volts_g.m). With a
%              standard board this only renames repurposed slots (e.g.
%              s2 -> c1). Older L0 files that still hold raw channel1..N
%              counts are converted directly. data.epsi_conversion is
%              updated to match.
%     ctd    - raw hex -> P/T/C/SP (SBE49 only - SBE41 arrives from L0
%              already in physical units) with L0_data.ctd_cal (the
%              file's $DCAL, else the .CAL file; ctd.cal_source says
%              which), plus derived dPdt, z, dzdt (always; the rates
%              from P and z low-passed at PROCESS.L1.dzdt_lowpass_s - see
%              lowpass_rate below) and SP, SR, CT, sigma0 (only when T/C are actually
%              present - see process_ctd_fields below). For vehicles with
%              no $SB49/$SB41 blocks at all (DeepSolo, Wirewalker),
%              external_ctd substitutes for L0_data.ctd instead - see
%              INPUTS.
%     alt, isap - raw distance -> height above bottom (hab)
%     accel  - new: the std of each EFE accelerometer channel
%              (epsi.a<n>_g) over windows of PROCESS.L1.accel_std_s
%              seconds (see accel_std below); [] without one
%     vnav   - attitude added as vnav.tilt/spin/pitch/roll/yaw
%              (mod_L1_add_vnav_attitude.m), and the cable twist count
%              as data.twist (mod_L1_add_twist.m), computed after ctd so
%              twist.pressure can be interpolated from it
%   Every other field (gps, seg, spec, ...) passes through
%   unchanged. Pure transformation - no file I/O, no metadata mutation
%   (external_ctd is read and time-sliced by the caller, not by this
%   function - see MODprocess_all_L0_to_L1.m).
%
%   Ported from mod_som_read_epsi_files_v4.m's physical-conversion logic
%   (MOD_fish_lib), which mixed raw parsing and calibration in one pass.
%   The raw parsing half is now MODprocess_single_modraw_to_L0.m; this is
%   the calibration half.
%
% INPUTS
%   L0_data   - struct from MODprocess_single_modraw_to_L0.m (or loaded
%               from an L0 .mat file)
%   metadata  - metadata struct (from MODsetup_read_yaml.m)
%               Uses: metadata.PROCESS.channels, metadata.PROCESS.latitude,
%                     metadata.PROCESS.L1.accel_std_s (only with an
%                     accelerometer channel; checked by the caller),
%                     metadata.PROCESS.L1.dzdt_lowpass_s (only with a
%                     CTD; checked by the caller),
%                     metadata.AFE.(channel).full_range/.ADCconf/.type
%                     (any missing -> standard EFE, see mod_efe_conversion.m),
%                     metadata.GEOMETRY.alt_angle_deg/.alt_dist_from_crashguard_ft/
%                     .alt_probe_dist_from_crashguard_in
%   external_ctd - (optional) struct with dnum/P always, and T/C/(S) only
%               if the source vehicle's file reports them (DeepSolo's
%               fallrise file doesn't - P only), already sliced to this L0
%               file's time range, from MODprocess_read_external_ctd.m via
%               MODprocess_all_L0_to_L1.m. Only used when L0_data.ctd is
%               empty (true for DeepSolo/Wirewalker, which have no
%               $SB49/$SB41 blocks to parse at L0) - ignored otherwise.
%               []/omitted for vehicles with no independent CTD file.
%
% OUTPUTS
%   data      - same fields as L0_data, with epsi/ctd/alt/isap converted
%               to physical units, vnav.tilt/spin added and vnav.pitch/
%               roll/yaw filled (mod_L1_add_vnav_attitude.m), and
%               data.twist and data.accel added, as described above
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   toolbox/seawater/gsw/gsw_SP_from_C.m, gsw_SR_from_SP.m, gsw_CT_from_t.m,
%   gsw_sigma0.m, gsw_z_from_p.m
%   mod_L1_add_vnav_attitude.m, mod_L1_add_twist.m
%   mod_efe_volts_g_to_counts.m, mod_efe_counts_to_volts_g.m
%   (local subfunctions: apply_setup_efe, accel_std, process_ctd_fields, lowpass_rate,
%   calibrate_altimeter_hab)
%
% NOTES
%   The subfunctions below are local rather than separate files - they are
%   never called except from here, so PLAN.md's "pure transformation
%   function per file" principle doesn't apply to them individually.
%   If a later step needs modProcess_L1_apply_ctd_calibration.m etc. as
%   standalone, testable functions, split them out then.
%
%   Height-above-bottom (hab) uses the same GEOMETRY fields for both the
%   MOD altimeter (alt) and the ISA500 (isap) - inherited as-is from
%   mod_som_read_epsi_files_v4.m, which assumed the same mount geometry
%   for both. Verified against real alt data in data_for_reorg/epsi_mako/
%   blt2021_0715, in addition to isap - see docs/workflow/
%   L0_to_L1_conversion.md's altimeter hab math section.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 3
    external_ctd = [];
end

toolbox_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'seawater');
addpath(toolbox_dir);
gsw_dir = fullfile(toolbox_dir, 'gsw');
addpath(gsw_dir);
addpath(fullfile(gsw_dir, 'library'));
addpath(fullfile(gsw_dir, 'thermodynamics_from_t'));

data = L0_data;

%% EFE channels: re-apply setup.yml's names/config (volts/g)
if ~isempty(data.epsi)
    [data.epsi, data.epsi_conversion] = apply_setup_efe(data, metadata);
elseif ~isfield(data, 'epsi_conversion')
    data.epsi_conversion = [];
end

%% Accelerometers: std over accel_std_s windows
data.accel = [];
if ~isempty(data.epsi)
    data.accel = accel_std(data.epsi, metadata);
end

%% CTD: raw hex -> physical P/T/C/S, plus derived fields
if ~isempty(data.ctd)
    gps = [];
    if isfield(data, 'gps')
        gps = data.gps;
    end
    cal = [];
    if isfield(data, 'ctd_cal')
        cal = data.ctd_cal;
    end
    data.ctd = process_ctd_fields(data.ctd, gps, metadata, cal);
elseif ~isempty(external_ctd)
    % DeepSolo/Wirewalker: no $SB49/$SB41 blocks in L0_data, so data.ctd
    % is empty here. external_ctd arrives already in physical units
    % (dnum/P, optionally T/C/(S) - see MODprocess_read_external_ctd.m),
    % so it only needs the derived-field half of process_ctd_fields
    % (th/sgth/dPdt/z/dzdt, plus S if the source file didn't already
    % report it) - the same path SBE41 takes. DeepSolo's fallrise file has
    % no T/C at all, so th/sgth/S are correctly skipped for it (see
    % process_ctd_fields below).
    gps = [];
    if isfield(data, 'gps')
        gps = data.gps;
    end
    data.ctd = process_ctd_fields(external_ctd, gps, metadata, []);
end

%% Altimeter / ISA500: raw distance -> height above bottom
if ~isempty(data.alt) && isfield(data.alt, 'dst')
    data.alt.hab = calibrate_altimeter_hab(data.alt.dst, metadata);
end
if ~isempty(data.isap) && isfield(data.isap, 'dst')
    data.isap.hab = calibrate_altimeter_hab(data.isap.dst, metadata);
end

%% VecNav: attitude (tilt, spin, pitch, roll, yaw), then the cable twist
% count (needs data.ctd already calibrated, for twist.pressure)
if isfield(data, 'vnav') && ~isempty(data.vnav)
    data.vnav = mod_L1_add_vnav_attitude(data.vnav);
    data = mod_L1_add_twist(data);
end

end %end function

%% Accelerometer std: accel.dnum (each window's mean time) and
% accel.<ch>_std [g] for every epsi.a<n>_g, one value per window of
% PROCESS.L1.accel_std_s seconds with 2 or more finite samples. Windows
% are counted from datenum 0, so they fall in the same place whichever L1
% file holds the samples (one split by a file boundary is two partial
% windows). [] without an accelerometer channel.
function accel = accel_std(epsi, metadata)
accel = [];
names = fieldnames(epsi);
channels = names(~cellfun(@isempty, regexp(names, '^a\d+_g$', 'once')));
if isempty(channels) || ~isfield(epsi, 'dnum') || isempty(epsi.dnum)
    return
end
if ~isfield(metadata, 'PROCESS') || ~isfield(metadata.PROCESS, 'L1') || ~isfield(metadata.PROCESS.L1, 'accel_std_s')
    error('MODprocess_single_L0_to_L1:noAccelWindow', ['l1.accel_std_s is not set - add it to the ' ...
        'yml (MODsetup_metadata_field_registry.m).']);
end
win_s = metadata.PROCESS.L1.accel_std_s;
if ~(isscalar(win_s) && win_s > 0)
    error('MODprocess_single_L0_to_L1:badAccelWindow', 'l1.accel_std_s must be > 0 s (got %s).', mat2str(win_s));
end
t = epsi.dnum(:);
w = floor(t * 86400 / win_s);
ok = isfinite(w);
[~, ~, iw] = unique(w(ok)); % window of each sample
t = t(ok);
accel.dnum = accumarray(iw, t, [], @mean);
keep = accumarray(iw, 1) >= 2;
for ch = channels'
    x = epsi.(ch{1})(:);
    x = x(ok);
    good = isfinite(x);
    n = accumarray(iw(good), 1, size(keep));
    s = accumarray(iw(good), x(good), size(keep), @std, NaN);
    s(n < 2) = NaN;
    accel.([ch{1}(1:end - 2) '_std']) = s;
end
accel.dnum = accel.dnum(keep);
for ch = channels'
    f = [ch{1}(1:end - 2) '_std'];
    accel.(f) = accel.(f)(keep);
end
end

%% EFE: recover exact counts, reconvert with setup.yml's names/config
% L0 files written before EFE conversion moved to L0 still hold raw
% channel1..N counts - those go straight to mod_efe_counts_to_volts_g.
function [epsi, conversion] = apply_setup_efe(data, metadata)

epsi = data.epsi;
old_conversion = [];
if ~isfield(epsi, 'channel1')
    if ~isfield(data, 'epsi_conversion') || isempty(data.epsi_conversion)
        error('MODprocess_single_L0_to_L1:noEpsiConversion', ...
            ['L0 epsi has no raw channel1..N counts and no epsi_conversion record, ' ...
             'so its counts can''t be recovered. Regenerate this L0 file with ' ...
             'MODprocess_single_modraw_to_L0.m.']);
    end
    old_conversion = data.epsi_conversion;
    epsi = mod_efe_volts_g_to_counts(epsi, old_conversion);
end

[epsi, conversion] = mod_efe_counts_to_volts_g(epsi, metadata);

% Say when setup.yml changed anything relative to what L0 used - names are
% expected to change for repurposed slots; config should never differ on
% a standard EFE board.
if ~isempty(old_conversion)
    for slot = 1:numel(conversion.channels)
        new_c = conversion.channel.(conversion.channels{slot});
        old_c = old_conversion.channel.(old_conversion.channels{slot});
        if ~strcmp(new_c.field, old_c.field)
            fprintf('MODprocess_single_L0_to_L1: EFE slot %d renamed %s -> %s (setup.yml)\n', ...
                slot, old_c.field, new_c.field);
        end
        if new_c.scale ~= old_c.scale || new_c.offset ~= old_c.offset
            fprintf(['MODprocess_single_L0_to_L1: EFE slot %d (%s) reconverted with setup.yml config ' ...
                '(%s, %g V) instead of L0''s (%s, %g V)\n'], ...
                slot, new_c.field, new_c.ADCconf, new_c.full_range, old_c.ADCconf, old_c.full_range);
        end
    end
end

end

%% CTD: calibrate raw SBE49 counts into P/T/C when present, then derive
% secondary fields unconditionally (or as far as the available fields
% allow - see the T/C guard below). "process" rather than "calibrate"
% because for SBE41/external-CTD sources, which arrive already in physical
% units, this function does no calibration at all - only derivation.
function ctd = process_ctd_fields(ctd, gps, metadata, cal)

% External CTD chunks (DeepSolo/Wirewalker - see MODprocess_read_external_ctd.m)
% arrive with only dnum, not time_s. time_s is just dnum in seconds on
% MATLAB's day-zero epoch (matches convert_timestamp.m in
% MODprocess_single_modraw_to_L0.m: time_s == dnum*86400 exactly), so
% it's cheaper to derive here than to require every CTD source to supply
% it. No-op for L0-sourced ctd, which already has time_s set.
if ~isfield(ctd, 'time_s')
    ctd.time_s = ctd.dnum*86400;
end

if isfield(ctd, 'T_raw')
    % SBE49 "eng" format - counts need the SBE calibration polynomials,
    % from the L0 file's ctd_cal (its $DCAL, else the .CAL file - see
    % MODprocess_all_modraw_to_L0.m). SBE41 "PTS" format arrives from L0
    % with P/T/S/C already ASCII-parsed, so this block is skipped for it.
    if isempty(cal)
        error('MODprocess_single_L0_to_L1:noCtdCalibration', ['This L0 file has SBE49 counts but no ' ...
            'ctd_cal - redo it with MODprocess_all_modraw_to_L0.m.']);
    end

    mv = (ctd.T_raw - 524288)/1.6e7;
    r = (mv*2.295e10 + 9.216e8)./(6.144e4 - mv*5.3e5);
    ctd.T = cal.ta0 + cal.ta1*log(r) + cal.ta2*log(r).^2 + cal.ta3*log(r).^3;
    ctd.T = 1./ctd.T - 273.15 + cal.toffset;

    y = ctd.PT_raw/13107;
    t = cal.ptempa0 + cal.ptempa1*y + cal.ptempa2*y.^2;
    x = ctd.P_raw - cal.ptca0 - cal.ptca1*t - cal.ptca2*t.^2;
    n = x.*cal.ptcb0./(cal.ptcb0 + cal.ptcb1*t + cal.ptcb2*t.^2);
    ctd.P = (cal.pa0 + cal.pa1*n + cal.pa2*n.^2 - 14.7)*0.689476 + cal.poffset;

    f = ctd.C_raw/256/1000;
    ctd.C = cal.cslope*(cal.g + cal.h*f.^2 + cal.i*f.^3 + cal.j*f.^4)./(1 + cal.tcor.*ctd.T + cal.pcor.*ctd.P);
    ctd.cal_source = cal.source;
end

if isfield(ctd, 'T') && isfield(ctd, 'C')
    if ~isfield(ctd, 'SP') || isempty(ctd.SP)
        % Not reported by the source (SBE41 "PTS" and external CTD files
        % normally do report SP already, and skip this) - derive it the
        % same way the SBE49 "eng" path does. ctd.C is S/m; gsw_SP_from_C
        % wants conductivity in mS/cm.
        ctd.SP = gsw_SP_from_C(ctd.C*10, ctd.T, ctd.P);
    end

    % Reference Salinity (SR ~= SA, the shortcut used throughout this repo
    % for GSW's Absolute-Salinity-family inputs - see
    % docs/concepts/units_and_seawater.md) is computed once here and
    % persisted, not re-derived ad hoc by every downstream consumer.
    ctd.SR = gsw_SR_from_SP(ctd.SP);

    ctd.CT     = gsw_CT_from_t(ctd.SR, ctd.T, ctd.P);
    ctd.sigma0 = gsw_sigma0(ctd.SR, ctd.CT);
else
    % No T/C at all - e.g. DeepSolo's fallrise pressure file
    % (MODprocess_read_external_ctd.m), which reports only P. SP/SR/CT/
    % sigma0 genuinely can't be computed without temperature and
    % conductivity, so they're left unset rather than guessed. dPdt/z/dzdt
    % below only need P (and latitude for z), so they still get computed
    % either way.
end

if ~isfield(metadata, 'PROCESS') || ~isfield(metadata.PROCESS, 'L1') || ~isfield(metadata.PROCESS.L1, 'dzdt_lowpass_s')
    error('MODprocess_single_L0_to_L1:noDzdtLowpass', ['l1.dzdt_lowpass_s is not set - add it to the ' ...
        'yml (MODsetup_metadata_field_registry.m).']);
end
lowpass_s = metadata.PROCESS.L1.dzdt_lowpass_s;
if ~(isscalar(lowpass_s) && lowpass_s > 0)
    error('MODprocess_single_L0_to_L1:badDzdtLowpass', 'l1.dzdt_lowpass_s must be > 0 s (got %s).', mat2str(lowpass_s));
end
ctd.dPdt = lowpass_rate(ctd.P, ctd.time_s, lowpass_s);

% Depth from pressure needs latitude - interpolate from GPS fixes if any
% exist for this file, otherwise fall back to the deployment's static
% latitude from setup.yml.
if ~isempty(gps) && isfield(gps, 'latitude') && any(~isnan(gps.latitude))
    not_nan = ~isnan(gps.dnum) & ~isnan(gps.latitude);
    if nnz(not_nan) > 1
        lat = interp1(gps.dnum(not_nan), gps.latitude(not_nan), ctd.dnum, 'linear', 'extrap');
    else
        lat = gps.latitude(find(not_nan, 1));
    end
else
    lat = metadata.PROCESS.latitude;
end
% gsw_z_from_p returns height (negative down); this repo's z/dzdt
% convention is positive down (dzdt > 0 during descent) - negate to
% preserve it exactly.
ctd.z = -gsw_z_from_p(ctd.P, lat);
ctd.dzdt = lowpass_rate(ctd.z, ctd.time_s, lowpass_s);

end

%% Rate of change of a CTD record, low-passed: x through a zero-phase
% Butterworth filter (filtfilt) whose applied response is at half power
% at 1/lowpass_s, then the centred gradient against time. Single-pass
% Butterworth is at half power at Wn; filtfilt squares the response, so
% Wn is moved up to put the two-pass half power at the cutoff. The order
% only sets how sharp the roll-off is. A record too short to pad
% (filtfilt needs more than 3 * order samples), or sampled too sparsely
% for the cutoff (Wn >= 1: lowpass_s is about two samples or less, e.g.
% DeepSolo's pressure), uses x as it is. NaNs are filled for the filter
% and put back after.
function rate = lowpass_rate(x, time_s, lowpass_s)
x = x(:);
time_s = time_s(:);
rate = nan(size(x));
ok = isfinite(x) & isfinite(time_s);
if nnz(ok) < 2
    return
end
order = 4;
dt = median(diff(time_s(ok)));
Wn = (2 * dt / lowpass_s) / (sqrt(2) - 1)^(1 / (2 * order));
xs = x;
if Wn > 0 && Wn < 1 && nnz(ok) > 3 * order
    [b, a] = butter(order, Wn, 'low');
    xs(ok) = filtfilt(b, a, x(ok));
end
rate(ok) = gradient(xs(ok), time_s(ok));
end

%% Altimeter/ISA500 raw distance -> height above bottom
function hab = calibrate_altimeter_hab(dst, metadata)

if ~isfield(metadata, 'GEOMETRY')
    error('MODprocess_single_L0_to_L1:missingGeometry', ...
        ['Altimeter/ISAP raw data is present but metadata.GEOMETRY is not set - no altimeter: ' ...
         'block in this deployment''s setup.yml, and no matching entry in ' ...
         'setup/platform_instrument_geometry.yml for fish_flag=%s, vehicle_name=''%s''. Add one or ' ...
         'the other and reload metadata.'], metadata.fish_flag, metadata.vehicle_name);
end

feet2meters = @(x) x*0.3048;
inches2meters = @(x) x*0.0254;

theta = deg2rad(metadata.GEOMETRY.alt_angle_deg);
altimeter_height_above_probes = feet2meters(metadata.GEOMETRY.alt_dist_from_crashguard_ft) - ...
    inches2meters(metadata.GEOMETRY.alt_probe_dist_from_crashguard_in);

hab = dst*cos(theta) - altimeter_height_above_probes;

end
