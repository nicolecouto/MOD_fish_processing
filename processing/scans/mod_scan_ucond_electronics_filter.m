function H2 = mod_scan_ucond_electronics_filter(f, ucond, f_sample_epsi, ADCfilter)
% mod_scan_ucond_electronics_filter        Part of MOD_fish_processing
%
% H2 = mod_scan_ucond_electronics_filter(f, ucond, f_sample_epsi, ADCfilter)
%
% DESCRIPTION
%   Magnitude-squared response of a microconductivity channel's
%   electronics: measured power = true power * H2. Dividing a c1_volt
%   power spectrum by H2 removes all three terms:
%     1. the SBE pre-emphasis circuit, which boosts high frequencies so
%        the small fluctuations rise above the ADC noise. Its response is
%          H_pre = 1 + Rf*R22/(R22^2 + w1^2) + i*Rf*w1/(R22^2 + w1^2),
%          Rf = R24 + R25, w1 = 1/(2*pi*f*C19)
%        (H_pre -> 1 at low f and -> 1 + Rf/R22 at high f), following
%        Steve Anderson and Alford/Pinkel 2000. Legacy removed it from the
%        time series by multiplying the FFT by 1/H_pre; here it's divided
%        out of the spectrum instead, which is the same for chi.
%     2. the anti-alias correction legacy chi used, sinc(f/f_Nyquist)^p
%        on the power spectrum (p = ucond.antialias_sinc_power; 0 = none).
%     3. the EFE ADC filter (mod_scan_adc_filter.m), squared, as for
%        every EFE channel.
%
% INPUTS
%   f         - frequency vector [Hz], any shape
%   ucond     - metadata.PROCESS.UCOND: preemphasis_R22_ohm,
%               preemphasis_R24_ohm, preemphasis_R25_ohm, preemphasis_C19_F,
%               antialias_sinc_power
%   f_sample_epsi   - EFE sample rate [Hz] (f_Nyquist = f_sample_epsi/2)
%   ADCfilter - the channel's ADC filter type, e.g. 'sinc4'
%
% OUTPUTS
%   H2 - nfreq x 1, the response to divide a power spectrum by. Empty if
%        ADCfilter isn't a recognized type (mod_scan_adc_filter.m).
%
% CALLED BY
%   MODsetup_define_filters.m, MODprocess_L1_apply_ucond_calibration.m
%
% CALLS
%   mod_scan_adc_filter.m
%
% PROVENANCE
%   MOD_fish_lib FastCTD_MATLAB/Dehysteresis_and_microconductivity/
%   microconductivity/other_necessary_scripts/remove_sbe_preemphasisMHA.m
%   (the circuit) and DoOneChi_MHA_v3.m (the sinc^2 correction).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

f = f(:);
H_adc = mod_scan_adc_filter(f, ADCfilter);
if isempty(H_adc)
    H2 = [];
    return
end

R22 = ucond.preemphasis_R22_ohm;
Rf = ucond.preemphasis_R24_ohm + ucond.preemphasis_R25_ohm;
w1 = 1 ./ (2*pi*f*ucond.preemphasis_C19_F);
H_pre = 1 + Rf*R22 ./ (R22^2 + w1.^2) + 1i*Rf*w1 ./ (R22^2 + w1.^2);
H_pre(f == 0) = 1; % w1 is infinite at f = 0, where the circuit passes the signal unchanged

H_antialias = sinc(f / (f_sample_epsi/2)).^ucond.antialias_sinc_power;

H2 = abs(H_pre).^2 .* H_antialias .* H_adc.^2;

end %end function
