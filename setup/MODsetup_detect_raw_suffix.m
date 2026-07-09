function raw_file_suffix = MODsetup_detect_raw_suffix(raw_dir)
% MODsetup_detect_raw_suffix        Part of MOD_fish_processing
%
% raw_file_suffix = MODsetup_detect_raw_suffix(raw_dir)
%
% DESCRIPTION
%   Guesses the raw data file suffix in raw_dir by listing every file,
%   excluding known non-raw extensions and hidden/system files, and
%   picking whichever extension is most common among what's left. Lets
%   MODprocess_all_modraw_to_L0.m find .modraw files today and something
%   else (e.g. .raw) later without a code change.
%
%   Deliberately extension-frequency based, not a binary-vs-text content
%   check: .mat files are binary too (that's MATLAB's own format), so
%   "is this file binary" does not distinguish raw data from L0 output
%   sitting in the wrong folder. Excluding known non-raw extensions and
%   taking the dominant remaining one is simpler and more reliable.
%
% INPUTS
%   raw_dir - full path to a folder of raw data files
%
% OUTPUTS
%   raw_file_suffix - detected suffix, including the leading dot (e.g. '.modraw')
%
% CALLED BY
%   MODprocess_all_modraw_to_L0.m
%
% CALLS
%   (none)
%
% NOTES
%   Errors instead of guessing if the folder has no candidate files, or
%   if two or more extensions are tied for most common - in both cases
%   the caller should pass raw_file_suffix explicitly rather than rely
%   on detection.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% Extensions that are never the raw data type itself - L0/L1 output,
% config/metadata, or OS/editor noise.
exclude_ext = {'.mat', '.json', '.csv', '.txt', '.yml', '.yaml', ...
    '.log', '.md', '.m', '.asv', '.mlx', ''};

listing = dir(raw_dir);
listing = listing(~[listing.isdir]);

% Drop hidden/system files (.DS_Store, dotfiles)
listing = listing(~startsWith({listing.name}, '.'));

if isempty(listing)
    error('MODsetup_detect_raw_suffix:noFiles', ...
        'No files found in %s', raw_dir);
end

[~, ~, ext] = cellfun(@fileparts, {listing.name}, 'UniformOutput', false);
ext = lower(ext);
ext = ext(~ismember(ext, exclude_ext));

if isempty(ext)
    error('MODsetup_detect_raw_suffix:onlyNonRawFiles', ...
        ['Only non-raw file types (.mat, .json, etc.) found in %s.\n' ...
         'This may be an L0/ folder rather than raw/ - or pass ' ...
         'raw_file_suffix explicitly to MODprocess_all_modraw_to_L0.'], raw_dir);
end

[uniq_ext, ~, ic] = unique(ext);
counts = accumarray(ic(:), 1);
[max_count, idx] = max(counts);

if sum(counts == max_count) > 1
    tied = strjoin(uniq_ext(counts == max_count), ', ');
    error('MODsetup_detect_raw_suffix:ambiguous', ...
        ['Cannot auto-detect raw file suffix in %s - multiple file ' ...
         'types are equally common (%s). Pass raw_file_suffix ' ...
         'explicitly to MODprocess_all_modraw_to_L0.'], raw_dir, tied);
end

raw_file_suffix = uniq_ext{idx};

end
