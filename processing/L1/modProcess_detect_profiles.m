function profiles = modProcess_detect_profiles(PressureTimeseries, metadata)
% modProcess_detect_profiles        Part of MOD_fish_processing
%
% profiles = modProcess_detect_profiles(PressureTimeseries, metadata)
%
% DESCRIPTION
%   Full profile-picker: finds discrete downcast/upcast start/end indices
%   from a deployment-length pressure record, using speed-limit hysteresis
%   (separate start/end thresholds per direction, same shape as the old
%   MOD_fish_lib picker) and a min-length filter, then merges consecutive
%   same-direction runs. Builds directly on
%   mod_L1_detect_profiling_direction.m's already-computed dPdt_smoothed
%   rather than re-deriving the cheby2 lowpass - this function's only new
%   work is the hysteresis/run-detection/merge/min-length logic that
%   function deliberately does not do (see its own NOTES).
%
%   Ported in spirit (not literally) from MOD_fish_lib/EPSILOMETER/epsilib/
%   epsiProcess_get_profiles_from_PressureTimeseries.m. Two real
%   differences from that function, beyond operating on an
%   already-smoothed dPdt:
%     1. Output is a struct array of profile objects (profiles(i).direction/
%        .index_start/...) instead of parallel startdown/enddown/startup/
%        endup/drop arrays - easier to index, matches this repo's other
%        struct-array conventions (e.g. metadata.header.history).
%     2. GAP-BOUNDARY SAFETY (new - legacy has no gaps to worry about):
%        PressureTimeseries.dPdt_smoothed is NOT NaN'd at gap-flanking
%        samples (only is_down is, inside mod_L1_detect_profiling_direction.m),
%        and array indices on either side of a real timestamp gap are
%        still numerically adjacent (a gap is a large jump in *time*, not
%        a break in the array). Left alone, this function's run-detection
%        and its cross-run merge pass could both, in principle, coalesce
%        samples from opposite sides of a real gap into one profile purely
%        because their array indices are adjacent. To prevent that, this
%        function re-derives the same gap split mod_L1_detect_profiling_direction.m's
%        STEP 1 computes internally (metadata.PROFILES.ctd_gap_factor,
%        same dt = diff(dnum)*86400 formula) and treats every gap as a
%        hard boundary neither a run nor a merge can ever cross. This is a
%        few lines duplicated from that function's STEP 1 (not its
%        smoothing) - see NOTES for why it isn't instead a new output
%        field of that function.
%
% INPUTS
%   PressureTimeseries - struct from mod_L1_detect_profiling_direction.m
%                         (meta/pressure_time_series.mat), with fields:
%                         dnum, P, dPdt_smoothed
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%     metadata.PROFILES.ctd_gap_factor         [dbar/s] - default 5. Same
%         field/semantics mod_L1_detect_profiling_direction.m validates -
%         reused, not re-registered under a different name.
%     metadata.PROFILES.speedLim_down_start_m_s [dbar/s], default 0.3
%     metadata.PROFILES.speedLim_down_end_m_s   [dbar/s], default 0.1
%     metadata.PROFILES.speedLim_up_start_m_s   [dbar/s], default 0.1
%     metadata.PROFILES.speedLim_up_end_m_s     [dbar/s], default 0.05
%     metadata.PROFILES.minLength_m             [dbar], default 10
%     (metadata.PROFILES.profile_dir is NOT read here - it no longer
%     filters which profiles this function returns, see NOTES. It's
%     validated/used downstream, in
%     MODprocess_single_L1_to_L2.m, to decide which direction(s)
%     get epsi spectra computed.)
%     Validated via MODsetup_validate_metadata.m as the first executable
%     line (same point-of-use pattern mod_scan_get_spectra.m uses) -
%     prompted for (and offered to be saved into setup.yml) if not already
%     in metadata; see MODsetup_metadata_field_registry.m for each field's
%     historical default. Per-vehicle hysteresis defaults (legacy switched
%     on fishflag_name: fctd/epsi got 0.3/0.1/0.1/0.05, wirewalker got
%     0.5/0.5/0.5/0.05) are NOT hardcoded here - PLAN.md Section 2's "no
%     hardcoded values without a documented reason" rule means a
%     wirewalker deployment sets its own speedLim_* in setup.yml rather
%     than this function guessing from vehicle type.
%
% OUTPUTS
%   profiles - 1 x n_profiles struct array, one entry per detected cast in
%              EITHER direction (not filtered by profile_dir - see NOTES),
%              sorted by index_start, with fields:
%     profile_number - sequential integer, 1-based, in time order across
%                       BOTH directions combined (for Profile####.mat naming)
%     direction       - 'down' or 'up'
%     index_start, index_end - indices into PressureTimeseries.dnum/.P
%     dnum_start, dnum_end   - PressureTimeseries.dnum(index_start/index_end)
%     P_start, P_end         - PressureTimeseries.P(index_start/index_end)
%   Empty (1x0) struct array (same fields, no elements) if PressureTimeseries
%   has fewer than 2 samples or nothing passes minLength_m filtering.
%
% CALLED BY
%   MODprocess_all_extract_profiles.m
%
% CALLS
%   MODsetup_validate_metadata.m
%
% NOTES
%   Both directions are always detected/merged/returned - this function
%   never filters by metadata.PROFILES.profile_dir (it did in an earlier
%   version of this branch; changed after review). CTD/pressure data is
%   collected on every cast a vehicle makes regardless of direction, so
%   every cast this function finds should get a Profile####.mat with its
%   CTD record saved (MODprocess_single_L1_to_L2.m always attaches
%   data.ctd). profile_dir instead governs, downstream, which
%   direction(s) are trusted enough to compute epsi spectra for - many
%   epsi platforms only trust downcasts for shear/fpo7 due to vehicle wake
%   turbulence on the upcast, even though the CTD itself is valid both
%   ways. A 'down'-only deployment still needed upcast runs identified
%   internally even before this change, so the alternating-merge logic has
%   something to check against when deciding whether two downcast runs are
%   "really" one - that part is unchanged.
%
%   The gap split is duplicated here (3-ish lines) rather than added as a
%   new output field of mod_L1_detect_profiling_direction.m: that function
%   is already "Done" and shipped, its NOTES already state it deliberately
%   does not build profile objects, and the duplication is small and
%   local, not spread across many call sites - see PLAN.md's discussion of
%   this tradeoff.
%
%   Legacy's merge loop has an off-by-one (`while ii<numel(...)` never
%   checks the last pair as a merge candidate) - not reproduced here
%   (`ii <= numel(...)`), since this is a re-derivation, not a literal
%   port, and there is no reason to keep an incidental bug.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'ctd_gap_factor', 'speedLim_down_start_m_s', 'speedLim_down_end_m_s', ...
     'speedLim_up_start_m_s', 'speedLim_up_end_m_s', 'minLength_m'});

