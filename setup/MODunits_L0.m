function u = MODunits_L0()
% MODunits_L0        Part of MOD_fish_processing
%
% u = MODunits_L0()
%
% DESCRIPTION
%   Static registry of every L0 struct type's units and description
%   (MODprocess_single_modraw_to_L0.m), one entry per top-level field name.
%   L0 is raw/uncalibrated data - no calibrations applied at all
%   (MODprocess_single_modraw_to_L0.m's own DESCRIPTION) - so every entry
%   here is explicitly documented as unitless/raw rather than omitted,
%   per this repo's "keep very careful notes of what units all our
%   variables are in" goal (PLAN.md, 2026-08-13 session log). Mirrors
%   MODsetup_metadata_field_registry.m's pattern (a static function
%   returning a struct, no data needed in hand to call it) but keyed by
%   field name -> {unit, description} rather than by yaml-registry name.
%
%   Documented at the top-level struct-type granularity (epsi, ctd, ...),
%   not every raw sub-field within each - most of those are intermediate
%   counts/hex with no stable physical meaning until L1 calibration, and
%   are already enumerated in MODprocess_single_modraw_to_L0.m's own
%   OUTPUTS docstring. `gps` is the one exception: NMEA GPGGA/INGGA
%   sentences are parsed directly into decimal degrees at L0 (no
%   calibration step exists or is needed), so it already has real
%   physical units at this level, unlike everything else here.
%
% OUTPUTS
%   u - struct, one field per L0 top-level field name. Each value is
%       struct('unit', ..., 'description', ...).
%
% CALLED BY
%   (none yet - reference registry, callable wherever a caller wants to
%   look up what an L0 field means)
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

u.epsi = struct('unit', 'counts', ...
    'description', 'Raw 24-bit ADC counts per AFE channel (channel1..channelN, ADC slot order) - no calibration applied. See MODprocess_single_L0_to_L1.m for the count -> volt/g conversion.');
u.ctd = struct('unit', 'mixed - raw/hex or already-physical', ...
    'description', 'SBE49 "eng" format: raw hex counts (T_raw/P_raw/PT_raw/C_raw), no calibration applied. SBE41 "PTS" format and external-CTD sources (DeepSolo/Wirewalker): already physical units (P dbar, T degC, SP psu, C S/m) - see MODprocess_single_L0_to_L1.m.');
u.alt = struct('unit', 'counts/raw distance', ...
    'description', 'MOD altimeter raw distance - no geometry calibration applied yet (see calibrate_altimeter_hab in MODprocess_single_L0_to_L1.m for the hab conversion).');
u.isap = struct('unit', 'counts/raw distance', ...
    'description', 'ISA500 altimeter raw distance - same treatment as alt.');
u.act = struct('unit', 'n/a', 'description', 'Actuator data - currently always empty ([]).');
u.vnav = struct('unit', 'raw', ...
    'description', 'VecNav compass/gyro/accelerometer raw data - no calibration applied at L0. mod_L1_add_twist.m derives cable-twist rotation counts from this at L1.');
u.gps = struct('unit', 'decimal degrees (latitude/longitude), MATLAB datenum (dnum)', ...
    'description', 'GPGGA/INGGA sentences, parsed directly to physical units at L0 (no separate calibration step) - the one L0 field type with real physical units already. Passes through L1 unchanged.');
u.seg = struct('unit', 'raw', 'description', 'Per-segment raw spectra input, onboard-computed - passes through L1 unchanged.');
u.spec = struct('unit', 'raw', 'description', 'Per-segment spectra, onboard-computed - passes through L1 unchanged.');
u.avgspec = struct('unit', 'raw', 'description', 'Averaged spectra, onboard-computed - passes through L1 unchanged.');
u.dissrate = struct('unit', 'raw', 'description', 'Onboard dissipation-rate estimates - passes through L1 unchanged. Not the same as this repo''s own epsilon_obs/epsilon_mle (modProcess_L2_calc_epsilon.m).');
u.apf = struct('unit', 'raw', 'description', 'APEX float (APF0/1/2) telemetry data - passes through L1 unchanged.');
u.fluor = struct('unit', 'raw', 'description', 'ECOP fluorometer raw data - passes through L1 unchanged.');
u.ttv = struct('unit', 'raw', 'description', 'TTV1 data - passes through L1 unchanged.');

end %end function
