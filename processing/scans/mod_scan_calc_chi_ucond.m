function scan = mod_scan_calc_chi_ucond(scan, metadata, channel)
% mod_scan_calc_chi_ucond        Part of MOD_fish_processing
%
% scan = mod_scan_calc_chi_ucond(scan, metadata, channel)
%
% DESCRIPTION
%   chi from a microconductivity channel for one scan, by integrating the
%   conductivity-gradient wavenumber spectrum (MHA's v3 method):
%     1. P_C(f) = c1_volt_f * gain^2 / electronics_filter: the gain
%        (metadata.AFE.(ch).volts_to_S_per_m,
%        MODprocess_L1_apply_ucond_calibration.m) and the electronics
%        response (pre-emphasis, anti-alias, ADC;
%        mod_scan_ucond_electronics_filter.m)
%     2. k = f/abs(w), Phi_dCdz(k) = (2*pi*k)^2 * P_C(f) * abs(w), as for
%        FP07 (mod_scan_fpo7_volts_to_Tg_spectrum.m)
%     3. dT/dC = 1/(dC/dT), with dC/dT from GSW (gsw_C_from_SP) at the
%        scan's SP, T and P. Legacy used the SBE approximation
%        dC/dT = 0.1*(1 + 0.006*(T - 20)) S/m per degC.
%     4. chi_ucond = 6 * ktemp * (dT/dC)^2 * dk * sum(Phi_dCdz) from
%        ucond.kmin_cpm to kmax = min(ucond.kmax_cpm, ucond.fmax_hz/abs(w))
%
%   kmax is far below the Batchelor wavenumber, so chi_ucond is an
%   underestimate, by a factor that grows with epsilon. Legacy's
%   correction for it (chi_tot, eps_chi; Alford and Pinkel 2000b) needs
%   N^2 and Rrho and isn't ported yet.
%
% INPUTS
%   scan     - struct with:
%                spectra.f         - [Hz]
%                spectra.Pc_volt_f - the channel's c1_volt power spectrum
%                                    [V^2/Hz], same shape as f
%                w                 - fall speed at the scan center [m/s]
%                ktemp             - thermal diffusivity [m^2/s]
%                SP, T, P          - scan-center practical salinity,
%                                    temperature [degC], pressure [dbar]
%                volts             - the scan's c1_volt samples, to tell
%                                    a railed signal
%   metadata - uses metadata.AFE.(channel).volts_to_S_per_m,
%              .electronics_filter and .full_range,
%              metadata.PROCESS.UCOND.kmin_cpm/.kmax_cpm/.fmax_hz/
%              .rail_fraction
%   channel  - e.g. 'c1'
%
% OUTPUTS
%   scan - with added:
%     chi_ucond      - [degC^2/s]; NaN when the signal is railed (a sample
%                      at ucond.rail_fraction of full_range or beyond),
%                      kmax <= kmin or a needed value is NaN
%     chi_ucond_kmax - the kmax used [cpm]
%     dTdC           - [degC per S/m]
%     spectra.k, spectra.Pc_dCdz_k - wavenumber [cpm] and conductivity-
%                      gradient spectrum [(S/m)^2/m^2 per cpm]
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   MODsetup_validate_metadata.m, gsw_C_from_SP.m
%
% PROVENANCE
%   MOD_fish_lib FastCTD_MATLAB/Dehysteresis_and_microconductivity/
%   microconductivity/DoOneChi_MHA_v3.m (MHA, Feb 2025). Legacy's
%   constants are yml values here (ucond block) or come from the scan:
%   D = 1.4e-7 is the scan's ktemp, and its own 2 s windows and 0.5 s FFTs
%   are this deployment's scans. Legacy took the spectrum of the first
%   difference; this uses (2*pi*k)^2, the exact derivative, like FP07 chi.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'ucond_kmin_cpm', 'ucond_kmax_cpm', 'ucond_fmax_hz', 'ucond_rail_fraction'});
U = metadata.PROCESS.UCOND;
afe = metadata.AFE.(channel);

f = scan.spectra.f(:)';
w = abs(scan.w);
P_C = scan.spectra.Pc_volt_f(:)' * afe.volts_to_S_per_m^2 ./ afe.electronics_filter(:)';

k = f / w;
scan.spectra.k = k;
scan.spectra.Pc_dCdz_k = (2*pi*k).^2 .* P_C * w;

% dC/dT [S/m per degC] by a centered difference in T; gsw_C_from_SP is in mS/cm
dT = 1e-3; % degC - a finite-difference step, small next to any T change across a scan
dCdT = (gsw_C_from_SP(scan.SP, scan.T + dT, scan.P) - gsw_C_from_SP(scan.SP, scan.T - dT, scan.P)) / (2*dT) / 10;
scan.dTdC = 1 / dCdT;

scan.chi_ucond_kmax = min(U.kmax_cpm, U.fmax_hz / w);
krange = k >= U.kmin_cpm & k <= scan.chi_ucond_kmax;
railed = any(abs(scan.volts) >= U.rail_fraction * afe.full_range);
if railed || scan.chi_ucond_kmax <= U.kmin_cpm || ~any(krange) || ~isfinite(scan.dTdC)
    scan.chi_ucond = NaN;
    return
end
dk = mean(diff(k), 'omitnan');
scan.chi_ucond = 6 * scan.ktemp * scan.dTdC^2 * dk * sum(scan.spectra.Pc_dCdz_k(krange), 'omitnan');

end %end function
