function gridded = MODprocess_grid(metadata, by)
% MODprocess_grid        Part of MOD_fish_processing
%
% G = MODprocess_grid(metadata)
% G = MODprocess_grid(metadata, by)
%
% DESCRIPTION
%   Puts a processing run's casts on a depth grid: one column per cast in
%   the run's cast table (meta/casts.mat, MODprocess_L1_update_cast_table.m),
%   down and up casts both, one row per depth bin of grid.z_bin_m meters.
%   Saves processed/<run>/gridded/gridded.mat (not grid: that's
%   Matlab's grid on/off).
%
%   Field names are long-form (temperature, salinity_practical, ...); L2's
%   per-channel values are <L2 name>_<channel> (epsilon_mle_s1, chi_obs_t2).
%   Three kinds of value, binned the same way (the mean of what falls in
%   the bin):
%     - CTD (pressure, temperature, conductivity, salinity_practical,
%       salinity_reference, temperature_conservative, sigma0, fall_speed):
%       the mean of every L1 CTD sample in the bin, at the CTD's full rate.
%     - Other L1 records (pitch, tilt, roll from vnav; height_above_bottom
%       from isap, or alt without one, leaving out samples pegged at the
%       altimeter's maximum range; fluor.bb, .chla, .fdom from the ECOP
%       fluorometer; qc.<ch>_std, the accelerometer std windows of L1
%       accel, e.g. qc.a3_std): the mean of the samples in the bin,
%       each at the CTD depth at its time (interpolated). roll is a
%       circular mean (it wraps at +-180 deg); yaw and spin are headings
%       and are left out.
%     - Scans (viscosity_kinematic, diffusivity_thermal_molecular, and
%       L2's grouped structs epsilon, chi, microconductivity, kc and qc,
%       under the same names: gridded.epsilon.final, gridded.epsilon.s1_obs,
%       gridded.chi.t1_mle, gridded.kc.t1_obs, gridded.qc.s1_coherence_a3_sum,
%       ...): each scan of the cast (its center in
%       the cast) fills every bin of its footprint - from the shallowest
%       to the deepest L1 CTD depth during the scan
%       (n_samples_scan_afe/fs_afe long), so a 6.4 s scan at
%       3.8 m/s spans about 24 m - and a bin is the
%       mean of the scans covering it (about 2 with 50% overlap). A bin
%       no scan covers is NaN, and n_scans says how many scans cover each
%       bin. Only casts in the
%       profile_detection.profile_dir direction have scans. L2's
%       scan-center CTD values (pressure, w, temperature, salinity, SR) are
%       left out: they are the L1 CTD interpolated at each scan center, and
%       the L1 bin means above use every sample.
%   Only fields that exist are gridded: the data decide, and a group
%   (epsilon, chi, microconductivity, kc, qc, fluor) is there only when
%   some cast has a value in it - a CTD-only vehicle's grid has none of
%   the turbulence groups, an FCTD's no epsilon, chi or qc, an Epsi's no
%   microconductivity. An L2 file in an older layout (flat names, Fs_epsi,
%   or cutoffs inside epsilon/chi/microconductivity instead of kc) stops
%   with an error: reprocess L2.
%   Position (latitude, longitude per cast) is from the L1 GPS fixes
%   during the cast, from the L1 files either way (by profile too): the
%   first fix for an Epsi downcast from the ship (metadata.platform
%   'ship', fish_flag EPSI) - it free falls with slack in the line, so it
%   stays where it was dropped whatever the ship does - and the mean of
%   the fixes for every other cast (FCTD is pulled along by the ship; on
%   an upcast the winch pulls any fish).
%
%   Each call rebins only the casts that are new or changed - a cast whose
%   start, end and source files (their times) are the same as when it was
%   last binned keeps its column (and the yml latitude the scans' depth
%   uses: a change rebins every cast) - and doesn't rewrite gridded.mat when no
%   cast changed. A cast still in progress (cast_complete false) is
%   rebinned every call until it ends. A different by or z_bin_m,
%   or a grid made by another version of this function (grid_version),
%   rebins every cast. Each source folder is listed once per call and each
%   file loaded at most once (only the variables used).
%
% INPUTS
%   metadata - from MODsetup_read_yaml.m. Uses metadata.paths (gridded, meta,
%              L1_meta, L1, L2, profiles_L1, profiles_L2),
%              metadata.PROCESS.latitude and grid.z_bin_m
%              (metadata.PROCESS.GRID.z_bin_m).
%   by       - (optional) where the data come from: 'file' (default) -
%              the L1 and L2 files a cast overlaps (time_index.mat), as
%              realtime; or 'profile' - processed/<run>/profiles_L1/ and
%              profiles_L2/ (MODprocess_all_extract_profiles.m, then
%              MODprocess_all_L1_to_L2.m). Either way the GPS comes from
%              the L1 files the cast overlaps (L1/ and L1_meta's
%              time_index.mat).
%
% OUTPUTS
%   gridded - the struct saved in gridded.mat (see setup/MODunits_L3.m for every
%          field): z (bin centers, m), z_bin_m, then per cast
%          (1 x ncast) time, latitude, longitude (first or mean GPS fix
%          during the cast, see above; NaN without one), cast_start, cast_end, cast_direction, cast_complete,
%          profile_number, then nz x ncast fields and, where the data have
%          them, the structs epsilon (with final_source, 1 x ncast
%          cellstr, '' for a cast without epsilon), chi, microconductivity,
%          kc, qc and fluor, variables (the units
%          and descriptions of the fields present), source ('file' or
%          'profile'), provenance. An empty grid (no columns) if there are
%          no casts yet.
%
% CALLED BY
%   MODprocess_deployment.m (stage 'grid'), templates/MODtemplate_postprocess_steps.m
%
% CALLS
%   MODsetup_validate_metadata.m, MODunits_L3.m, MODutil_altimeter_hab_m.m,
%   MODutil_provenance.m, MODutil_save_atomic.m, gsw_z_from_p.m (Gibbs SeaWater toolbox)
%
% NOTES
%   Ported in spirit from MOD_fish_lib's FastCTD_GridData.m (bin means of
%   the full-rate CTD, in depth) and epsiProcess_gridProfiles.m (one
%   column per profile), with two changes: turbulence is bin-averaged on
%   the scan centers instead of interpolated between scans, and only new
%   or changed casts are rebinned instead of the whole grid every time.
%   No despiking or salinity smoothing yet (FastCTD_GridData.m lowpassed
%   salinity over 10 m) - to be added as its own step once the gridded
%   data have been looked at.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(by)
    by = 'file';
