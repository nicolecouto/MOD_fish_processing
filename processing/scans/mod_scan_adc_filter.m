function H = mod_scan_adc_filter(f, ADCfilter)
% mod_scan_adc_filter        Part of MOD_fish_processing
%
% H = mod_scan_adc_filter(f, ADCfilter)
%
% DESCRIPTION
%   AFE ADC anti-alias filter response, amplitude (not yet squared) -
%   channel-type-agnostic, used identically for fpo7/shear/acc channels
%   (see MODsetup_define_filters.m, which squares/combines this with
%   other per-channel-type terms to build metadata.AFE.(ch).electronics_filter).
%
%   Only 'sinc4' is implemented - the only ADCfilter type any real
%   setup.yml or legacy metadata this repo has seen actually uses (matches
%   the old MOD_fish_lib get_filters_SOM.m's only case too).
%
%   Pulled out of MODsetup_define_filters.m (where it was a private
%   subfunction, only reachable from inside that one file) so it can also
%   be called directly for a legacy Profile file with no setup.yml at all
%   - e.g. MODvis_spectra.m's modeled-noise-floor checkbox, which needs
%   this same electronics_filter but has no metadata.AFE.(ch) to resolve
%   it from ahead of time.
%
% INPUTS
%   f         - frequency vector [Hz], any shape.
%   ADCfilter - filter type string, e.g. 'sinc4'.
%
% OUTPUTS
%   H - filter amplitude response (not squared), same size as f. Empty
%       ([]) if ADCfilter isn't a recognized type, so the caller can warn
%       and skip rather than silently produce a wrong filter.
%
% CALLED BY
%   MODsetup_define_filters.m, MODvis_spectra.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

switch lower(ADCfilter)
    case 'sinc4'
        H = (sinc(f ./ (2 * f(end)))).^4;
    otherwise
        H = [];
end

end %end function
