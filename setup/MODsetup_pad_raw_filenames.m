function n_renamed = MODsetup_pad_raw_filenames(raw_dir, options)
% MODsetup_pad_raw_filenames        Part of MOD_fish_processing
%
% n_renamed = MODsetup_pad_raw_filenames(raw_dir, Name, Value, ...)
%
% DESCRIPTION
%   Renames raw files whose names end in an unpadded number (modsom_0,
%   modsom_1, ..., modsom_192) to zero-padded names (modsom_000,
%   modsom_001, ...) so that alphabetical file listings sort in
%   chronological order. Files are renamed in place with movefile - the
%   contents are never read or written, only the directory entry changes -
%   and every rename is verified (same byte count) and recorded in
%   meta/FilenamePadLog.csv next to raw_dir.
%
%   If a sibling L0 folder already holds converted .mat files under the
%   old names, those are renamed to match and the raw_file_info.filename
%   field inside each is updated, so MODprocess_all_modraw_to_L0 still
%   recognizes them as already converted.
%
%   Does nothing (and says so) when names are date-based or already
%   padded, so it is safe to call on every processing run.
%
%   Confirmation, unless force is set, is a small centered dialog when a
%   display is available - this is what to use if a terminal y/n prompt
%   can't be answered (e.g. running MATLAB through VS Code). It lists the
%   actual renames (up to 3 examples plus a count of the rest) and, if
%   pad_width was not already fixed by the caller, a spinner to change
%   the zero-padding digit count before confirming. Falls back to text
%   prompts (digit count, then y/n) when there is no display, and to a
%   no-op warning under -batch, where neither kind of prompt can be
%   answered.
%
% INPUTS
%   raw_dir - full path to a folder of raw data files
%
% NAME-VALUE ARGUMENTS (any order)
%   raw_file_suffix - e.g. '.modraw'. Default: auto-detected by
%                      MODsetup_detect_raw_suffix.m.
%   L0_dir          - folder of converted .mat files to rename in step
%                      with the raw files. Default: a sibling 'L0' folder
%                      next to raw_dir, if it exists.
%   force           - true to skip the confirmation prompt/dialog
%                      entirely. Default: false.
%   pad_width       - zero-pad to this many digits instead of the default
%                      max(3, widest number already present). Useful when
%                      you know the run won't grow past the current file
%                      count, e.g. pad_width=2 for a post-processed
%                      deployment that maxes out at 99 files. Default: 0
%                      (auto) - when running interactively, 0 also means
%                      "let me choose in the dialog/prompt", pre-filled
%                      with the auto value.
%
% OUTPUTS
%   n_renamed - number of raw files renamed (0 if nothing needed doing,
%               the user declined, or MATLAB is running with -batch and
%               force was not set)
%
% CALLED BY
%   MODprocess_all_modraw_to_L0.m
%
% CALLS
%   MODsetup_detect_raw_suffix.m
%   MODutil_short_path.m (console messages only)
%
% NOTES
%   Auto width (pad_width=0), per numeric prefix: if every file's trailing
%   number already has the same digit width, nothing is renamed - equal
%   widths already sort correctly regardless of how many digits that is
%   (modsom_00..modsom_45 needs no padding). Only actually mixed widths
%   (e.g. modsom_1, modsom_2, ..., modsom_45) get padded, to
%   max(3, widest number present) so there's room to grow before the next
%   re-pad is needed. pad_width overrides this and forces every file in
%   that prefix to the given width regardless of whether it was already
%   uniform.
%
%   If a deployment could grow past 999 files, run this once up front so
%   the width is settled before processing starts. Real-time acquisition
%   always names files by timestamp rather than a running number, so a
%   fixed pad_width is really only useful when post-processing a
%   finished, unpadded numbered run.
%
%   In non-interactive MATLAB (-batch) neither the dialog nor the text
%   prompt can be answered, so without force=true the function warns and
%   does nothing rather than renaming files unprompted.
%
% EXAMPLE
%   MODsetup_pad_raw_filenames(raw_dir, 'force', true, 'pad_width', 2)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    raw_dir (1,:) char
    options.raw_file_suffix (1,:) char = ''
    options.L0_dir (1,:) char = ''
    options.force (1,1) logical = false
    options.pad_width (1,1) double {mustBeInteger, mustBeNonnegative} = 0
