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
%   Field names are long-form (temperature, salinity_practical, ...); L2's
%   per-channel values are <L2 name>_<channel> (epsilon_mle_s1, chi_obs_t2).
%   Three kinds of value, binned the same way (the mean of what falls in
%   the bin):
%     - CTD (pressure, temperature, conductivity, salinity_practical,
%       salinity_reference, temperature_conservative, sigma0, fall_speed):
%       the mean of every L1 CTD sample in the bin, at the CTD's full rate.
%     - Other L1 records (pitch, tilt, roll from vnav; height_above_bottom
%       from isap, or alt without one, leaving out samples pegged at the
%       altimeter's maximum range): the mean of the samples in the bin,
%       each at the CTD depth at its time (interpolated). roll is a
%       circular mean (it wraps at +-180 deg); yaw and spin are headings
%       and are left out.
%     - Scans (viscosity_kinematic, diffusivity_thermal_molecular,
%       epsilon_final, every form of epsilon and chi per channel with their
%       cutoffs, fom and coherence_sum): the mean of the L2 scans whose
%       center is in the bin. A bin with no scan is NaN, and n_scans says
%       how many scans each bin holds. Only casts in the
%       profile_detection.profile_dir direction have scans. L2's
%       scan-center CTD values (pressure, w, temperature, salinity, SR) are
%       left out: they are the L1 CTD interpolated at each scan center, and
%       the L1 bin means above use every sample.
%   Only fields that exist are gridded: the data decide, so a CTD-only
%   vehicle's grid has no turbulence fields, one with no shear channels
%   has no epsilon (L2's epsilon_final_source is empty) and one with
%   no fpo7 channels has no chi.
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
%   uses: a change rebins every cast) - and doesn't rewrite grid.mat when no
%   cast changed. A cast still in progress (cast_complete false) is
%   rebinned every call until it ends. A different by or z_bin_m,
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
%              MODprocess_all_L1_to_L2.m). Either way the GPS comes from
%              the L1 files the cast overlaps (L1/ and L1_meta's
%              time_index.mat).
%
% OUTPUTS
%   grid - (call it something else, e.g. G: grid is Matlab's grid on/off)
%          the struct saved in grid.mat (see setup/MODunits_L3.m for every
%          field): z (bin centers, m), z_bin_m, then per cast
%          (1 x ncast) time, latitude, longitude (first or mean GPS fix
%          during the cast, see above; NaN without one), cast_start, cast_end, cast_direction, cast_complete,
%          profile_number, epsilon_final_source (cellstr, '' for a cast
%          without epsilon), then nz x ncast fields, variables (the units
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
GRID_VERSION = 6; % 2: conductivity C; 3: GPS latitude/longitude per cast, no all-NaN epsilon_final; 4: first fix for Epsi downcasts from the ship; 5: long-form names, every L2 per-scan value, attitude and height above bottom; 6: microconductivity chi. A grid from another version rebins every cast.
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
    grid = old; % nothing changed - not rewritten
    fprintf(1, 'MODprocess_grid: %d casts, none changed - %s not rewritten\n', numel(casts), grid_file);
    return
end
grid = assemble(columns, casts, z_bin, by);
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
extra = struct('pitch', zeros(0, 2), 'tilt', zeros(0, 2), 'roll', zeros(0, 2), ...
    'height_above_bottom', zeros(0, 2));
for i = 1:numel(L1_files)
    s = load_cached(cache, L1_files{i}, {'ctd', 'vnav', 'isap', 'alt'});
    for name = {'pitch', 'tilt', 'roll'}
        extra.(name{1}) = [extra.(name{1}); samples_in_cast(s, 'vnav', name{1}, in_cast)];
    end
    hab = altimeter_in_cast(s, 'isap', in_cast);
    if isempty(hab)
        hab = altimeter_in_cast(s, 'alt', in_cast);
    end
    extra.height_above_bottom = [extra.height_above_bottom; hab];
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

% Turbulence: the scans whose center is in the cast
scans = struct('dnum', [], 'pressure', []);
turb = struct();
for i = 1:numel(L2_files)
    s = load_cached(cache, L2_files{i}, [{'dnum', 'pressure', 'nu', 'ktemp', 'epsilon_final', ...
        'epsilon_final_source'}, channel_kinds()]);
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

%% [dnum, hab] of an altimeter's samples in the cast, without the ones
% pegged at its maximum range (no bottom in range: dst sits at one flat
% value, e.g. 120 m for the ISA500 - MODunits_L1.m); a real range varies
% from sample to sample, so a maximum seen more than once is a peg
function x = altimeter_in_cast(s, rec, in_cast)
x = samples_in_cast(s, rec, 'hab', in_cast);
if isempty(x) || ~isfield(s.(rec), 'dst') || numel(s.(rec).dst) ~= numel(s.(rec).dnum)
    return
end
dst = s.(rec).dst(:);
peg = max(dst);
if nnz(dst == peg) > 1
    [~, k] = ismember(x(:, 1), s.(rec).dnum(:));
    x = x(dst(k) ~= peg, :);
end
end

%% L2's per-channel structs (one field per channel), each gridded as
% <kind>_<channel>; longest first, so variables_present matches
% epsilon_obs_coh_corr_kc before epsilon_obs
function kinds = channel_kinds()
kinds = {'epsilon_obs_coh_corr_kc', 'epsilon_obs_coh_corr', 'epsilon_obs_kc', 'epsilon_obs', ...
    'epsilon_mle', 'fom_mle', 'fom', 'coherence_sum', 'chi_obs_kc', 'chi_obs', 'chi_mle', ...
    'chi_ucond_kmax', 'chi_ucond'};
end

%% Per-scan values from an L2 file, as nscan x 1 columns, and its
% epsilon_final_source ('' without epsilon)
function [v, source] = scan_values(s)
v = struct();
source = '';
n = numel(s.dnum);
% epsilon_final only where L2 computed it (L2 files made before
% 2026-10-17 have an all-NaN epsilon_final and an empty
% epsilon_final_source when there were no shear probes)
if isfield(s, 'epsilon_final') && numel(s.epsilon_final) == n ...
        && isfield(s, 'epsilon_final_source') && ~isempty(s.epsilon_final_source)
    v.epsilon_final = s.epsilon_final(:);
    source = char(s.epsilon_final_source);
end
% molecular properties at the scans (ktemp is all NaN without chi)
long = struct('nu', 'viscosity_kinematic', 'ktemp', 'diffusivity_thermal_molecular');
for name = fieldnames(long)'
    if isfield(s, name{1}) && numel(s.(name{1})) == n && any(isfinite(s.(name{1})))
        v.(long.(name{1})) = s.(name{1})(:);
    end
end
for kind = channel_kinds()
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
col = struct('fields', struct(), 'n_bins', 0, 'time', old.time(k), 'latitude', old.latitude(k), ...
    'longitude', old.longitude(k), 'epsilon_final_source', old.epsilon_final_source{k});
names = setdiff(fieldnames(old), [axis_fields(), {'z', 'z_bin_m', 'variables', 'source', ...
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
names = {'time', 'latitude', 'longitude', 'cast_start', 'cast_end', 'cast_direction', 'cast_complete', ...
    'profile_number', 'epsilon_final_source'};
end

%% Columns -> one grid
function grid = assemble(columns, casts, z_bin, by)
n = numel(columns);
nz = 0;
names = {};
for i = 1:n
    nz = max(nz, columns{i}.n_bins);
    names = union(names, fieldnames(columns{i}.fields));
end
grid.z = ((1:nz)' - 0.5) * z_bin;
grid.z_bin_m = z_bin;
grid.time = nan(1, n);
grid.latitude = nan(1, n);
grid.longitude = nan(1, n);
grid.cast_start = [casts.dnum_start];
grid.cast_end = [casts.dnum_end];
grid.cast_direction = {casts.direction};
grid.cast_complete = [casts.complete];
grid.profile_number = [casts.profile_number];
grid.epsilon_final_source = repmat({''}, 1, n);
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
    grid.latitude(i) = columns{i}.latitude;
    grid.longitude(i) = columns{i}.longitude;
    grid.epsilon_final_source{i} = columns{i}.epsilon_final_source;
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
    pattern = regexprep(key, ['^(' strjoin(channel_kinds(), '|') ')_.+$'], '$1_channel');
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
