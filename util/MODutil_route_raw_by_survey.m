function result = MODutil_route_raw_by_survey(raw_dir, processed_root)
% MODutil_route_raw_by_survey        Part of MOD_fish_processing
%
% result = MODutil_route_raw_by_survey(raw_dir, processed_root)
%
% DESCRIPTION
%   The rsync from DEV1 puts every survey's raw files in one cruise-wide
%   folder (Processed/RAW_full_cruise/). This links each one into its own
%   survey's raw/ folder, <processed_root>/<survey>/raw/<name>, so each
%   deployment is processed from its own raw/ like any other.
%
%   The survey is the CTD.survey line fctd_epsi copies from Setup into each
%   file's header (Start New Deployment sets it). Files are linked with
%   hard links: each raw/ file is a real file - the same file as in
%   raw_dir, so it takes no extra space - and any copy of a survey (Finder,
%   cp, rsync, the share drive, a hard drive) gets real files. When rsync
%   updates a growing file it writes a new file in its place, so a raw/
%   link that is no longer the same file as raw_dir's is linked again (the
%   next call, up to one worker pass behind). A symlink left from before
%   2026-10-16 is replaced the same way. Nothing is ever moved, renamed or
%   deleted in raw_dir; a file deleted there stays in raw/. raw_dir and
%   processed_root must be on the same disk (hard links can't cross disks).
%
%   Each file's header is read once; the answer is kept in
%   <processed_root>/raw_routing.mat. A file with no CTD.survey line yet is
%   looked at again when it grows (its header may not have been written
%   yet). Files that can't be routed are reported, with the reason, every
%   call.
%
% INPUTS
%   raw_dir        - the cruise-wide folder the rsync fills
%   processed_root - folder holding the survey folders
%
% OUTPUTS
%   result - struct:
%     .linked    - cellstr '<survey>/raw/<name>' linked by this call for
%                  the first time
%     .relinked  - cellstr '<survey>/raw/<name>' linked again by this call
%                  (rsync had replaced the file, or it was a symlink)
%     .surveys   - cellstr of every survey seen in raw_dir (sorted)
%     .unrouted  - struct array (.file, .reason) of files with no survey
%     .broken    - cellstr of symlinks (from before hard links) in survey
%                  raw/ folders whose file is gone
%
% CALLED BY
%   MODprocess_deployment.m (every pass, when given processed_root)
%
% CALLS
%   (none)
%
% NOTES
%   Only files ending in .modraw or .raw are routed; rsync's in-progress
%   temporary files (.<name>.<random>) don't match. Numbered raw names
%   (modsom_0, modsom_1, ...) that MODsetup_pad_raw_filenames.m would
%   rename aren't expected from fctd_epsi (its names carry a timestamp);
%   padding a linked name would make this link the unpadded name again.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

HEADER_BYTES = 2^16; % the Setup copy is in the first few kB of each file

result = struct('linked', {{}}, 'relinked', {{}}, 'surveys', {{}}, ...
    'unrouted', struct('file', {}, 'reason', {}), 'broken', {{}});
routing_file = fullfile(processed_root, 'raw_routing.mat');
routing = struct('name', {}, 'survey', {}, 'bytes', {});
if isfile(routing_file)
    saved = load(routing_file, 'routing');
    routing = saved.routing;
end
changed = false;

files = [dir(fullfile(raw_dir, '*.modraw')); dir(fullfile(raw_dir, '*.raw'))];
files = files(~startsWith({files.name}, '.'));
for i = 1:numel(files)
    name = files(i).name;
    k = find(strcmp({routing.name}, name), 1);
    if isempty(k) || (isempty(routing(k).survey) && files(i).bytes > routing(k).bytes)
        survey = header_survey(fullfile(raw_dir, name), HEADER_BYTES);
        entry = struct('name', name, 'survey', survey, 'bytes', files(i).bytes);
        if isempty(k)
            routing(end+1) = entry; %#ok<AGROW>
        else
            routing(k) = entry;
        end
        changed = true;
        k = find(strcmp({routing.name}, name), 1);
    end
    survey = routing(k).survey;
    if isempty(survey)
        result.unrouted(end+1) = struct('file', fullfile(raw_dir, name), ...
            'reason', 'no CTD.survey line in its header');
        continue
    end
    if ~is_safe_folder_name(survey)
        result.unrouted(end+1) = struct('file', fullfile(raw_dir, name), ...
            'reason', sprintf('survey name "%s" isn''t a usable folder name', survey));
        continue
    end
    link_dir = fullfile(processed_root, survey, 'raw');
    link = fullfile(link_dir, name);
    source = fullfile(files(i).folder, name);
    try
        if ~is_link_or_file(link)
            if ~isfolder(link_dir)
                mkdir(link_dir);
            end
            hard_link(link, source);
            result.linked{end+1} = fullfile(survey, 'raw', name);
        elseif is_link(link) || ~same_file(link, source)
            % link a temporary name, then rename it over the old one, so
            % raw/<name> is never missing
            tmp = fullfile(link_dir, ['.' name '.relink']);
            if is_link_or_file(tmp)
                delete(tmp);
            end
            hard_link(tmp, source);
            replace_with(tmp, link);
            result.relinked{end+1} = fullfile(survey, 'raw', name);
        end
    catch ME
        % e.g. no permission, a different disk, or something else already
        % at that path - this file waits, the others still get linked
        reason = sprintf('could not link it into %s (%s)', link_dir, ME.message);
        if contains(ME.message, 'cross-device', 'IgnoreCase', true)
            reason = sprintf(['%s and %s are on different disks - hard links can''t cross disks, ' ...
                'so put the processed folder on the same disk as the raw folder'], raw_dir, processed_root);
        end
        result.unrouted(end+1) = struct('file', source, 'reason', reason);
    end
end

if changed
    tmp = [tempname(processed_root) '.mat'];
    save(tmp, 'routing');
    movefile(tmp, routing_file, 'f');
end
result.surveys = reshape(unique({routing(~cellfun(@isempty, {routing.survey})).survey}), 1, []);

% Symlinks (from before hard links) whose file has gone
for iS = 1:numel(result.surveys)
    listing = dir(fullfile(processed_root, result.surveys{iS}, 'raw'));
    for iD = 1:numel(listing)
        d = listing(iD);
        p = fullfile(d.folder, d.name);
        if ~d.isdir && is_link(p) && ~isfile(p)
            result.broken{end+1} = p;
        end
    end
end
end %end function

%% The CTD.survey value in a raw file's header ('' if none)
function survey = header_survey(file, n_bytes)
survey = '';
fid = fopen(file, 'r');
if fid < 0
    return
end
head = fread(fid, n_bytes, '*char')';
fclose(fid);
% the value must be complete (closing quote) - a header cut off mid-line
% would otherwise be cached as a truncated survey name
tok = regexp(head, 'CTD\.survey\s*=\s*''([^''\r\n]*)''', 'tokens', 'once');
if ~isempty(tok)
    survey = strtrim(tok{1});
end
end

function tf = is_safe_folder_name(s)
tf = ~isempty(regexp(s, '^[A-Za-z0-9_.\-+]+$', 'once')) && ~any(strcmp(s, {'.', '..'}));
end

function tf = is_link(p)
tf = java.nio.file.Files.isSymbolicLink(java.io.File(p).toPath());
end

function tf = is_link_or_file(p)
tf = isfile(p) || is_link(p);
end

function hard_link(link, source)
java.nio.file.Files.createLink(java.io.File(link).toPath(), java.io.File(source).toPath());
end

function tf = same_file(a, b)
tf = java.nio.file.Files.isSameFile(java.io.File(a).toPath(), java.io.File(b).toPath());
end

function replace_with(tmp, target)
options = javaArray('java.nio.file.CopyOption', 2);
options(1) = javaMethod('valueOf', 'java.nio.file.StandardCopyOption', 'REPLACE_EXISTING');
options(2) = javaMethod('valueOf', 'java.nio.file.StandardCopyOption', 'ATOMIC_MOVE');
java.nio.file.Files.move(java.io.File(tmp).toPath(), java.io.File(target).toPath(), options);
end