end

raw_file_suffix = options.raw_file_suffix;
if isempty(raw_file_suffix)
    raw_file_suffix = MODsetup_detect_raw_suffix(raw_dir);
end
L0_dir = options.L0_dir;
if isempty(L0_dir)
    L0_dir = fullfile(fileparts(raw_dir), 'L0');
end
force = options.force;
pad_width = options.pad_width;

n_renamed = 0;

listing = dir(fullfile(raw_dir, ['*', raw_file_suffix]));
listing = listing(~startsWith({listing.name}, '.'));
if isempty(listing)
    fprintf('MODsetup_pad_raw_filenames: no %s files in %s\n', raw_file_suffix, MODutil_short_path(raw_dir));
    return
end

% Split each base name into prefix + trailing number (empty if no number)
nf = numel(listing);
old_base = cell(nf,1);
prefix   = cell(nf,1);
idx      = nan(nf,1);
width    = nan(nf,1);
for k = 1:nf
    old_base{k} = listing(k).name(1:end-numel(raw_file_suffix));
    t = regexp(old_base{k}, '^(.*?)(\d+)$', 'tokens', 'once');
    if ~isempty(t)
        prefix{k} = t{1};
        idx(k)    = str2double(t{2});
        width(k)  = numel(t{2});
    end
end

isnum = ~isnan(idx);
if ~any(isnum)
    fprintf('MODsetup_pad_raw_filenames: no trailing-number filenames in %s - nothing to pad\n', MODutil_short_path(raw_dir));
    return
end

suggested_pad_width = auto_pad_width(width(isnum));

% Nothing to do? Check up front, before any prompt/dialog - using
% whichever pad_width was actually requested (0 for auto, or an explicit
% override). If it wouldn't rename anything, say so and return without
% ever asking - no point popping a dialog (or a text prompt) to confirm
% an empty rename set. If pad_width is an explicit override that would
% still change something, this correctly falls through to prompting.
if isequal(pad_new_basenames(old_base, prefix, idx, width, isnum, pad_width), old_base)
    fprintf('MODsetup_pad_raw_filenames: filenames in %s already padded\n', MODutil_short_path(raw_dir));
    return
end

interactive = ~force && ~batchStartupOptionUsed && feature('ShowFigureWindows');

if interactive
    % Let the user see the actual renames - and, unless pad_width was
    % already fixed by the caller, choose the digit count - before
    % anything is checked or touched.
    [do_rename, pad_width] = pad_width_dialog(old_base, prefix, idx, width, isnum, raw_file_suffix, pad_width);
    if ~do_rename
        fprintf('MODsetup_pad_raw_filenames: no files renamed\n');
        return
    end
    force = true; % already confirmed above - skip the plain y/n prompt below
elseif pad_width == 0 && ~force && ~batchStartupOptionUsed
    % No display to show a dialog on - fall back to a text prompt for the
    % digit count (the y/n confirmation itself still happens below).
    resp = strtrim(input(sprintf('Digits to pad to? [%d]: ', suggested_pad_width), 's'));
    resp_num = str2double(resp);
    if ~isempty(resp) && ~isnan(resp_num) && resp_num >= 1
        pad_width = round(resp_num);
    else
        pad_width = suggested_pad_width;
    end
end

new_base = pad_new_basenames(old_base, prefix, idx, width, isnum, pad_width);

