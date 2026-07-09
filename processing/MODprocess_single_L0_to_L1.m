function data = MODprocess_single_L0_to_L1(L0_data, metadata)
% MODprocess_single_L0_to_L1        Part of MOD_fish_processing
%
% data = MODprocess_single_L0_to_L1(L0_data, metadata)
%
% DESCRIPTION
%   Converts one file's L0 struct (raw counts/hex, from
%   MODprocess_single_modraw_to_L0.m) into physical units:
%     epsi   - AFE counts -> volts (t*/s*) or g (a*), by manifest channel
%     ctd    - raw hex -> P/T/C/S (SBE49 only - SBE41 arrives from L0
%              already in physical units), plus derived th, sgth, dPdt,
%              z, dzdt
%     alt, isap - raw distance -> height above bottom (hab)
%   Every other field (gps, vnav, seg, spec, ...) passes through
%   unchanged. Pure transformation - no file I/O, no metadata mutation.
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
%                     metadata.AFE.(channel).full_range/.ADCconf/.type,
%                     metadata.CTD.name, metadata.CTD.cal,
%                     metadata.GEOMETRY.alt_angle_deg/.alt_dist_from_crashguard_ft/
%                     .alt_probe_dist_from_crashguard_in
%
% OUTPUTS
%   data      - same fields as L0_data, with epsi/ctd/alt/isap converted
%               to physical units as described above
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   toolbox/seawater/sw_salt.m, sw_ptmp.m, sw_pden.m, sw_dpth.m
%   (local subfunctions: convert_efe_channels, calibrate_ctd, calibrate_altimeter_hab)
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
%   for both. Unverified against real alt data - none of the
%   data_for_reorg example deployments carry MOD altimeter data yet.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

toolbox_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'seawater');
addpath(toolbox_dir);

data = L0_data;

%% EFE channels: counts -> volts (t*, s*) or g (a*)
if ~isempty(data.epsi) && isfield(data.epsi, 'channel1')
    data.epsi = convert_efe_channels(data.epsi, metadata);
end

%% CTD: raw hex -> physical P/T/C/S, plus derived fields
if ~isempty(data.ctd)
    gps = [];
    if isfield(data, 'gps')
        gps = data.gps;
    end
    data.ctd = calibrate_ctd(data.ctd, gps, metadata);
end

%% Altimeter / ISA500: raw distance -> height above bottom
if ~isempty(data.alt) && isfield(data.alt, 'dst')
    data.alt.hab = calibrate_altimeter_hab(data.alt.dst, metadata);
end
if ~isempty(data.isap) && isfield(data.isap, 'dst')
    data.isap.hab = calibrate_altimeter_hab(data.isap.dst, metadata);
end

end %end function

%% EFE counts -> volts/g, renaming L0's positional channel1..N to manifest names
function epsi = convert_efe_channels(epsi, metadata)

bit_counts = 24;
gain = 1;
acc_offset = 0.9;   % V, half of the 1.8 V accelerometer full range
acc_factor = 0.4;   % V/g, from the accelerometer datasheet

Unipolar = @(FR, count) FR/gain*double(count)/2^bit_counts;
Bipolar  = @(FR, count) FR/gain*(double(count)/2^(bit_counts-1) - 1);

channel_names = metadata.PROCESS.channels;
for iC = 1:numel(channel_names)
    ch = channel_names{iC};
    slot_field = sprintf('channel%d', iC);
    if ~isfield(epsi, slot_field)
        continue
    end

    counts = epsi.(slot_field);
    epsi.([ch '_count']) = counts;
    epsi = rmfield(epsi, slot_field);

    FR = metadata.AFE.(ch).full_range;
    switch metadata.AFE.(ch).ADCconf
        case {'Bipolar', 'bipolar'}
            volts = Bipolar(FR, counts);
        case {'Unipolar', 'unipolar'}
            volts = Unipolar(FR, counts);
        otherwise
            error('MODprocess_single_L0_to_L1:unknownADCconf', ...
                'Channel %s has unrecognized ADCconf "%s"', ch, metadata.AFE.(ch).ADCconf);
    end

    if strcmpi(metadata.AFE.(ch).type, 'acc')
        epsi.([ch '_g']) = (volts - acc_offset)/acc_factor;
    else
        epsi.([ch '_volt']) = volts;
    end
end

end

%% CTD raw hex -> physical units
function ctd = calibrate_ctd(ctd, gps, metadata)

c3515 = 42.914; % conductivity standard, mS/cm

if isfield(ctd, 'T_raw')
    % SBE49 "eng" format - counts need the SBE calibration polynomials.
    % SBE41 "PTS" format arrives from L0 with P/T/S/C already ASCII-parsed,
    % so this block is skipped for it.
    cal = metadata.CTD.cal;

    mv = (ctd.T_raw - 524288)/1.6e7;
    r = (mv*2.295e10 + 9.216e8)./(6.144e4 - mv*5.3e5);
    ctd.T = cal.ta0 + cal.ta1*log(r) + cal.ta2*log(r).^2 + cal.ta3*log(r).^3;
    ctd.T = 1./ctd.T - 273.15;

    y = ctd.PT_raw/13107;
    t = cal.ptempa0 + cal.ptempa1*y + cal.ptempa2*y.^2;
    x = ctd.P_raw - cal.ptca0 - cal.ptca1*t - cal.ptca2*t.^2;
    n = x.*cal.ptcb0./(cal.ptcb0 + cal.ptcb1*t + cal.ptcb2*t.^2);
    ctd.P = (cal.pa0 + cal.pa1*n + cal.pa2*n.^2 - 14.7)*0.689476;

    f = ctd.C_raw/256/1000;
    ctd.C = (cal.g + cal.h*f.^2 + cal.i*f.^3 + cal.j*f.^4)./(1 + cal.tcor.*ctd.T + cal.pcor.*ctd.P);

    ctd.S = real(sw_salt(ctd.C*10./c3515, ctd.T, ctd.P));
end

ctd.th   = sw_ptmp(ctd.S, ctd.T, ctd.P, 0);
ctd.sgth = sw_pden(ctd.S, ctd.T, ctd.P, 0);
ctd.dPdt = [0; diff(ctd.P)./diff(ctd.time_s)];

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
ctd.z = sw_dpth(ctd.P, lat);
ctd.dzdt = [0; diff(ctd.z)./diff(ctd.time_s)];

end

%% Altimeter/ISA500 raw distance -> height above bottom
function hab = calibrate_altimeter_hab(dst, metadata)

feet2meters = @(x) x*0.3048;
inches2meters = @(x) x*0.0254;

theta = deg2rad(metadata.GEOMETRY.alt_angle_deg);
altimeter_height_above_probes = feet2meters(metadata.GEOMETRY.alt_dist_from_crashguard_ft) - ...
    inches2meters(metadata.GEOMETRY.alt_probe_dist_from_crashguard_in);

hab = dst*cos(theta) - altimeter_height_above_probes;

end
