function u = MODunits_L0()
% MODunits_L0        Part of MOD_fish_processing
%
% u = MODunits_L0()
%
% DESCRIPTION
%   Static registry of every L0 struct type's units and description
%   (MODprocess_single_modraw_to_L0.m), one entry per top-level field name.
%   L0 is raw/uncalibrated data - no calibrations applied at all
%   (MODprocess_single_modraw_to_L0.m's own DESCRIPTION), except that EFE
%   counts are converted to volts/g (epsi) - so every entry here is
%   explicitly documented as unitless/raw (or its unit) rather than omitted,
%   per this repo's "keep very careful notes of what units all our
%   variables are in" goal (SESSION_LOG.md, 2026-08-13). Mirrors
%   MODsetup_metadata_field_registry.m's pattern (a static function
%   returning a struct, no data needed in hand to call it) but keyed by
%   field name -> {unit, description} rather than by yaml-registry name.
%
%   Documented at the top-level struct-type granularity (epsi, ctd, ...),
%   not every raw sub-field within each - most of those are intermediate
%   counts/hex with no stable physical meaning until L1 calibration, and
%   are already enumerated in MODprocess_single_modraw_to_L0.m's own
%   OUTPUTS docstring. Two exceptions already have physical units at
%   this level: `gps` (NMEA GPGGA/INGGA sentences are parsed directly
%   into decimal degrees - no calibration step exists or is needed) and
%   `epsi` (EFE counts converted to volts/g with the standard board
%   config - see epsi_conversion).
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

u.epsi = struct('unit', 'V (<name>_volt), g (<name>_g)', ...
    'description', 'EFE channels converted from 24-bit ADC counts to volts (t1_volt, s1_volt, ... every non-accelerometer channel) or g (a1_g, a2_g, a3_g), named by channel - converted at L0 (unlike every other raw type), using the standard EFE board config (MODsetup_default_efe.m) unless MODprocess_single_modraw_to_L0.m was given metadata. No sensor calibration (no temperature, no shear). Exact counts are recoverable - see epsi_conversion. L0 files written before this change hold raw counts as channel1..channelN instead.');
u.epsi_conversion = struct('unit', 'n/a (record)', ...
    'description', 'Per-channel counts <-> volts/g record for epsi (mod_efe_conversion.m): channel names in slot order, ADC config, exact scale/offset (value = counts*scale + offset), where each came from (default EFE or setup.yml), and a plain-text README / per-channel how_to_recover_counts. Carried on to L1 and updated there.');
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
    'description', 'GPGGA/INGGA sentences, parsed directly to physical units at L0 (no separate calibration step), so already in physical units. Passes through L1 unchanged.');
u.seg = struct('unit', 'raw', 'description', 'Per-segment raw spectra input, onboard-computed - passes through L1 unchanged.');
u.spec = struct('unit', 'raw', 'description', 'Per-segment spectra, onboard-computed - passes through L1 unchanged.');
u.avgspec = struct('unit', 'raw', 'description', 'Averaged spectra, onboard-computed - passes through L1 unchanged.');
u.dissrate = struct('unit', 'raw', 'description', 'Onboard dissipation-rate estimates - passes through L1 unchanged. Not the same as this repo''s own epsilon_obs/epsilon_mle (mod_scan_calc_epsilon.m).');
u.apf = struct('unit', 'raw', 'description', 'APEX float (APF0/1/2) telemetry data - passes through L1 unchanged.');
u.fluor = struct('unit', 'raw', 'description', 'ECOP fluorometer raw data - passes through L1 unchanged.');
u.ttv = struct('unit', 'raw', 'description', 'TTV1 data - passes through L1 unchanged.');

end %end function