empty_fields = {'profile_number', 'direction', 'index_start', 'index_end', ...
    'dnum_start', 'dnum_end', 'P_start', 'P_end'};
empty_args = [empty_fields; repmat({{}}, 1, numel(empty_fields))];
profiles = struct(empty_args{:}); % struct('a',{},'b',{},...) -> 0x0 struct array with these fields

dnum = PressureTimeseries.dnum(:);
P    = PressureTimeseries.P(:);
dpdt = PressureTimeseries.dPdt_smoothed(:);
n = numel(dnum);

if n < 2
    return
end

%% Gap split - same formula as mod_L1_detect_profiling_direction.m STEP 1,
% duplicated (not shared) so a run/merge below can never cross a gap - see
% DESCRIPTION.
dt = diff(dnum) * 86400; % seconds
gap_after = dt > metadata.PROFILES.ctd_gap_factor * median(dt); % (n-1) x 1

%% Per-direction hysteresis run detection
startdown = []; enddown = [];
startup = []; endup = [];
for downCast = [true, false]
    if downCast
        crit_start = find(dpdt > 0 & dpdt > metadata.PROFILES.speedLim_down_start_m_s);
        crit_end   = find(dpdt > 0 & dpdt > metadata.PROFILES.speedLim_down_end_m_s);
    else
        crit_start = find(-dpdt > 0 & -dpdt > metadata.PROFILES.speedLim_up_start_m_s);
        crit_end   = find(-dpdt > 0 & -dpdt > metadata.PROFILES.speedLim_up_end_m_s);
    end

    run_start_idx = first_of_each_run(crit_start, gap_after);
    run_end_idx   = last_of_each_run(crit_end, gap_after);
    profiling_start = crit_start(run_start_idx);
    profiling_end   = sort(crit_end(run_end_idx));

    % Pair each start with the first end after it (matches legacy). Since
    % the end-threshold is always less strict than the start-threshold,
    % every profiling_start sample also satisfies the end criteria, so it
    % falls inside some end-run - pairing naturally lands within the same
    % gap-free run the start belongs to, with no extra gap check needed
    % here (the run-detection above already stopped every run at a gap).
    startcast = zeros(0, 1);
    endcast = zeros(0, 1);
    for i = 1:numel(profiling_start)
        end_idx = find(profiling_end > profiling_start(i), 1);
        if ~isempty(end_idx)
            startcast(end+1, 1) = profiling_start(i); %#ok<AGROW>
            endcast(end+1, 1) = profiling_end(end_idx); %#ok<AGROW>
        end
    end

    % A profiling_end index can be the nearest qualifying end for more
    % than one start - keep the last start for each unique end (matches
    % legacy's unique() behavior).
    [~, iU] = unique(endcast);
    startcast = startcast(iU);
    endcast = endcast(iU);

    profLength = abs(P(endcast) - P(startcast));
    longEnough = profLength >= metadata.PROFILES.minLength_m;

    if downCast
        startdown = startcast(longEnough);
        enddown = endcast(longEnough);
    else
        startup = startcast(longEnough);
        endup = endcast(longEnough);
    end
end

%% Merge consecutive same-direction runs (not separated by an
% opposite-direction run or a real gap) - up to 10 passes, same as legacy.
for repeat_i = 1:10
    all_up = runs_to_indices(startup, endup);
    all_down = runs_to_indices(startdown, enddown);

    [startup, endup] = merge_adjacent_runs(startup, endup, all_down, gap_after);
    [startdown, enddown] = merge_adjacent_runs(startdown, enddown, all_up, gap_after);
end

%% Every detected profile, both directions - NOT filtered by
% metadata.PROFILES.profile_dir. That field is a downstream concern (which
% direction(s) get epsi spectra computed - MODprocess_single_L1_to_L2.m)
% rather than a profile-existence concern: CTD/pressure data is collected
% on every cast regardless of direction, so every cast this function finds
% is returned here and gets a Profile####.mat with its CTD record saved -
% see NOTES.
idx_start = [startdown(:); startup(:)];
idx_end = [enddown(:); endup(:)];
direction = [repmat({'down'}, numel(startdown), 1); repmat({'up'}, numel(startup), 1)];

if isempty(idx_start)
    return
end

[idx_start, sortIdx] = sort(idx_start);
idx_end = idx_end(sortIdx);
direction = direction(sortIdx);

n_profiles = numel(idx_start);
for i = 1:n_profiles
    profiles(i).profile_number = i;
    profiles(i).direction = direction{i};
    profiles(i).index_start = idx_start(i);
    profiles(i).index_end = idx_end(i);
    profiles(i).dnum_start = dnum(idx_start(i));
    profiles(i).dnum_end = dnum(idx_end(i));
    profiles(i).P_start = P(idx_start(i));
    profiles(i).P_end = P(idx_end(i));
end

end %end function

%% First index (into crit) of each gap-free contiguous run in crit
function is_start = first_of_each_run(crit, gap_after)
n = numel(crit);
is_start = true(n, 1);
for k = 2:n
    is_start(k) = (crit(k) - crit(k-1) > 1) || any(gap_after(crit(k-1):crit(k)-1));
end
end

%% Last index (into crit) of each gap-free contiguous run in crit
function is_end = last_of_each_run(crit, gap_after)
n = numel(crit);
is_end = true(n, 1);
for k = 1:n-1
    is_end(k) = (crit(k+1) - crit(k) > 1) || any(gap_after(crit(k):crit(k+1)-1));
end
end

%% Flatten paired start/end indices into one sorted vector of every sample
% index covered by any run (used by the merge step to test "is there an
% opposite-direction sample between these two runs").
function idx = runs_to_indices(start_arr, end_arr)
idx = [];
for ii = 1:numel(start_arr)
    idx = [idx, start_arr(ii):end_arr(ii)]; %#ok<AGROW>
end
end

%% Merge consecutive runs in (start_arr, end_arr) when neither an
% opposite-direction sample (any index in other_idx) nor a real gap
% (gap_after) lies strictly between them.
function [start_arr, end_arr] = merge_adjacent_runs(start_arr, end_arr, other_idx, gap_after)
ii = 2;
while ii <= numel(start_arr)
    span_lo = end_arr(ii-1);
    span_hi = start_arr(ii);
    has_opposite = any(ismember(span_lo:span_hi, other_idx));
    has_gap = span_hi > span_lo && any(gap_after(span_lo:span_hi-1));
    if ~has_opposite && ~has_gap
        end_arr(ii-1) = end_arr(ii);
        start_arr(ii) = [];
        end_arr(ii) = [];
    else
        ii = ii + 1;
    end
end
end
