function MODutil_simulate_acquisition(source_raw_dir, incoming_dir, varargin)
% MODutil_simulate_acquisition        Part of MOD_fish_processing
%
% MODutil_simulate_acquisition(source_raw_dir, incoming_dir)
% MODutil_simulate_acquisition(..., 'n_files', 4, 'file_s', 60, 'chunks', 4, 'first', 1)
%
% DESCRIPTION
%   For testing realtime processing without a fish in the water: copies a
%   real deployment's raw files into incoming_dir (standing in for the
%   cruise-wide RAW_full_cruise/ folder the rsync fills) one at a time, and
%   writes each one in pieces over 'file_s' seconds, so the newest file
%   grows while processing runs - the way fctd_epsi writes it. Run it in a
%   second Matlab (or in the background) while the worker watches.
%
%   Use copies of real deployments only (e.g. from data_for_reorg); the
%   source folder is only read.
%
% INPUTS
%   source_raw_dir - folder of .modraw/.raw files to replay (read only)
%   incoming_dir   - where to write them (created if missing)
%   Name-value options:
%     'n_files' - how many files to replay, in name order (default: all)
%     'first'   - index of the first one (default 1)
%     'file_s'  - seconds over which each file is written (default 60)
%     'chunks'  - pieces each file is written in (default 4)
%
% OUTPUTS
%   (none - writes files into incoming_dir and prints a line per file)
%
% CALLED BY
%   (by hand, for testing; see docs/workflow/realtime_processing.md "Testing")
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

ip = inputParser;
addParameter(ip, 'n_files', Inf);
addParameter(ip, 'first', 1);
addParameter(ip, 'file_s', 60);
addParameter(ip, 'chunks', 4);
parse(ip, varargin{:});
o = ip.Results;

files = [dir(fullfile(source_raw_dir, '*.modraw')); dir(fullfile(source_raw_dir, '*.raw'))];
files = files(~startsWith({files.name}, '.'));
[~, order] = sort({files.name});
files = files(order);
last = min(numel(files), o.first + o.n_files - 1);
if ~isfolder(incoming_dir)
    mkdir(incoming_dir);
end

for i = o.first:last
    src = fullfile(files(i).folder, files(i).name);
    dst = fullfile(incoming_dir, files(i).name);
    fid = fopen(src, 'r');
    bytes = fread(fid, Inf, '*uint8');
    fclose(fid);
    edges = round(linspace(0, numel(bytes), o.chunks + 1));
    out = fopen(dst, 'w');
    for c = 1:o.chunks
        fwrite(out, bytes(edges(c) + 1 : edges(c + 1)));
        fflush_safe(out);
        if c < o.chunks
            pause(o.file_s / o.chunks);
        end
    end
    fclose(out);
    fprintf('%s | wrote %s (%d bytes)\n', char(datetime('now', 'Format', 'HH:mm:ss')), files(i).name, numel(bytes));
    if i < last
        pause(o.file_s / o.chunks);
    end
end
end %end function

%% Make the piece visible to other processes before the pause
function fflush_safe(fid)
% Matlab has no fflush; reopening in append mode would, but fseek to the
% current position flushes the buffer on every platform we use
fseek(fid, 0, 'cof');
end
