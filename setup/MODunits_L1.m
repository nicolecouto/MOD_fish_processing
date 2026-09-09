function u = MODunits_L1()
% MODunits_L1        Part of MOD_fish_processing
%
% u = MODunits_L1()
%
% DESCRIPTION
%   Static registry of every L1 field's units and description
%   (MODprocess_single_L0_to_L1.m's output), one entry per field name -
%   see MODunits_L0.m's own DESCRIPTION for the overall design (mirrors
%   MODsetup_metadata_field_registry.m's pattern, keyed by field name
%   rather than yaml-registry name). Dynamically-named per-channel fields
%   (epsi.(channel)_volt/_g) are documented as a pattern once, not
%   enumerated per possible channel name - same convention
%   mod_L2_tile_scans.m's own header docstring already uses.
%
%   Field names not listed here (gps, seg, spec, avgspec, dissrate, apf,
%   fluor, ttv, vnav's own raw sub-fields) pass through from L0 to L1
%   unchanged - see MODunits_L0.m for those.
%
% OUTPUTS
%   u - struct, one field per L1 field name (dot-path flattened, e.g.
%       'ctd_SP' for ctd.SP). Each value is
%       struct('unit', ..., 'description', ...).
%
% CALLED BY
%   (none yet - reference registry)
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% --- epsi (AFE channels: counts -> volts or g) ---
u.epsi_volt = struct('unit', 'V', ...
    'description', 'Any t*/s* channel (fpo7/shear) converted from raw counts - epsi.(channel)_volt, e.g. epsi.t1_volt, epsi.s1_volt. Pattern, not enumerated per channel - see MODprocess_single_L0_to_L1.m''s convert_efe_channels.');
u.epsi_g = struct('unit', 'g (gravitational acceleration)', ...
    'description', 'Any a* channel (accelerometer) converted from raw counts, then volts -> g - epsi.(channel)_g, e.g. epsi.a3_g. Pattern, not enumerated per channel.');

% --- ctd ---
u.ctd_dnum = struct('unit', 'MATLAB datenum', 'description', 'CTD sample time - the master clock everything else CTD-related is derived from (process_ctd_fields).');
u.ctd_time_s = struct('unit', 's', 'description', 'dnum in seconds on MATLAB''s day-zero epoch (dnum*86400) - matches MODprocess_single_modraw_to_L0.m''s convert_timestamp convention.');
u.ctd_P = struct('unit', 'dbar', 'description', 'CTD pressure.');
u.ctd_T = struct('unit', 'degC (ITS-90/IPTS-68 per SBE convention)', 'description', 'CTD in-situ temperature.');
u.ctd_C = struct('unit', 'S/m', 'description', 'CTD conductivity - NOT mS/cm. gsw_SP_from_C wants mS/cm, hence the *10 conversion at its call site.');
u.ctd_SP = struct('unit', 'psu (PSS-78)', 'description', 'Practical Salinity - reported directly by the instrument (SBE41/external CTD), or derived via gsw_SP_from_C (SBE49 "eng" format, process_ctd_fields). See docs/concepts/units_and_seawater.md.');
u.ctd_SR = struct('unit', 'g/kg', 'description', 'Reference Salinity, gsw_SR_from_SP(ctd.SP) - the SR-approximates-Absolute-Salinity shortcut used throughout this repo''s GSW calls (density, heat capacity, Conservative Temperature, ...). See docs/concepts/units_and_seawater.md for the accuracy tradeoff.');
u.ctd_CT = struct('unit', 'degC', 'description', 'Conservative Temperature, gsw_CT_from_t(ctd.SR, ctd.T, ctd.P) - the TEOS-10-idiomatic replacement for potential temperature (formerly ctd.th).');
u.ctd_sigma0 = struct('unit', 'kg/m^3', 'description', 'Potential density anomaly referenced to 0 dbar, gsw_sigma0(ctd.SR, ctd.CT) - the TEOS-10-idiomatic replacement for potential density (formerly ctd.sgth).');
u.ctd_z = struct('unit', 'm, positive down', 'description', 'Depth from pressure, -gsw_z_from_p(ctd.P, lat) - negated because gsw_z_from_p''s own convention is height (negative down) and this repo''s z/dzdt convention is positive down.');
u.ctd_dPdt = struct('unit', 'dbar/s', 'description', 'Finite-difference pressure rate, diff(ctd.P)./diff(ctd.time_s).');
u.ctd_dzdt = struct('unit', 'm/s, positive during descent', 'description', 'Finite-difference depth rate (fall speed), diff(ctd.z)./diff(ctd.time_s) - this is the "w" fed to L2 spectral calculations.');

% --- alt / isap (altimeters) ---
u.alt_hab = struct('unit', 'm', 'description', 'MOD altimeter height above bottom, from raw distance + GEOMETRY calibration (calibrate_altimeter_hab).');
u.isap_hab = struct('unit', 'm', 'description', 'ISA500 altimeter height above bottom - same geometry/conversion as alt.hab.');
u.isap_dst = struct('unit', 'm (raw, pre-hab)', 'description', 'ISA500 raw range-to-target - pegs at a flat maximum (120 in the one deployment tested) when the target is out of range; not a bug, but don''t mistake a flatlined hab for a real constant range to bottom.');

% --- twist (cable rotation count, from vnav) ---
u.twist_count_gyro = struct('unit', 'full rotations', 'description', 'Cumulative cable-twist rotation count, integrated z-axis gyro / (2*pi) - mod_L1_add_twist.m.');
u.twist_pressure = struct('unit', 'dbar', 'description', 'CTD pressure interpolated onto the vnav timebase - marks upcast/downcast for the twist-count plot (NaN if no CTD or interpolation fails).');

end %end function
