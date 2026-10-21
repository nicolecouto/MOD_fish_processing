function fits = MODsetup_probe_fits()
% MODsetup_probe_fits        Part of MOD_fish_processing
%
% fits = MODsetup_probe_fits()
%
% DESCRIPTION
%   The in-situ probe fits: AFE channel types whose scale is fit against
%   the CTD for each deployment, rather than looked up like shear's Sv.
%   MODprocess_all_L0_to_L1.m fits and saves each one to meta/<file>, and
%   MODsetup_add_derived_metadata.m loads it back into
%   metadata.AFE.(ch).<field>, so one list keeps the two in step.
%
% OUTPUTS
%   fits - 1 x n struct array:
%     name         - label in meta/metadata.mat's record
%     type         - metadata.AFE.(ch).type it applies to
%     field        - metadata.AFE.(ch) field the fit is stored in (and the
%                    variable name in the saved file)
%     file         - file name in meta/
%     fit_function - handle, fit_function(L1_dir, metadata, PressureTimeseries)
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m, MODsetup_add_derived_metadata.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

fits = struct( ...
    'name', {'fpo7_calibration', 'ucond_calibration'}, ...
    'type', {'fpo7', 'microcond'}, ...
    'field', {'volts_to_C', 'volts_to_S_per_m'}, ...
    'file', {'fpo7_calibration.mat', 'ucond_calibration.mat'}, ...
    'fit_function', {@MODprocess_L1_apply_fpo7_calibration, @MODprocess_L1_apply_ucond_calibration});

end %end function
