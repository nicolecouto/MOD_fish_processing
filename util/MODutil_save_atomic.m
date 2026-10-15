function MODutil_save_atomic(mat_file, S)
% MODutil_save_atomic        Part of MOD_fish_processing
%
% MODutil_save_atomic(mat_file, S)
%
% DESCRIPTION
%   save(mat_file, '-struct', 'S'), done so that mat_file is never left
%   half-written: the data goes to <mat_file>.tmp first (MAT format, an
%   extension a dir('*.mat') listing doesn't pick up) and is then moved
%   into place. If Matlab is killed during the save (Terminal closed, power
%   cut), the previous version of mat_file - or no file - is what's left,
%   not a truncated one that later passes would trip over.
%
% INPUTS
%   mat_file - full path, including .mat
%   S        - struct whose fields become the file's variables
%
% OUTPUTS
%   (none - writes mat_file)
%
% CALLED BY
%   MODprocess_all_modraw_to_L0.m, MODprocess_all_L0_to_L1.m,
%   MODprocess_all_L1_to_L2.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

tmp = [mat_file '.tmp'];
save(tmp, '-struct', 'S', '-mat');
movefile(tmp, mat_file, 'f');
end
