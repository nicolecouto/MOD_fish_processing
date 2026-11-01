function settings = MODsetup_L1_settings(metadata)
% MODsetup_L1_settings        Part of MOD_fish_processing
%
% settings = MODsetup_L1_settings(metadata)
%
% DESCRIPTION
%   The part of a metadata struct that the L0 -> L1 step reads
%   (MODprocess_all_L0_to_L1.m, MODprocess_single_L0_to_L1.m and the L1
%   helpers they call), so two runs' L1 settings can be compared: a run
%   that takes its L1 from another run (run.L1_from in its yml) is only
%   allowed when this is the same for both (MODsetup_preflight.m). Values
%   are compared, not yml text, so e.g. two calibrations_root paths that
%   hold the same calibration files count as the same. Works on a saved
%   metadata.mat too: only the AFE fields read from the yml are compared,
%   not the electronics filters or FP07 fit added later.
%
%   Keep this list in step with what L0 -> L1 reads: a field added there
%   and not here would let a run reuse an L1 made with a different value.
%   Spectral settings (fft_length, ...) are not here - L1 files don't
%   depend on them. Nor is the SBE calibration: it comes from the shared
%   L0 (ctd_cal), the same for every run of a survey.
%
% INPUTS
%   metadata - from MODsetup_read_yaml.m, or a saved metadata.mat
%
% OUTPUTS
%   settings - struct; a field that metadata doesn't have is []
%
% CALLED BY
%   MODsetup_preflight.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

settings = struct();
settings.fish_flag = get_field(metadata, {'fish_flag'});
settings.vehicle_name = get_field(metadata, {'vehicle_name'});
settings.manifest = get_field(metadata, {'manifest'});
settings.AFE = afe_from_yml(get_field(metadata, {'AFE'})); % channel types, SNs, probe cals, full range, ADC
settings.channels = get_field(metadata, {'PROCESS', 'channels'});
settings.latitude = get_field(metadata, {'PROCESS', 'latitude'});
settings.epsi_gap_factor = get_field(metadata, {'PROCESS', 'epsi_gap_factor'});
settings.accel_std_s = get_field(metadata, {'PROCESS', 'L1', 'accel_std_s'}); % L1 accel
settings.GEOMETRY = get_field(metadata, {'GEOMETRY'}); % altimeter
% profiling direction is detected at L1 (mod_L1_detect_profiling_direction.m)
settings.lowpass_sec = get_field(metadata, {'PROFILES', 'lowpass_sec'});
settings.ctd_gap_factor = get_field(metadata, {'PROFILES', 'ctd_gap_factor'});
settings.buffer_bins = get_field(metadata, {'PROFILES', 'buffer_bins'});
end %end function

%% Only the AFE fields that come from the yml (MODsetup_read_yaml.m) - not
% the ones added later (electronics_filter, the FP07 volts_to_C fit), which
% a saved metadata.mat can hold and a freshly read one doesn't
function out = afe_from_yml(afe)
out = afe;
if ~isstruct(afe)
    return
end
keep = {'type', 'SN', 'cal', 'full_range', 'ADCconf', 'ADCfilter'};
out = struct();
for ch = fieldnames(afe)'
    for f = keep
        if isfield(afe.(ch{1}), f{1})
            out.(ch{1}).(f{1}) = afe.(ch{1}).(f{1});
        end
    end
end
end

function v = get_field(s, path)
v = [];
for k = 1:numel(path)
    if ~isstruct(s) || ~isfield(s, path{k})
        return
    end
    s = s.(path{k});
end
v = s;
end