% Two old names must never map to one new name (e.g. modsom_1 + modsom_001)
[uniq_new, ~, ic] = unique(new_base);
counts = accumarray(ic, 1);
if any(counts > 1)
    dupes = strjoin(uniq_new(counts > 1), ', ');
    error('MODsetup_pad_raw_filenames:duplicateTarget', ...
        ['Cannot pad filenames in %s - multiple files would collapse onto ' ...
         'the same padded name (%s). Resolve the duplicates by hand first.'], ...
        raw_dir, dupes);
end

changed = find(~strcmp(old_base, new_base));
if isempty(changed)
    fprintf('MODsetup_pad_raw_filenames: filenames in %s already padded\n', MODutil_short_path(raw_dir));
    return
end

% A padded target must not already exist as some file we are not renaming
for k = changed'
    target = fullfile(raw_dir, [new_base{k}, raw_file_suffix]);
    if isfile(target) && ~ismember(new_base{k}, old_base)
        error('MODsetup_pad_raw_filenames:targetExists', ...
            '%s already exists - will not overwrite it with a renamed %s%s', ...
            target, old_base{k}, raw_file_suffix);
    end
end

% Confirm before touching anything
fprintf('MODsetup_pad_raw_filenames: %d of %d %s files in %s need zero-padding, e.g.\n', ...
    numel(changed), nf, raw_file_suffix, MODutil_short_path(raw_dir));
nshow = min(3, numel(changed));
for k = changed(1:nshow)'
    fprintf('    %s%s -> %s%s\n', old_base{k}, raw_file_suffix, new_base{k}, raw_file_suffix);
end
if numel(changed) > nshow
    fprintf('    ... and %d more\n', numel(changed) - nshow);
end

if ~force
    if batchStartupOptionUsed
        warning('MODsetup_pad_raw_filenames:batchSkip', ...
            ['MATLAB is running non-interactively, so no confirmation prompt is possible. ' ...
             'Files were NOT renamed. Call MODsetup_pad_raw_filenames(raw_dir, ''force'', true) to rename.']);
        return
    end
    % interactive (dialog) confirmation already happened above and set
    % force = true, so only the no-display text fallback reaches here.
    if numel(changed) == 1
        plural_s = '';
    else
        plural_s = 's';
    end
    prompt_msg = sprintf(['Rename %d %s file%s in place?\n' ...
        '(contents untouched, log written to meta/FilenamePadLog.csv)'], ...
        numel(changed), raw_file_suffix, plural_s);
    resp = input([prompt_msg, ' y/n: '], 's');
    if ~strcmpi(strtrim(resp), 'y')
        fprintf('MODsetup_pad_raw_filenames: no files renamed\n');
        return
    end
end

% Open the log (append mode; header only when the file is new)
meta_dir = fullfile(fileparts(raw_dir), 'meta');
if ~exist(meta_dir, 'dir')
    mkdir(meta_dir);
end
log_path = fullfile(meta_dir, 'FilenamePadLog.csv');
new_log = ~isfile(log_path);
fid = fopen(log_path, 'a');
if fid == -1
    error('MODsetup_pad_raw_filenames:logOpenFailed', 'Cannot open %s for writing', log_path);
end
if new_log
    fprintf(fid, '# MODsetup_pad_raw_filenames rename log - files renamed in place, contents untouched\n');
    fprintf(fid, 'datetime_utc,folder,old_name,new_name\n');
