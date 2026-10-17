function grid = MODprocess_grid(metadata, by)
% MODprocess_grid        Part of MOD_fish_processing
%
% G = MODprocess_grid(metadata)
% G = MODprocess_grid(metadata, by)
%
% DESCRIPTION
%   Puts a processing run's casts on a depth grid: one column per cast in
%   the run's cast table (meta/casts.mat, MODprocess_L1_update_cast_table.m),
%   down and up casts both, one row per depth bin of grid.z_bin_m meters.
%   Saves processed/<run>/grid/grid.mat.
%
%   Two kinds of value, binned the same way (the mean of what falls in the
%   bin, nothing interpolated):
%     - CTD (T, SP, SR, CT, sigma0, w, P): the mean of every L1 CTD sample
%       in the bin, at the CTD's full rate.
%     - Turbulence (epsilon_final, chi_obs_<ch>, chi_mle_<ch>): the mean of
%       the L2 scans whose center is in the bin. A bin with no scan is NaN,
%       and n_scans says how many scans each bin holds. Only casts in the
%       profile_detection.profile_dir direction have scans.
%   Only fields that exist are gridded: the manifest decides, so a CTD-only
%   vehicle's grid has no turbulence fields and one with no fpo7 channels
%   has no chi.
%
%   Each call rebins only the casts that are new or changed - a cast whose
%   start, end and source files (their times) are the same as when it was
%   last binned keeps its column - and doesn't rewrite grid.mat when no
%   cast changed. A cast still in progress (cast_complete false) is
%   rebinned every call until it ends. A different by, z_bin_m or latitude,
%   or a grid made by another version of this function (grid_version),
%   rebins every cast. Each source folder is listed once per call and each
%   file loaded at most once (only the variables used).
%
% INPUTS
%   metadata - from MODsetup_read_yaml.m. Uses metadata.paths (grid, meta,
%              L1_meta, L1, L2, profiles_L1, profiles_L2),
%              metadata.PROCESS.latitude and grid.z_bin_m
%              (metadata.PROCESS.GRID.z_bin_m).
%   by       - (optional) where the data come from: 'file' (default) -
%              the L1 and L2 files a cast overlaps (time_index.mat), as
%              realtime; or 'profile' - processed/<run>/profiles_L1/ and
%              profiles_L2/ (MODprocess_all_extract_profiles.m, then
%              MODprocess_all_L1_to_L2.m).
%
% OUTPUTS
%   grid - (call it something else, e.g. G: grid is Matlab's grid on/off)
%          the struct saved in grid.mat (see setup/MODunits_L3.m for every
%          field): z (bin centers, m), z_bin_m, latitude, then per cast (1 x ncast)
%          time, cast_start, cast_end, cast_direction, cast_complete,
%          profile_number, then nz x ncast fields, variables (the units
%          and descriptions of the fields present), source ('file' or
%          'profile'), provenance. An empty grid (no columns) if there are
%          no casts yet.
%
% CALLED BY
%   MODprocess_deployment.m (stage 'grid'), templates/MODtemplate_postprocess_steps.m
%
% CALLS
%   MODsetup_validate_metadata.m, MODunits_L3.m, MODutil_provenance.m,
%   MODutil_save_atomic.m, gsw_z_from_p.m (Gibbs SeaWater toolbox)
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
GRID_VERSION = 2; % 2: conductivity C added. A grid from another version rebins every cast.
if ~(z_bin > 0)
    error('MODprocess_grid:badZBin', 'grid.z_bin_m must be > 0 m (got %g).', z_bin);
end
lat = metadata.PROCESS.latitude;

casts_file = fullfile(metadata.paths.meta, 'casts.mat');
if ~isfile(casts_file)
    error('MODprocess_grid:noCasts', ['%s does not exist yet - make the cast table first ' ...
        '(MODprocess_L1_update_cast_table.m).'], casts_file);
end
saved = load(casts_file, 'casts');
casts = saved.casts;

time_index = [];
if strcmp(by, 'file')
    ti_file = fullfile(metadata.paths.L1_meta, 'time_index.mat');
    if ~isfile(ti_file)
        error('MODprocess_grid:noTimeIndex', '%s does not exist yet - it is made with L1.', ti_file);
    end
    time_index = load(ti_file);
    folders = {metadata.paths.L1, metadata.paths.L2};
else
    folders = {metadata.paths.profiles_L1, metadata.paths.profiles_L2};
end
% each folder listed once per call, and each file loaded at most once
dates = file_dates(folders);
cache = containers.Map();
if ~isempty(casts) && dates.Count == 0
    % e.g. by 'profile' on a run that made L2 by file - don't replace its grid
    error('MODprocess_grid:noSources', ['No .mat files in %s or %s - nothing to grid by ''%s''. ' ...
        'by must match how this run made its L2 (''file'': L1/ and L2/, ''profile'': ' ...
        'profiles_L1/ and profiles_L2/).'], folders{1}, folders{2}, by);
end

grid_dir = metadata.paths.grid;
grid_file = fullfile(grid_dir, 'grid.mat');
old = [];
if isfile(grid_file)
    old = load(grid_file);
    if isfield(old, 'source') && ~strcmp(old.source, by)
        fprintf(1, 'MODprocess_grid: %s was made by %s, now by %s - every cast is rebinned.\n', ...
            grid_file, old.source, by);
    end
    if ~isfield(old, 'source') || ~strcmp(old.source, by) || ~isfield(old, 'z_bin_m') || old.z_bin_m ~= z_bin ...
            || ~isfield(old, 'latitude') || ~isequal(old.latitude, lat) || ~isfield(old, 'source_stamp') ...
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
    [L1_files, L2_files] = cast_sources(c, by, metadata, time_index, dates);
    stamp = [c.dnum_end, double(c.complete), cellfun(@(f) dates(f), [L1_files, L2_files])];
    all_sources = [all_sources, L1_files, L2_files]; %#ok<AGROW>
    k = [];
    if ~isempty(old) && ~isempty(old.cast_start)
        k = find(old.cast_start == c.dnum_start, 1);
    end
    if ~isempty(k) && isequal(old.source_stamp{k}, stamp)
        columns{iC} = column_from_grid(old, k);
    else
        columns{iC} = bin_cast(c, L1_files, L2_files, z_bin, lat, cache);
        n_binned = n_binned + 1;
    end
    columns{iC}.source_stamp = stamp;
end

if n_binned == 0 && ~isempty(old) && isequal(old.cast_start, [casts.dnum_start])
    grid = old; % nothing changed - not rewritten
    fprintf(1, 'MODprocess_grid: %d casts, none changed - %s not rewritten\n', numel(casts), grid_file);
    return
end
grid = assemble(columns, casts, z_bin, lat, by);
grid.grid_version = GRID_VERSION;
grid.provenance = MODutil_provenance(unique(all_sources, 'stable'), metadata);
grid.variables = variables_present(grid);
if ~isfolder(grid_dir)
    mkdir(grid_dir);
end
MODutil_save_atomic(grid_file, grid);
fprintf(1, 'MODprocess_grid: %d casts (%d binned), %d depth bins of %g m -> %s\n', ...
    numel(casts), n_binned, numel(grid.z), z_bin, grid_file);
end %end function

%% The L1 (CTD) and L2 (scans) files that hold a cast
function [L1_files, L2_files] = cast_sources(c, by, metadata, time_index, dates)
if strcmp(by, 'profile')
    name = sprintf('Profile%04d.mat', c.profile_number);
    L1_files = existing({fullfile(metadata.paths.profiles_L1, name)}, dates);
    L2_files = existing({fullfile(metadata.paths.profiles_L2, name)}, dates);
    return
end
L1_files = {};
L2_files = {};
if isempty(time_index) || ~isfield(time_index, 'filename') || isempty(time_index.filename)
    return
end
overlap = time_index.dnum_start <= c.dnum_end & time_index.dnum_end >= c.dnum_start;
names = time_index.filename(overlap);
L1_files = existing(fullfile(metadata.paths.L1, names(:)'), dates);
L2_files = existing(fullfile(metadata.paths.L2, names(:)'), dates);
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
function col = bin_cast(c, L1_files, L2_files, z_bin, lat, cache)
col = struct('fields', struct(), 'n_bins', 0);
in_cast = @(t) t >= c.dnum_start & t <= c.dnum_end;

% CTD: every L1 sample in the cast
ctd_names = {'P', 'T', 'C', 'SP', 'SR', 'CT', 'sigma0', 'dzdt'};
grid_names = {'P', 'T', 'C', 'SP', 'SR', 'CT', 'sigma0', 'w'};
ctd = struct('dnum', [], 'z', []);
for i = 1:numel(L1_files)
    s = load_cached(cache, L1_files{i}, {'ctd'});
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

% Turbulence: the scans whose center is in the cast
scans = struct('dnum', [], 'pressure', []);
turb = struct();
for i = 1:numel(L2_files)
    s = load_cached(cache, L2_files{i}, {'dnum', 'pressure', 'epsilon_final', 'chi_obs', 'chi_mle'});
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
    values = scan_values(s);
    names = fieldnames(values);
    for f = 1:numel(names)
        if ~isfield(turb, names{f})
            turb.(names{f}) = nan(n_before, 1);
        end
        turb.(names{f}) = [turb.(names{f}); values.(names{f})(keep)];
    end
    for f = setdiff(fieldnames(turb)', names)
        turb.(f{1}) = [turb.(f{1}); nan(nnz(keep), 1)];
    end
end
if ~isempty(scans.dnum)
    [scans.dnum, iu] = unique(scans.dnum);
    scan_bins = bin_number(-gsw_z_from_p(scans.pressure(iu), lat), z_bin);
    col.fields.n_scans = bin_count(scan_bins);
    names = fieldnames(turb);
    for f = 1:numel(names)
        col.fields.(names{f}) = bin_mean(scan_bins, turb.(names{f})(iu));
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

%% Per-scan turbulence values from an L2 file, as nscan x 1 columns
function v = scan_values(s)
v = struct();
n = numel(s.dnum);
if isfield(s, 'epsilon_final') && numel(s.epsilon_final) == n
    v.epsilon_final = s.epsilon_final(:);
end
for kind = {'chi_obs', 'chi_mle'}
    if isfield(s, kind{1}) && isstruct(s.(kind{1}))
        channels = fieldnames(s.(kind{1}));
        for k = 1:numel(channels)
            x = s.(kind{1}).(channels{k});
            if numel(x) == n
                v.([kind{1} '_' channels{k}]) = x(:);
            end
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

%% A column taken back out of an earlier grid
function col = column_from_grid(old, k)
col = struct('fields', struct(), 'n_bins', 0, 'time', old.time(k));
names = setdiff(fieldnames(old), [axis_fields(), {'z', 'z_bin_m', 'latitude', 'variables', 'source', ...
    'provenance', 'source_stamp', 'grid_version'}]);
for f = 1:numel(names)
    x = old.(names{f});
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
names = {'time', 'cast_start', 'cast_end', 'cast_direction', 'cast_complete', 'profile_number'};
end

%% Columns -> one grid
function grid = assemble(columns, casts, z_bin, lat, by)
n = numel(columns);
nz = 0;
names = {};
for i = 1:n
    nz = max(nz, columns{i}.n_bins);
    names = union(names, fieldnames(columns{i}.fields));
end
grid.z = ((1:nz)' - 0.5) * z_bin;
grid.z_bin_m = z_bin;
grid.latitude = lat;
grid.time = nan(1, n);
grid.cast_start = [casts.dnum_start];
grid.cast_end = [casts.dnum_end];
grid.cast_direction = {casts.direction};
grid.cast_complete = [casts.complete];
grid.profile_number = [casts.profile_number];
for f = 1:numel(names)
    fill = NaN;
    if strcmp(names{f}, 'n_scans')
        fill = 0;
    end
    grid.(names{f}) = fill * ones(nz, n);
end
grid.source_stamp = cell(1, n);
for i = 1:n
    grid.time(i) = columns{i}.time;
    grid.source_stamp{i} = columns{i}.source_stamp;
    cn = fieldnames(columns{i}.fields);
    for f = 1:numel(cn)
        x = columns{i}.fields.(cn{f});
        grid.(cn{f})(1:numel(x), i) = x;
    end
end
if n == 0
    grid.cast_direction = {};
end
grid.source = by;
end

%% Units and descriptions of the gridded fields that are present
function v = variables_present(grid)
units = MODunits_L3();
v = struct('name', {}, 'unit', {}, 'description', {});
names = fieldnames(grid);
for i = 1:numel(names)
    key = names{i};
    pattern = regexprep(key, '^(chi_obs|chi_mle)_.+$', '$1_channel');
    if isfield(units, key)
        u = units.(key);
    elseif isfield(units, pattern)
        u = units.(pattern);
    else
        continue
    end
    v(end+1) = struct('name', key, 'unit', u.unit, 'description', u.description); %#ok<AGROW>
end
end