end
if ~any(strcmp(by, {'file', 'profile'}))
    error('MODprocess_grid:badBy', 'by must be ''file'' or ''profile'' (got ''%s'').', by);
end
yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'z_bin_m'});
z_bin = metadata.PROCESS.GRID.z_bin_m;
GRID_VERSION = 13; % 2: conductivity C; 3: GPS latitude/longitude per cast, no all-NaN epsilon_final; 4: first fix for Epsi downcasts from the ship; 5: long-form names, every L2 per-scan value, attitude and height above bottom; 6: microconductivity chi; 7: turbulence grouped in epsilon, chi, microconductivity, qc; 8: microconductivity chi_obs, chi_tot, eps_chi, n2; 9: reused casts keep every turbulence group (8 lost all but chi); 10: each scan fills its footprint, n_scans counts the scans covering a bin; 11: L2's fs_afe, n_samples_scan_afe (were Fs_epsi, N_epsi); 12: fluor, L2's cutoffs in kc, only the groups the data have; 13: qc.<accel>_std from L1 accel. A grid from another version rebins every cast.
if ~(z_bin > 0)
    error('MODprocess_grid:badZBin', 'grid.z_bin_m must be > 0 m (got %g).', z_bin);
end
lat = metadata.PROCESS.latitude;
% Epsi from the ship free falls: its downcasts keep the drop position
free_fall = strcmpi(metadata.platform, 'ship') && strcmpi(metadata.fish_flag, 'EPSI');

casts_file = fullfile(metadata.paths.meta, 'casts.mat');
if ~isfile(casts_file)
    error('MODprocess_grid:noCasts', ['%s does not exist yet - make the cast table first ' ...
        '(MODprocess_L1_update_cast_table.m).'], casts_file);
end
saved = load(casts_file, 'casts');
casts = saved.casts;

