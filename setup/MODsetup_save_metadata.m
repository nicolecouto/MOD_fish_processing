function metadata = MODsetup_save_metadata(metadata, meta_dir, event_name, filepath)
% MODsetup_save_metadata        Part of MOD_fish_processing
%
% metadata = MODsetup_save_metadata(metadata, meta_dir, event_name, filepath)
%
% DESCRIPTION
%   Central save wrapper for meta/metadata.mat. Every caller that builds
%   or modifies a metadata struct goes through this function instead of
%   calling save() directly, so the archive-vs-update decision and the
%   history log are handled in one place. Compares the metadata to be
%   saved against what is already on disk (ignoring metadata.header
%   itself) and picks one of three outcomes:
%
%     no-op   - content identical to what's on disk. Nothing is written;
%               the on-disk struct (with its existing history) is
%               returned unchanged. This is the common case when a
%               deployment script re-reads the same setup.yml many times
%               an hour during a cruise.
%     create  - content differs AND metadata.header.yaml_hash differs
%               from what's on disk (the yaml itself changed - routine
%               edit or a deliberate parameter experiment). The existing
%               meta/metadata.mat is archived to
%               meta/archive/metadata_<timestamp>.mat, then the new
%               struct is written.
%     update  - content differs but metadata.header.yaml_hash matches
%               what's on disk (a derived value was filled in or
%               changed, e.g. a probe serial number resolving to a
%               calibration file - the yaml itself said nothing new).
%               Written to meta/metadata.mat in place, no archiving.
%
%   In both the create and update cases, one entry is appended to
%   metadata.header.history, a struct array with fields .timestamp,
%   .computer, .event, .filepath - so metadata.header.history(1).timestamp
%   works directly, no cell indexing. Reading any single metadata.mat
%   therefore tells you its full lineage with no separate log file
%   needed. See PLAN.md Section 2, "Metadata provenance and archiving."
%
% INPUTS
%   metadata   - the metadata struct to save. Callers building a fresh
%                metadata from yaml must set metadata.header.yaml_hash
%                (a hash of the setup.yml file) before calling. Callers
%                merging a derived value into an existing metadata
%                should load the current metadata.mat, add the new
%                field(s) onto it, and pass the result - this function
%                does not merge fields itself.
%   meta_dir   - deployment's meta/ folder (where metadata.mat and
%                archive/ live)
%   event_name - char, e.g. 'created_from_yaml'
%   filepath   - char, path to the file responsible for this save (the
%                setup.yml that was read). Recorded in the history entry.
%
% OUTPUTS
%   metadata - the struct now on disk, with header.history updated. On a
%              no-op this is the struct that was already on disk (not the
%              caller's copy), so the caller's in-memory metadata stays
%              consistent with what a later read of metadata.mat returns.
%
% CALLED BY
%   MODsetup_read_yaml.m
%
% CALLS
%   (none)
%
% NOTES
%   The very first save for a deployment (no metadata.mat on disk yet) is
%   always treated as create, with nothing to archive.
%
%   An on-disk metadata.mat saved before this function existed has no
%   header.yaml_hash. That is treated as a hash mismatch (safe default:
%   archives the old file under create rather than guessing it's
%   equivalent).
%
%   filepath is the only per-event detail recorded today because
%   created_from_yaml is the only caller. A future caller logging a
%   different kind of event (e.g. a calibration merge, with a probe
%   serial number and cal file instead of a single path) will need this
%   signature revisited then, rather than generalizing now for a case
%   nothing uses yet.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

mat_path = fullfile(meta_dir, 'metadata.mat');

new_entry = struct( ...
    'timestamp', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'computer',  get_computer_name(), ...
    'event',     event_name, ...
    'filepath',  filepath);

if ~isfile(mat_path)
    metadata.header.history = new_entry;
    save(mat_path, '-struct', 'metadata');
    return
end

on_disk = load(mat_path);
has_old_header = isfield(on_disk, 'header');

new_content = metadata;
if isfield(new_content, 'header'); new_content = rmfield(new_content, 'header'); end
old_content = on_disk;
if has_old_header; old_content = rmfield(old_content, 'header'); end

% A pre-existing metadata.mat with no header at all did not go through
% this function - never treat it as equivalent, even if its content
% happens to match (see NOTES: falls through to 'create' below).
if has_old_header && isequaln(new_content, old_content)
    metadata = on_disk;
    return
end

old_hash = '';
if has_old_header && isfield(on_disk.header, 'yaml_hash')
    old_hash = on_disk.header.yaml_hash;
end
new_hash = '';
if isfield(metadata, 'header') && isfield(metadata.header, 'yaml_hash')
    new_hash = metadata.header.yaml_hash;
end

old_history = struct('timestamp', {}, 'computer', {}, 'event', {}, 'filepath', {});
if has_old_header && isfield(on_disk.header, 'history')
    old_history = on_disk.header.history;
end

if ~strcmp(old_hash, new_hash)
    archive_dir = fullfile(meta_dir, 'archive');
    if ~isfolder(archive_dir); mkdir(archive_dir); end
    timestamp_str = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd''_''HHmmss'));
    copyfile(mat_path, fullfile(archive_dir, sprintf('metadata_%s.mat', timestamp_str)));
end

metadata.header.history = [old_history(:); new_entry];
save(mat_path, '-struct', 'metadata');

end %end function

%% Cross-platform hostname lookup
function name = get_computer_name()
name = getenv('COMPUTERNAME');
if isempty(name)
    name = getenv('HOSTNAME');
end
if isempty(name)
    name = char(java.net.InetAddress.getLocalHost().getHostName());
end
end
