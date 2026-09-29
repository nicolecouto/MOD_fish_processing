function [epsi, conversion] = mod_efe_counts_to_volts_g(epsi, metadata)
% mod_efe_counts_to_volts_g        Part of MOD_fish_processing
%
% [epsi, conversion] = mod_efe_counts_to_volts_g(epsi, metadata)
%
% DESCRIPTION
%   Converts EFE ADC counts to volts (every non-accelerometer channel) or
%   g (accelerometer channels), and renames L0's positional channel1..N
%   fields to channel names (t1_volt, s1_volt, a1_g, ...). Only volts/g -
%   no temperature, no shear: those need FP07/shear-probe calibrations
%   applied later (MODprocess_L1_apply_fpo7_calibration.m, shear Sv).
%
%   Names and ADC config come from mod_efe_conversion.m: the standard EFE
%   board (MODsetup_default_efe.m), overridden by metadata where given.
%
% INPUTS
%   epsi     - struct with channel1..channelN raw ADC counts (any numeric
%              class), plus any other fields (time_s, dnum, ...), which
%              pass through unchanged
%   metadata - (optional) metadata struct from MODsetup_read_yaml.m, or
%              [] / omitted to use the standard EFE defaults
%
% OUTPUTS
%   epsi       - same struct with channelN replaced by <name>_volt [V] or
%                <name>_g [g], as double
%   conversion - the record from mod_efe_conversion.m that was applied -
%                store it with the data (L0_data.epsi_conversion) so the
%                counts can be recovered (mod_efe_volts_g_to_counts.m)
%
% CALLED BY
%   MODprocess_single_modraw_to_L0.m, MODprocess_single_L0_to_L1.m
%
% CALLS
%   mod_efe_conversion.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2
    metadata = [];
end

n_slots = 0;
while isfield(epsi, sprintf('channel%d', n_slots + 1))
    n_slots = n_slots + 1;
end

conversion = mod_efe_conversion(n_slots, metadata);

for slot = 1:n_slots
    slot_field = sprintf('channel%d', slot);
    c = conversion.channel.(conversion.channels{slot});
    epsi.(c.field) = double(epsi.(slot_field)) * c.scale + c.offset;
    epsi = rmfield(epsi, slot_field);
end

end %end function
