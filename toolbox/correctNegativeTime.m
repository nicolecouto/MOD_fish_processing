function corrected_time = correctNegativeTime(time)
% correctNegativeTime        Part of MOD_fish_processing
%
% corrected_time = correctNegativeTime(time)
%
% DESCRIPTION
%   Corrects timestamps that wrapped around into negative values (the
%   underlying counter overflowed as if reinterpreted as signed). Any
%   value <= 0 is shifted back into range by adding 2^64.
%
% INPUTS
%   time      - numeric array of raw timestamp values, some possibly
%               negative due to overflow
%
% OUTPUTS
%   corrected_time - same array with values <= 0 replaced by (value + 2^64)
%
% CALLED BY
%   MODprocess_single_modraw_to_L0.m
%
% CALLS
%   (none)
%
% NOTES
%   Ported from the local subfunction of the same name in MOD_fish_lib's
%   FastCTD_MATLAB/FastCTD_ReadASCII.m (and identical copies in its
%   _VNAV/_with_cal/_YEI variants), where it was only in scope for code
%   running inside that same file. Extracted here as a standalone function
%   so callers elsewhere (e.g. MODprocess_single_modraw_to_L0.m) can use it
%   directly.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

corrected_time = time;
neg_time = time(time < 0);
corrected_time(time <= 0) = 2^64 + neg_time;

end