end
tstamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z'''));

% Rename raw files, verifying byte count after each move
for k = changed'
    old_path = fullfile(raw_dir, [old_base{k}, raw_file_suffix]);
    new_path = fullfile(raw_dir, [new_base{k}, raw_file_suffix]);
    movefile(old_path, new_path);
    d = dir(new_path);
    if isempty(d) || d.bytes ~= listing(k).bytes
        fclose(fid);
        error('MODsetup_pad_raw_filenames:verifyFailed', ...
            'Byte count changed renaming %s -> %s (expected %d). Check meta/FilenamePadLog.csv.', ...
            old_path, new_path, listing(k).bytes);
    end
    fprintf(fid, '%s,raw,%s%s,%s%s\n', tstamp, old_base{k}, raw_file_suffix, new_base{k}, raw_file_suffix);
    n_renamed = n_renamed + 1;
end

% Rename any matching L0 .mat files and update raw_file_info.filename so
% the already-converted check in MODprocess_all_modraw_to_L0 still matches
n_L0 = 0;
if isfolder(L0_dir)
    for k = changed'
        old_mat = fullfile(L0_dir, [old_base{k}, '.mat']);
        new_mat = fullfile(L0_dir, [new_base{k}, '.mat']);
        if ~isfile(old_mat)
            continue
        end
        movefile(old_mat, new_mat);
        S = load(new_mat, 'raw_file_info');
        if isfield(S, 'raw_file_info')
            raw_file_info = S.raw_file_info;
            raw_file_info.filename = new_base{k};
            save(new_mat, 'raw_file_info', '-append');
        end
        fprintf(fid, '%s,L0,%s.mat,%s.mat\n', tstamp, old_base{k}, new_base{k});
        n_L0 = n_L0 + 1;
    end
end

fclose(fid);
fprintf('MODsetup_pad_raw_filenames: renamed %d raw files', n_renamed);
if n_L0 > 0
    fprintf(' and %d L0 .mat files', n_L0);
end
fprintf(' - log: %s\n', MODutil_short_path(log_path));

end

function new_base = pad_new_basenames(old_base, prefix, idx, width, isnum, pad_width)
% Padded name per file. pad_width = 0 means "auto" - see auto_pad_width.
% pad_width > 0 applies that width to every prefix uniformly.
new_base = old_base;
for p = unique(prefix(isnum))'
    m = isnum & strcmp(prefix, p{1});
    if pad_width > 0
        pad = pad_width;
    else
        pad = auto_pad_width(width(m));
    end
    for k = find(m)'
        new_base{k} = sprintf('%s%0*d', p{1}, pad, idx(k));
    end
end
end

function pad = auto_pad_width(width_group)
% Auto (pad_width=0) padding width for one group of trailing numbers -
% either all files sharing one prefix, or (for the top-level suggestion)
% all numbered files regardless of prefix. If every number in the group
% already has the same digit width, that width is already correct -
% filenames sort fine as-is (00, 01, ..., 45 is fine; only mixed widths
% like 1, 2, 45 break alphabetical sorting). Only mixed widths get bumped,
% to max(3, widest) so there's room to grow before the next re-pad is
% needed.
if numel(unique(width_group)) == 1
    pad = width_group(1);
else
    pad = max(3, max(width_group));
end
end

function txt = build_preview_text(old_base, prefix, idx, width, isnum, raw_file_suffix, pad_width)
% Human-readable preview of what pad_width would rename, e.g.
%   43 files total
%   3 files need zero-padding, e.g.
%   modsom_0.modraw -> modsom_000.modraw
%   modsom_1.modraw -> modsom_001.modraw
%   modsom_2.modraw -> modsom_002.modraw
% Total is shown up front so you can tell, before picking a width,
% whether the file count itself is 2 digits or 3.
total_line = sprintf('%d files total', numel(old_base));
new_base = pad_new_basenames(old_base, prefix, idx, width, isnum, pad_width);
changed = find(~strcmp(old_base, new_base));
n = numel(changed);
if n == 0
    txt = sprintf('%s\nNo files need zero-padding at %d digits.', total_line, pad_width);
    return
end
nshow = min(3, n);
lines = cell(nshow + (n > nshow), 1);
for i = 1:nshow
    k = changed(i);
    lines{i} = sprintf('%s%s -> %s%s', old_base{k}, raw_file_suffix, new_base{k}, raw_file_suffix);
end
if n > nshow
    lines{end} = sprintf('... and %d more', n - nshow);
end
txt = sprintf('%s\n%d file%s need zero-padding, e.g.\n%s', ...
    total_line, n, repmat('s', 1, n ~= 1), strjoin(lines, newline));
end

function [do_rename, pad_width] = pad_width_dialog(old_base, prefix, idx, width, isnum, raw_file_suffix, pad_width)
% Small modal dialog: shows the actual renames (up to 3 examples plus a
% count of the rest) and, unless pad_width was already fixed by the
% caller, a spinner to change the zero-padding digit count before
% confirming. Returns do_rename = false if the user cancels or closes
% the window without choosing Rename.

editable = pad_width == 0;
if editable
    pad_width = auto_pad_width(width(isnum)); % starting suggestion
end

dlg_w = 480;
dlg_h = 300;
% uifigure Position is always in pixels (its Units cannot be changed);
% force groot's Units to pixels too before reading ScreenSize so the two
% are guaranteed to agree, regardless of any prior session-wide Units
% customization.
root_units = get(groot, 'Units');
cleanup_units = onCleanup(@() set(groot, 'Units', root_units));
set(groot, 'Units', 'pixels');
scr = get(groot, 'ScreenSize');
dlg_pos = [scr(1) + (scr(3) - dlg_w)/2, scr(2) + (scr(4) - dlg_h)/2, dlg_w, dlg_h];

% uiconfirm/uifigure (not questdlg) - questdlg is a legacy Java/AWT
% dialog that on some Mac multi-monitor/HiDPI setups renders oversized
% with tiny text pinned to one corner. This uses MATLAB's modern
% web-based uifigure stack instead, which scales correctly.
fig = uifigure('Visible', 'on', 'Position', dlg_pos, 'Name', 'MODsetup_pad_raw_filenames');
fig.UserData = struct('do_rename', false, 'pad_width', pad_width);

preview_label = uilabel(fig, 'Position', [20, 100, dlg_w - 40, 180], ...
    'Text', build_preview_text(old_base, prefix, idx, width, isnum, raw_file_suffix, pad_width), ...
    'WordWrap', 'on', 'VerticalAlignment', 'top');

if editable
    uilabel(fig, 'Position', [20, 65, 140, 22], 'Text', 'Digits to pad to:');
    spinner = uispinner(fig, 'Position', [165, 63, 70, 26], ...
        'Limits', [1, 10], 'RoundFractionalValues', 'on', 'Step', 1, 'Value', pad_width);
    spinner.ValueChangedFcn = @(src, ~) pad_width_dialog_spinner_changed( ...
        fig, preview_label, src, old_base, prefix, idx, width, isnum, raw_file_suffix);
else
    uilabel(fig, 'Position', [20, 65, dlg_w - 40, 22], ...
        'Text', sprintf('Padding to %d digits (set by the pad_width argument)', pad_width));
end

uibutton(fig, 'Position', [dlg_w - 190, 15, 80, 30], 'Text', 'Rename', ...
    'ButtonPushedFcn', @(~, ~) pad_width_dialog_button(fig, true));
uibutton(fig, 'Position', [dlg_w - 100, 15, 80, 30], 'Text', 'Cancel', ...
    'ButtonPushedFcn', @(~, ~) pad_width_dialog_button(fig, false));

uiwait(fig);
result = fig.UserData;
if isvalid(fig)
    delete(fig);
end
do_rename = result.do_rename;
pad_width = result.pad_width;
end

function pad_width_dialog_spinner_changed(fig, preview_label, spinner, old_base, prefix, idx, width, isnum, raw_file_suffix)
pad_width = round(spinner.Value);
fig.UserData.pad_width = pad_width;
preview_label.Text = build_preview_text(old_base, prefix, idx, width, isnum, raw_file_suffix, pad_width);
end

function pad_width_dialog_button(fig, do_rename)
fig.UserData.do_rename = do_rename;
uiresume(fig);
end
