function epsi = mod_efe_volts_g_to_counts(epsi, conversion)
% mod_efe_volts_g_to_counts        Part of MOD_fish_processing
%
% epsi = mod_efe_volts_g_to_counts(epsi, conversion)
%
% DESCRIPTION
%   Exact inverse of mod_efe_counts_to_volts_g.m: recovers the raw EFE ADC
%   counts from <name>_volt / <name>_g fields, using the conversion record
%   stored with the data (L0_data.epsi_conversion). Counts are integers,
%   so rounding recovers them exactly - the float error of the forward
%   conversion is many orders of magnitude below one count.
%
% INPUTS
%   epsi       - struct with <name>_volt / <name>_g fields, plus any other
%                fields (time_s, dnum, ...), which pass through unchanged
%   conversion - record from mod_efe_conversion.m (as stored in
%                L0_data.epsi_conversion)
%
% OUTPUTS
%   epsi - same struct with each converted field replaced by
%          channel<slot> raw counts (double, integer-valued), the same
%          positional names L0 used before conversion
%
% CALLED BY
%   MODprocess_single_L0_to_L1.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

for slot = 1:numel(conversion.channels)
    c = conversion.channel.(conversion.channels{slot});
    if ~isfield(epsi, c.field)
        continue
    end
    epsi.(sprintf('channel%d', slot)) = round((epsi.(c.field) - c.offset) / c.scale);
    epsi = rmfield(epsi, c.field);
end

end %end function
