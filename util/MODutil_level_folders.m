function [L1_dir, L2_dir] = MODutil_level_folders(folder)
% MODutil_level_folders        Part of MOD_fish_processing
%
% [L1_dir, L2_dir] = MODutil_level_folders(folder)
%
% DESCRIPTION
%   For the viewers: the L1 and L2 folders that go together, given a
%   processing run's folder (<survey>/processed/<run>/), one of its L2/ or
%   profiles_L2/ folders, or any other L2-style folder. An L2 file holds
%   scans only; its time series are in the L1 file with the same name, so
%   a viewer needs both folders.
%     - processed/<run>/       -> its L2/ and its L1 (below); with no L2/
%                                 but a profiles_L2/, that and profiles_L1/
%     - .../profiles_L2        -> the sibling profiles_L1/
%     - processed/<run>/L2     -> the run's L1
%     - any other .../L2       -> the sibling L1/
%   A run's L1 is its own L1/, or, when its yml (<survey>/meta/
%   meta_data_<run>.yml) has run.L1_from, processed/<L1_from>/L1/. A
%   folder that doesn't exist on disk is returned as '' (so a run with L1
%   but no L2 yet gives its L1 and L2_dir = '').
%
% INPUTS
%   folder - see above
%
% OUTPUTS
%   L1_dir - the matching L1 (or profiles_L1) folder, or ''
%   L2_dir - the L2 (or profiles_L2) folder, or ''
%
% CALLED BY
%   MODvis_spectra.m, MODvis_timeseries.m
%
% CALLS
%   ReadYaml (toolbox/YAMLMatlab_0.4.3)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

folder = char(folder);
if endsWith(folder, filesep)
    folder = folder(1:end-1);
end
[parent, name] = fileparts(folder);
if strcmp(fileparts_name(parent), 'processed') % a run's folder
    run_dir = folder;
    L2_dir = fullfile(run_dir, 'L2');
    L1_dir = run_L1(run_dir);
    if ~isfolder(L2_dir) && isfolder(fullfile(run_dir, 'profiles_L2'))
        L2_dir = fullfile(run_dir, 'profiles_L2');
        L1_dir = fullfile(run_dir, 'profiles_L1');
    end
elseif strcmp(name, 'profiles_L2')
    L2_dir = folder;
    L1_dir = fullfile(parent, 'profiles_L1');
else % an L2 folder: in a run, that run's L1; otherwise the sibling L1/
    L2_dir = folder;
    L1_dir = fullfile(parent, 'L1');
    if strcmp(fileparts_name(fileparts(parent)), 'processed')
        L1_dir = run_L1(parent);
    end
end
if ~isfolder(L1_dir)
    L1_dir = '';
end
if ~isfolder(L2_dir)
    L2_dir = '';
end
end %end function

%% A run's L1 folder: its own, or processed/<L1_from>/L1 when its yml
% (<survey>/meta/meta_data_<run>.yml) has run.L1_from
function L1_dir = run_L1(run_dir)
L1_dir = fullfile(run_dir, 'L1');
[processed, run] = fileparts(run_dir);
yml_file = fullfile(fileparts(processed), 'meta', ['meta_data_' run '.yml']);
if ~isfile(yml_file)
    return
end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3'));
try
    y = ReadYaml(yml_file);
    if isfield(y, 'run') && isfield(y.run, 'L1_from') && ~isempty(y.run.L1_from)
        L1_dir = fullfile(processed, char(string(y.run.L1_from)), 'L1');
    end
catch
    % unreadable yml - fall back to the run's own L1/
end
end

function n = fileparts_name(p)
[~, n] = fileparts(p);
end
