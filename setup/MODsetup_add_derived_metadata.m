function metadata = MODsetup_add_derived_metadata(metadata)
% MODsetup_add_derived_metadata        Part of MOD_fish_processing
%
% metadata = MODsetup_add_derived_metadata(metadata)
%
% DESCRIPTION
%   Adds the metadata values that aren't in the yml but are derived from
%   it or from the data, so every processing step sees them no matter
%   which session or retry built its metadata:
%     - metadata.AFE.(ch).electronics_filter - the AFE electronics/ADC
%       transfer functions, recomputed (MODsetup_define_filters.m; cheap,
%       needs only the yml).
%     - metadata.AFE.(ch).volts_to_C - the FP07 in-situ fit, loaded from
%       fpo7_calibration.mat in metadata.paths.L1_meta (the meta/ next to
%       the L1 the fit was made on) if it exists. That file is written by
%       MODprocess_all_L0_to_L1.m each time it fits
%       (MODprocess_L1_apply_fpo7_calibration.m). Only channels that are
%       still fpo7 with the same probe SN in this yml are filled, so a
%       fit is never applied to a different probe (a warning says when an
%       SN doesn't match).
%
%   Why: MODsetup_read_yaml.m builds metadata from the yml alone, so
%   metadata read in a new session, or reread after a prompted value was
%   saved (MODsetup_validate_metadata.m's yamlUpdated retry), would
%   otherwise lack both, and FP07 chi would be skipped without an error.
%
%   If MODsetup_define_filters.m prompts for a value and it's saved to
%   the yml, metadata is reread from the yml here and this runs again, so
%   the caller never has to handle that case. Callers that catch
%   yamlUpdated from a later step reload with
%   MODsetup_add_derived_metadata(MODsetup_read_yaml(metadata.paths.setup_yml)).
%
% INPUTS
%   metadata - from MODsetup_read_yaml.m (needs .paths.L1_meta, .AFE,
%              .PROCESS.channels)
%
% OUTPUTS
%   metadata - same, with the fields above added
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m, MODprocess_all_L1_to_L2.m
%
% CALLS
%   MODsetup_define_filters.m, MODsetup_read_yaml.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

while true
    try
        metadata = MODsetup_define_filters(metadata);
        break
    catch ME
        if ~strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
            rethrow(ME)
        end
        metadata = MODsetup_read_yaml(metadata.paths.setup_yml);
    end
end

cal_file = fullfile(metadata.paths.L1_meta, 'fpo7_calibration.mat');
if ~isfile(cal_file)
    return
end
saved = load(cal_file);
for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    if ~isfield(saved.volts_to_C, ch) || ~isfield(metadata.AFE, ch) ...
            || ~strcmpi(metadata.AFE.(ch).type, 'fpo7')
        continue
    end
    sn = probe_sn(metadata.AFE.(ch));
    if strcmp(sn, saved.sn.(ch))
        metadata.AFE.(ch).volts_to_C = saved.volts_to_C.(ch);
    else
        % Say so, rather than let FP07 chi drop out without a word
        warning('MODsetup_add_derived_metadata:fpo7SNChanged', ...
            ['%s: the FP07 fit in %s is for probe SN "%s", but the yml says SN "%s" - not ' ...
             'used, so no chi for %s until MODprocess_all_L0_to_L1 refits it.'], ...
            ch, cal_file, saved.sn.(ch), sn, ch);
    end
end
end %end function

%% A channel's probe SN as char ('' if none) - the key fpo7_calibration.mat is saved with
function sn = probe_sn(afe_channel)
sn = '';
if isfield(afe_channel, 'SN')
    sn = char(string(afe_channel.SN));
end
end
