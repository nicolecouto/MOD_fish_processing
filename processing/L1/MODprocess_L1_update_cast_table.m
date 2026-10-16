function [casts, metadata] = MODprocess_L1_update_cast_table(metadata)
% MODprocess_L1_update_cast_table        Part of MOD_fish_processing
%
% [casts, metadata] = MODprocess_L1_update_cast_table(metadata)
%
% DESCRIPTION
%   Picks the casts from the deployment's pressure record
%   (pressure_time_series.mat in metadata.paths.L1_meta, next to the L1 it
%   was built from; modProcess_detect_profiles.m) and saves them as this
%   processing run's casts.mat (metadata.paths.meta) - the one cast table
%   both realtime processing
%   and postprocessing use: realtime grids by it, postprocessing cuts
%   profiles_L1/Profile####.mat from it (MODprocess_all_extract_profiles.m).
%   Tuning cast picking means changing the profile_detection parameters
%   (or editing this table); there is no second picker.
%
%   A cast that runs into the end of the pressure record (its last sample
%   is the record's last sample) is marked complete = false: during
%   realtime acquisition it's still going. Realtime gridding leaves it out
%   until it ends; postprocessing keeps it (the deployment is over, so it's
%   real, if cut-off, data).
%
%   Casts are numbered in time order across both directions
%   (profile_number - the number Profile####.mat uses). Numbers can change when the
%   record grows (e.g. two runs merge), so anything keeping per-cast
%   results should key them by dnum_start, not by number.
%
% INPUTS
%   metadata - from MODsetup_read_yaml.m. Uses metadata.paths.L1_meta,
%              metadata.paths.meta and the
%              profile_detection parameters (metadata.PROFILES.*, validated
%              by modProcess_detect_profiles.m).
%
% OUTPUTS
%   casts    - struct array in time order (empty if no casts):
%                .profile_number, .direction ('down'/'up'),
%                .dnum_start, .dnum_end, .P_start, .P_end,
%                .index_start, .index_end (into pressure_time_series.mat),
%                .complete (false for a cast still in progress)
%   metadata - same, reread from the yml if a prompted value was saved to
%              it (MODsetup_validate_metadata.m's yamlUpdated)
%   Also saves meta/casts.mat (casts, record_end_dnum, made_utc).
%
% CALLED BY
%   MODprocess_all_extract_profiles.m, MODprocess_deployment.m
%
% CALLS
%   modProcess_detect_profiles.m, MODsetup_read_yaml.m,
%   MODsetup_add_derived_metadata.m (only after a yml reread)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

pressure_timeseries_file = fullfile(metadata.paths.L1_meta, 'pressure_time_series.mat');
if ~isfile(pressure_timeseries_file)
    error('MODprocess_L1_update_cast_table:noPressureTimeseries', ...
        ['%s does not exist yet. It is built by MODprocess_all_L0_to_L1.m once this ' ...
         'deployment has CTD data in its L1 files - run that first.'], pressure_timeseries_file);
end
PressureTimeseries = load(pressure_timeseries_file);

while true
    try
        profiles = modProcess_detect_profiles(PressureTimeseries, metadata);
        break
    catch ME
        if ~strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
            rethrow(ME)
        end
        metadata = MODsetup_add_derived_metadata(MODsetup_read_yaml(metadata.paths.setup_yml));
    end
end

n_record = numel(PressureTimeseries.dnum);
casts = struct('profile_number', {}, 'direction', {}, 'dnum_start', {}, 'dnum_end', {}, ...
    'P_start', {}, 'P_end', {}, 'index_start', {}, 'index_end', {}, 'complete', {});
for p = profiles
    casts(end+1) = struct('profile_number', p.profile_number, 'direction', p.direction, ...
        'dnum_start', p.dnum_start, 'dnum_end', p.dnum_end, 'P_start', p.P_start, 'P_end', p.P_end, ...
        'index_start', p.index_start, 'index_end', p.index_end, ...
        'complete', p.index_end < n_record); %#ok<AGROW>
end

record_end_dnum = NaN;
if n_record > 0
    record_end_dnum = PressureTimeseries.dnum(end);
end
made_utc = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss'));
tmp = [tempname(metadata.paths.meta) '.mat'];
save(tmp, 'casts', 'record_end_dnum', 'made_utc');
movefile(tmp, fullfile(metadata.paths.meta, 'casts.mat'), 'f');
end %end function
