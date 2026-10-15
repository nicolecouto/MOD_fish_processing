function tf = MODutil_needs_redo(up_to_date, is_newest, output_file, newest_min_redo_s, reprocess_all)
% MODutil_needs_redo        Part of MOD_fish_processing
%
% tf = MODutil_needs_redo(up_to_date, is_newest, output_file, newest_min_redo_s, reprocess_all)
%
% DESCRIPTION
%   The one rule the per-file drivers (MODprocess_all_modraw_to_L0.m,
%   MODprocess_all_L0_to_L1.m, MODprocess_all_L1_to_L2.m) use to decide
%   whether to (re)process a file:
%     - reprocess_all: always.
%     - not the newest file: only if its output is out of date.
%     - the newest file (the one that may still be growing during
%       realtime acquisition):
%         newest_min_redo_s == 0 (the default): always - the drivers'
%           original behaviour, in case it was still being written.
%         newest_min_redo_s > 0 (the realtime worker passes its
%           regrow_min_s): only if its output is out of date, and no more
%           often than once per newest_min_redo_s seconds (judged by the
%           output file's age), so a growing file isn't redone - with
%           everything after it - on every pass.
%
% INPUTS
%   up_to_date        - true if the output exists and is current
%   is_newest         - true for the newest input file
%   output_file       - path of the output file (may not exist)
%   newest_min_redo_s - seconds; 0 = always redo the newest file
%   reprocess_all     - true to redo everything
%
% OUTPUTS
%   tf - true to (re)process the file
%
% CALLED BY
%   MODprocess_all_modraw_to_L0.m, MODprocess_all_L0_to_L1.m,
%   MODprocess_all_L1_to_L2.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if reprocess_all
    tf = true;
elseif ~is_newest
    tf = ~up_to_date;
elseif newest_min_redo_s <= 0
    tf = true;
elseif up_to_date
    tf = false;
else
    out = dir(output_file);
    if isempty(out)
        tf = true;
    else
        age_s = (now - out(1).datenum) * 86400;
        tf = age_s >= newest_min_redo_s;
    end
end
end