% the L1 time index: which L1 files a cast overlaps (by file: its CTD and
% scans; either way: its GPS, which profiles_L1 files don't carry)
time_index = [];
ti_file = fullfile(metadata.paths.L1_meta, 'time_index.mat');
if isfile(ti_file)
    time_index = load(ti_file);
elseif strcmp(by, 'file')
    error('MODprocess_grid:noTimeIndex', '%s does not exist yet - it is made with L1.', ti_file);
end
if strcmp(by, 'file')
    folders = {metadata.paths.L1, metadata.paths.L2};
else
    folders = {metadata.paths.profiles_L1, metadata.paths.profiles_L2, metadata.paths.L1};
end
% each folder listed once per call, and each file loaded at most once
dates = file_dates(folders);
cache = containers.Map();
if ~isempty(casts) && ~any(startsWith(string(keys(dates)), string(folders(1:2))))
    % e.g. by 'profile' on a run that made L2 by file - don't replace its grid
    error('MODprocess_grid:noSources', ['No .mat files in %s or %s - nothing to grid by ''%s''. ' ...
        'by must match how this run made its L2 (''file'': L1/ and L2/, ''profile'': ' ...
        'profiles_L1/ and profiles_L2/).'], folders{1}, folders{2}, by);
end

grid_dir = metadata.paths.gridded;
grid_file = fullfile(grid_dir, 'gridded.mat');
old = [];
if isfile(grid_file)
    old = load(grid_file);
    if isfield(old, 'source') && ~strcmp(old.source, by)
        fprintf(1, 'MODprocess_grid: %s was made by %s, now by %s - every cast is rebinned.\n', ...
            grid_file, old.source, by);
    end
    if ~isfield(old, 'source') || ~strcmp(old.source, by) || ~isfield(old, 'z_bin_m') || old.z_bin_m ~= z_bin ...
            || ~isfield(old, 'source_stamp') ...
            || ~isfield(old, 'grid_version') || old.grid_version ~= GRID_VERSION
        old = []; % made another way - rebin everything
    end
end

%% One column per cast: reuse it, or bin it
columns = cell(1, numel(casts));
all_sources = {};
n_binned = 0;
for iC = 1:numel(casts)
    c = casts(iC);
    [L1_files, L2_files, gps_files] = cast_sources(c, by, metadata, time_index, dates);
    sources = unique([L1_files, L2_files, gps_files], 'stable');
    % lat is in the stamp (not saved on its own): the scans' depth uses it;
    % so is the position rule (a platform or fish_flag typed in later)
    first_fix = free_fall && strcmp(c.direction, 'down');
    stamp = [c.dnum_end, double(c.complete), lat, double(first_fix), cellfun(@(f) dates(f), sources)];
    all_sources = [all_sources, sources]; %#ok<AGROW>
    k = [];
    if ~isempty(old) && ~isempty(old.cast_start)
        k = find(old.cast_start == c.dnum_start, 1);
    end
    if ~isempty(k) && isequal(old.source_stamp{k}, stamp)
        columns{iC} = column_from_grid(old, k);
    else
        columns{iC} = bin_cast(c, L1_files, L2_files, gps_files, z_bin, lat, cache, first_fix);
        n_binned = n_binned + 1;
    end
    columns{iC}.source_stamp = stamp;
end

if n_binned == 0 && ~isempty(old) && isequal(old.cast_start, [casts.dnum_start])
    gridded = old; % nothing changed - not rewritten
    fprintf(1, 'MODprocess_grid: %d casts, none changed - %s not rewritten\n', numel(casts), grid_file);
    return
end
gridded = assemble(columns, casts, z_bin, by);
gridded.grid_version = GRID_VERSION;
gridded.provenance = MODutil_provenance(unique(all_sources, 'stable'), metadata);
gridded.variables = variables_present(gridded);
if ~isfolder(grid_dir)
    mkdir(grid_dir);
end
MODutil_save_atomic(grid_file, gridded);
fprintf(1, 'MODprocess_grid: %d casts (%d binned), %d depth bins of %g m -> %s\n', ...
    numel(casts), n_binned, numel(gridded.z), z_bin, grid_file);
end %end function

%% The L1 (CTD) and L2 (scans) files that hold a cast, and the L1 files
% that hold its GPS
function [L1_files, L2_files, gps_files] = cast_sources(c, by, metadata, time_index, dates)
L2_files = {};
gps_files = {};
if ~isempty(time_index) && isfield(time_index, 'filename') && ~isempty(time_index.filename)
    overlap = time_index.dnum_start <= c.dnum_end & time_index.dnum_end >= c.dnum_start;
    names = time_index.filename(overlap);
    gps_files = existing(fullfile(metadata.paths.L1, names(:)'), dates);
end
if strcmp(by, 'profile')
    name = sprintf('Profile%04d.mat', c.profile_number);
    L1_files = existing({fullfile(metadata.paths.profiles_L1, name)}, dates);
    L2_files = existing({fullfile(metadata.paths.profiles_L2, name)}, dates);
    return
end
L1_files = gps_files;
if ~isempty(time_index) && isfield(time_index, 'filename') && ~isempty(time_index.filename)
    L2_files = existing(fullfile(metadata.paths.L2, names(:)'), dates);
end
end

function files = existing(files, dates)
files = files(cellfun(@(f) isKey(dates, f), files));
end

%% full path -> datenum of every .mat in these folders
function dates = file_dates(folders)
dates = containers.Map();
for i = 1:numel(folders)
    d = dir(fullfile(folders{i}, '*.mat'));
    for k = 1:numel(d)
        dates(fullfile(folders{i}, d(k).name)) = d(k).datenum;
    end
end
end

%% Bin one cast: one value per bin (1 = 0 to z_bin m) per field
function col = bin_cast(c, L1_files, L2_files, gps_files, z_bin, lat, cache, first_fix)
col = struct('fields', struct(), 'n_bins', 0, 'epsilon_final_source', '');
in_cast = @(t) t >= c.dnum_start & t <= c.dnum_end;

% Position: the first GPS fix during the cast (first_fix) or their mean
% (NaN if none)
fix = zeros(0, 3);
for i = 1:numel(gps_files)
    s = load_cached(cache, gps_files{i}, {'gps'});
    if ~isfield(s, 'gps') || ~isstruct(s.gps) || ~all(isfield(s.gps, {'dnum', 'latitude', 'longitude'})) ...
            || numel(s.gps.latitude) ~= numel(s.gps.dnum) || numel(s.gps.longitude) ~= numel(s.gps.dnum)
        continue
    end
    keep = in_cast(s.gps.dnum(:)) & isfinite(s.gps.latitude(:)) & isfinite(s.gps.longitude(:));
    fix = [fix; s.gps.dnum(keep), s.gps.latitude(keep), s.gps.longitude(keep)]; %#ok<AGROW>
end
[~, iu] = unique(fix(:, 1)); % sorted by time; the same fix from two L1 files is counted once
if first_fix
    iu = iu(1:min(1, end));
end
col.latitude = mean(fix(iu, 2));
col.longitude = mean(fix(iu, 3));
if isempty(iu)
    col.latitude = NaN;
    col.longitude = NaN;
end

% CTD: every L1 sample in the cast
ctd_names = {'P', 'T', 'C', 'SP', 'SR', 'CT', 'sigma0', 'dzdt'};
grid_names = {'pressure', 'temperature', 'conductivity', 'salinity_practical', 'salinity_reference', ...
    'temperature_conservative', 'sigma0', 'fall_speed'};
ctd = struct('dnum', [], 'z', []);
% other L1 records: [dnum, value] of each sample in the cast
% (fluor__<leaf> is gridded.fluor.<leaf>; qc__<ch>_std, from L1 accel,
% gridded.qc.<ch>_std)
extra = struct('pitch', zeros(0, 2), 'tilt', zeros(0, 2), 'roll', zeros(0, 2), ...
    'height_above_bottom', zeros(0, 2), 'fluor__bb', zeros(0, 2), 'fluor__chla', zeros(0, 2), ...
    'fluor__fdom', zeros(0, 2));
fluor_names = struct('fluor__bb', 'bb', 'fluor__chla', 'chla', 'fluor__fdom', 'fDOM');
for i = 1:numel(L1_files)
    s = load_cached(cache, L1_files{i}, {'ctd', 'vnav', 'isap', 'alt', 'fluor', 'accel'});
    for name = {'pitch', 'tilt', 'roll'}
        extra.(name{1}) = [extra.(name{1}); samples_in_cast(s, 'vnav', name{1}, in_cast)];
    end
    for name = fieldnames(fluor_names)'
        extra.(name{1}) = [extra.(name{1}); samples_in_cast(s, 'fluor', fluor_names.(name{1}), in_cast)];
    end
    extra.height_above_bottom = [extra.height_above_bottom; MODutil_altimeter_hab_m(s, in_cast)];
    if isfield(s, 'accel') && isstruct(s.accel)
        for name = fieldnames(s.accel)'
            if endsWith(name{1}, '_std')
                key = ['qc__' name{1}];
                if ~isfield(extra, key)
                    extra.(key) = zeros(0, 2);
                end
                extra.(key) = [extra.(key); samples_in_cast(s, 'accel', name{1}, in_cast)];
            end
        end
    end
    if ~isfield(s, 'ctd') || ~isfield(s.ctd, 'dnum') || ~isfield(s.ctd, 'z') || isempty(s.ctd.dnum)
        continue
    end
    keep = in_cast(s.ctd.dnum(:));
    ctd.dnum = [ctd.dnum; s.ctd.dnum(keep)];
    ctd.z = [ctd.z; s.ctd.z(keep)];
    for f = 1:numel(ctd_names)
        if isfield(s.ctd, ctd_names{f}) && numel(s.ctd.(ctd_names{f})) == numel(s.ctd.dnum)
            if ~isfield(ctd, ctd_names{f})
                ctd.(ctd_names{f}) = nan(numel(ctd.dnum) - nnz(keep), 1);
            end
            x = s.ctd.(ctd_names{f});
            ctd.(ctd_names{f}) = [ctd.(ctd_names{f}); x(keep)];
        elseif isfield(ctd, ctd_names{f})
            ctd.(ctd_names{f}) = [ctd.(ctd_names{f}); nan(nnz(keep), 1)];
        end
    end
end
% the same sample from two L1 files (a damaged copy) is counted once
[ctd.dnum, iu] = unique(ctd.dnum);
ctd.z = ctd.z(iu);
col.time = mean(ctd.dnum, 'omitnan');
ctd_bins = bin_number(ctd.z, z_bin);
for f = 1:numel(ctd_names)
    if isfield(ctd, ctd_names{f})
        col.fields.(grid_names{f}) = bin_mean(ctd_bins, ctd.(ctd_names{f})(iu));
    end
end

% Other L1 records, each sample at the CTD depth at its time
if numel(ctd.dnum) > 1
    for name = fieldnames(extra)'
        x = extra.(name{1});
        if isempty(x)
            continue
        end
        [~, ie] = unique(x(:, 1)); % the same sample from two L1 files is counted once
        x = x(ie, :);
        b = bin_number(interp1(ctd.dnum, ctd.z, x(:, 1)), z_bin);
        if strcmp(name{1}, 'roll')
            m = atan2d(bin_mean(b, sind(x(:, 2))), bin_mean(b, cosd(x(:, 2))));
        else
            m = bin_mean(b, x(:, 2));
        end
        if ~isempty(m)
            col.fields.(name{1}) = m;
        end
    end
end

% Turbulence: the scans whose center is in the cast, each over the bins
% it spans (its footprint)
scans = struct('dnum', [], 'pressure', [], 'half_s', []);
turb = struct();
for i = 1:numel(L2_files)
    s = load_cached(cache, L2_files{i}, [{'dnum', 'pressure', 'nu', 'ktemp', 'n_samples_scan_afe', 'fs_afe', ...
        'epsilon_final', 'epsilon_obs', 'chi_obs', 'chi_ucond', 'coherence_sum', 'Fs_epsi', 'N_epsi'}, ...
        turbulence_groups()]); % the old names only to tell an old L2 file (scan_values)
    if ~isfield(s, 'dnum') || isempty(s.dnum) || ~isfield(s, 'pressure')
        continue
    end
    keep = in_cast(s.dnum(:));
    if ~any(keep)
        continue
    end
    n_before = numel(scans.dnum);
    scans.dnum = [scans.dnum; s.dnum(keep)];
    scans.pressure = [scans.pressure; s.pressure(keep)];
    half_s = NaN; % no scan length: the scan's center bin only
    if isfield(s, 'n_samples_scan_afe') && isfield(s, 'fs_afe')
        half_s = s.n_samples_scan_afe / s.fs_afe / 2;
    end
    scans.half_s = [scans.half_s; repmat(half_s, nnz(keep), 1)];
    [values, source] = scan_values(s);
    if isempty(col.epsilon_final_source)
        col.epsilon_final_source = source;
    end
    names = fieldnames(values);
    for f = 1:numel(names)
        if ~isfield(turb, names{f})
            turb.(names{f}) = nan(n_before, 1);
        end
        turb.(names{f}) = [turb.(names{f}); values.(names{f})(keep)];
    end
    for f = setdiff(fieldnames(turb), names)' % both columns: a column back, made a row
        turb.(f{1}) = [turb.(f{1}); nan(nnz(keep), 1)];
    end
end
if ~isempty(scans.dnum)
    [scans.dnum, iu] = unique(scans.dnum);
    % footprint: the bins from the shallowest to the deepest L1 CTD sample
    % during the scan (in the cast), else the bin of its center pressure
    first = bin_number(-gsw_z_from_p(scans.pressure(iu), lat), z_bin);
    last = first;
    half = scans.half_s(iu) / 86400;
    for k = 1:numel(first)
        in_scan = ctd.dnum >= scans.dnum(k) - half(k) & ctd.dnum <= scans.dnum(k) + half(k);
        zb = bin_number(ctd.z(in_scan), z_bin);
        if any(isfinite(zb))
            first(k) = min(zb);
            last(k) = max(zb);
        end
    end
    % one (bin, scan) pair per bin a scan covers; overlapping scans average
    ok = isfinite(first);
    scan_of = repelem(find(ok), last(ok) - first(ok) + 1);
    pair_bins = cell2mat(arrayfun(@(a, b) (a:b)', first(ok), last(ok), 'UniformOutput', false));
    if isempty(pair_bins)
        pair_bins = zeros(0, 1);
    end
    col.fields.n_scans = bin_count(pair_bins);
    names = fieldnames(turb);
    for f = 1:numel(names)
        x = turb.(names{f})(iu);
        col.fields.(names{f}) = bin_mean(pair_bins, x(scan_of));
    end
end
if isempty(fieldnames(col.fields))
    col.n_bins = 0;
else
    col.n_bins = max(cellfun(@numel, struct2cell(col.fields)));
end
if ~isfield(col, 'time') || isnan(col.time)
    col.time = (c.dnum_start + c.dnum_end) / 2;
end
end

%% Some variables of a .mat, loaded once per call, every vector a column
% (variables the file doesn't have are left out)
function s = load_cached(cache, file, vars)
key = [file '|' strjoin(vars, ',')];
if isKey(cache, key)
    s = cache(key);
    return
end
w = warning('off', 'MATLAB:load:variableNotFound');
restore = onCleanup(@() warning(w));
s = columns_of(load(file, vars{:}));
cache(key) = s;
end

function s = columns_of(s)
if isstruct(s) && isscalar(s)
    names = fieldnames(s);
    for i = 1:numel(names)
        s.(names{i}) = columns_of(s.(names{i}));
    end
elseif isnumeric(s) && isvector(s)
    s = s(:);
end
end

%% [dnum, value] of an L1 record's samples in the cast (none if the file
% doesn't have it, or it's all NaN)
function x = samples_in_cast(s, rec, name, in_cast)
x = zeros(0, 2);
if ~isfield(s, rec) || ~isstruct(s.(rec)) || ~all(isfield(s.(rec), {'dnum', name})) ...
        || numel(s.(rec).(name)) ~= numel(s.(rec).dnum)
    return
end
t = s.(rec).dnum(:);
y = s.(rec).(name)(:);
keep = in_cast(t) & isfinite(y);
x = [t(keep), y(keep)];
end

%% L2's grouped turbulence structs, gridded under the same names
% (gridded.<group>.<leaf>)
function g = turbulence_groups()
g = {'epsilon', 'chi', 'microconductivity', 'kc', 'qc'};
end

%% Every grouped struct in the grid: L2's, and L1's fluor
function g = grouped_fields()
g = [turbulence_groups(), {'fluor'}];
end

%% Per-scan values from an L2 file, as nscan x 1 columns keyed
% <group>__<leaf> (flat while binning; assemble nests them), and its
% epsilon.final_source ('' without epsilon)
function [v, source] = scan_values(s)
v = struct();
source = '';
n = numel(s.dnum);
cutoff_inside = @(g, pattern) isfield(s, g) && isstruct(s.(g)) && any(endsWith(fieldnames(s.(g)), pattern));
if any(isfield(s, {'epsilon_final', 'epsilon_obs', 'chi_obs', 'chi_ucond', 'coherence_sum', 'Fs_epsi', 'N_epsi'})) ...
        || cutoff_inside('epsilon', '_kc') || cutoff_inside('chi', '_kc') ...
        || cutoff_inside('microconductivity', 'chi_obs_kmax')
    error('MODprocess_grid:oldL2Layout', ...
        ['An L2 file is in an older layout (flat epsilon_obs, chi_obs, ..., Fs_epsi/N_epsi, or ' ...
         'cutoffs inside epsilon/chi/microconductivity - now fs_afe/n_samples_scan_afe and kc). ' ...
         'Reprocess L2 (delete processed/<run>/L2/ or reset the survey) and grid again.']);
end
if isfield(s, 'epsilon') && isfield(s.epsilon, 'final_source')
    source = char(s.epsilon.final_source);
end
% molecular properties at the scans (ktemp is all NaN without chi)
long = struct('nu', 'viscosity_kinematic', 'ktemp', 'diffusivity_thermal_molecular');
for name = fieldnames(long)'
    if isfield(s, name{1}) && numel(s.(name{1})) == n && any(isfinite(s.(name{1})))
        v.(long.(name{1})) = s.(name{1})(:);
    end
end
for group = turbulence_groups()
    if ~isfield(s, group{1}) || ~isstruct(s.(group{1}))
        continue
    end
    leaves = fieldnames(s.(group{1}));
    for k = 1:numel(leaves)
        x = s.(group{1}).(leaves{k});
        if isnumeric(x) && numel(x) == n
            v.([group{1} '__' leaves{k}]) = x(:);
        end
    end
end
end

%% Bin numbers (1 = 0 to z_bin m); NaN above the surface or without a depth
function b = bin_number(z, z_bin)
b = floor(z(:) / z_bin) + 1;
b(~(z(:) >= 0)) = NaN;
end

function m = bin_mean(b, x)
ok = ~isnan(b) & ~isnan(x(:));
if ~any(ok)
    m = zeros(0, 1);
    return
end
total = accumarray(b(ok), x(ok));
n = accumarray(b(ok), 1);
m = total ./ n;
m(n == 0) = NaN;
end

function n = bin_count(b)
ok = ~isnan(b);
if ~any(ok)
    n = zeros(0, 1);
    return
end
n = accumarray(b(ok), 1, [], @sum, 0);
end

%% A column taken back out of an earlier grid (grouped fields flattened
% back to <group>__<leaf>)
function col = column_from_grid(old, k)
source = '';
if isfield(old, 'epsilon') && isfield(old.epsilon, 'final_source')
    source = old.epsilon.final_source{k};
end
col = struct('fields', struct(), 'n_bins', 0, 'time', old.time(k), 'latitude', old.latitude(k), ...
    'longitude', old.longitude(k), 'epsilon_final_source', source);
flat = struct();
for name = setdiff(fieldnames(old), [axis_fields(), grouped_fields(), {'z', 'z_bin_m', 'variables', ...
        'source', 'provenance', 'source_stamp', 'grid_version'}])'
    flat.(name{1}) = old.(name{1});
end
for group = intersect(grouped_fields(), fieldnames(old)') % both rows: a row back, one pass per group
    for leaf = setdiff(fieldnames(old.(group{1})), {'final_source'})'
        flat.([group{1} '__' leaf{1}]) = old.(group{1}).(leaf{1});
    end
end
names = fieldnames(flat);
for f = 1:numel(names)
    x = flat.(names{f});
    if isnumeric(x) && size(x, 1) == numel(old.z) && size(x, 2) == numel(old.time)
        x = x(:, k);
        % its own depth, so the grid can get shallower again
        has_data = isfinite(x) & ~(strcmp(names{f}, 'n_scans') & x == 0);
        last = find(has_data, 1, 'last');
        if ~isempty(last)
            col.fields.(names{f}) = x(1:last);
            col.n_bins = max(col.n_bins, last);
        end
    end
end
end

function names = axis_fields()
names = {'time', 'latitude', 'longitude', 'cast_start', 'cast_end', 'cast_direction', 'cast_complete', ...
    'profile_number'};
end

%% Columns -> one grid
function gridded = assemble(columns, casts, z_bin, by)
n = numel(columns);
nz = 0;
names = {};
for i = 1:n
    nz = max(nz, columns{i}.n_bins);
    names = union(names, fieldnames(columns{i}.fields));
end
gridded.z = ((1:nz)' - 0.5) * z_bin;
gridded.z_bin_m = z_bin;
gridded.time = nan(1, n);
gridded.latitude = nan(1, n);
gridded.longitude = nan(1, n);
gridded.cast_start = [casts.dnum_start];
gridded.cast_end = [casts.dnum_end];
gridded.cast_direction = {casts.direction};
gridded.cast_complete = [casts.complete];
gridded.profile_number = [casts.profile_number];
% a group only when some cast has a value in it
for group = grouped_fields()
    if any(startsWith(names, [group{1} '__']))
        gridded.(group{1}) = struct();
    end
end
if isfield(gridded, 'epsilon')
    gridded.epsilon.final_source = repmat({''}, 1, n);
end
for f = 1:numel(names)
    fill = NaN;
    if strcmp(names{f}, 'n_scans')
        fill = 0;
    end
    gridded = set_field(gridded, names{f}, fill * ones(nz, n));
end
gridded.source_stamp = cell(1, n);
for i = 1:n
    gridded.time(i) = columns{i}.time;
    gridded.latitude(i) = columns{i}.latitude;
    gridded.longitude(i) = columns{i}.longitude;
    if isfield(gridded, 'epsilon')
        gridded.epsilon.final_source{i} = columns{i}.epsilon_final_source;
    end
    gridded.source_stamp{i} = columns{i}.source_stamp;
    cn = fieldnames(columns{i}.fields);
    for f = 1:numel(cn)
        x = columns{i}.fields.(cn{f});
        M = get_field(gridded, cn{f});
        M(1:numel(x), i) = x;
        gridded = set_field(gridded, cn{f}, M);
    end
end
if n == 0
    gridded.cast_direction = {};
end
gridded.source = by;
end

%% A column field name -> its place in the grid: <group>__<leaf> is
% gridded.<group>.<leaf>, anything else top-level
function path = field_path(name)
path = strsplit(name, '__');
end

function gridded = set_field(gridded, name, value)
path = field_path(name);
gridded = setfield(gridded, path{:}, value);
end

function value = get_field(gridded, name)
path = field_path(name);
value = getfield(gridded, path{:});
end

%% Units and descriptions of the gridded fields that are present: name is
% the field's path ('temperature', 'epsilon.s1_obs'). A per-channel leaf
% (<channel>_<variant>) takes MODunits_L3's channel_<variant> entry for
% its group, the longest variant that matches.
function v = variables_present(gridded)
units = MODunits_L3();
v = struct('name', {}, 'unit', {}, 'description', {});
names = fieldnames(gridded);
for i = 1:numel(names)
    key = names{i};
    if ismember(key, grouped_fields())
        if ~isfield(units, key)
            continue
        end
        for leaf = fieldnames(gridded.(key))'
            u = leaf_units(units.(key), leaf{1});
            if ~isempty(u)
                v(end+1) = struct('name', [key '.' leaf{1}], 'unit', u.unit, 'description', u.description); %#ok<AGROW>
            end
        end
    elseif isfield(units, key) && isfield(units.(key), 'unit')
        v(end+1) = struct('name', key, 'unit', units.(key).unit, 'description', units.(key).description); %#ok<AGROW>
    end
end
end

function u = leaf_units(group_units, leaf)
u = [];
if isfield(group_units, leaf)
    u = group_units.(leaf);
    return
end
patterns = fieldnames(group_units);
patterns = patterns(startsWith(patterns, 'channel_'));
[~, order] = sort(cellfun(@numel, patterns), 'descend');
for p = patterns(order)'
    if endsWith(leaf, p{1}(numel('channel') + 1:end))
        u = group_units.(p{1});
        return
    end
end
end
