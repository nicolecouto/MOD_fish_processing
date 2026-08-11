function metadata = MODsetup_define_filters(metadata)
% MODsetup_define_filters        Part of MOD_fish_processing
%
% metadata = MODsetup_define_filters(metadata)
%
% DESCRIPTION
%   Resolves each AFE channel's fixed (deployment-constant) electronics/
%   ADC transfer function - magnitude-squared, same convention as
%   mod_scan_fpo7_transfer_function.m - and stores it as
%   metadata.AFE.(ch).electronics_filter.
%
%   Ports MOD_fish_lib's get_filters_SOM.m, minus the one term that isn't
%   actually deployment-constant: the FPO7 thermal rolloff (H.magsq/
%   H.FPO7 there) needs per-scan fall speed, so it stays a small pure
%   function on its own (mod_scan_fpo7_transfer_function.m, already
%   built). Everything else in get_filters_SOM.m - the per-channel ADC
%   sinc^4 response, shear's charge-amp electronics filter, gains -
%   depends only on f (itself just metadata.PROCESS.nfft/.Fs_epsi) and
%   metadata.AFE.(ch), so it's a genuine "resolve once, like volts_to_C"
%   value. See PLAN.md Section 6.2's "Design note: instrument filters"
%   for the full reasoning, and docs/workflow/L2_calc_chi.md for how
%   fpo7's electronics_filter actually gets consumed today.
%
%   Per channel type (metadata.AFE.(ch).type):
%     fpo7  - electronics_filter = H_adc^2 (matches get_filters_SOM.m's
%             H.electFPO7.^2, the term inside H.FPO7 = H.electFPO7.^2 .*
%             H.magsq(speed) - gain is 1, so squaring H_adc directly is
%             the whole thing)
%     shear - electronics_filter = (H_ca .* H_adc)^2, where H_ca is the
%             probe's charge-amp response (interpolated from a
%             network-analysis .mat, see NOTES) - matches H.shear
%     acc   - electronics_filter = H_adc^2 (gain 1, matches H.electAccel)
%
%   Deliberately NOT ported: the old "Tdiff" analog-differentiator term
%   (H.Tdiff in get_filters_SOM.m) - confirmed via MOD_fish_lib's actual
%   process configs (see mod_scan_fpo7_transfer_function.m's NOTES) that
%   no deployment this repo processes has ever used it. Adding it now,
%   with no real Tdiff deployment or filter file to validate against,
%   would be building for a hypothetical.
%
% INPUTS
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%              metadata.PROCESS.nfft/.Fs_epsi/.channels,
%              metadata.AFE.(ch).type/.ADCfilter,
%              metadata.paths.calibrations_root (shear only)
%
% OUTPUTS
%   metadata - same struct, with metadata.AFE.(ch).electronics_filter
%              (magnitude-squared, nfreq x 1, same f as
%              mod_scan_get_spectra.m produces for this deployment's
%              nfft/Fs_epsi) added for every channel with a resolvable
%              type/filter. A shear channel is left without the field
%              (warning, not error) if the charge-amp filter file isn't
%              found - same "missing calibration is not an error"
%              convention as metadata.AFE.(ch).cal/.volts_to_C.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m (once per deployment, right after
%   MODsetup_read_yaml.m - needs no L0/L1 data)
%
% CALLS
%   (none)
%
% NOTES
%   f is derived via a cheap dummy pwelch call (zeros(nfft,1), same nfft/
%   Fs_epsi/'psd' args mod_scan_get_spectra.m uses) rather than hand-
%   deriving the one-sided PSD frequency-bin formula - guarantees this
%   function's f is bit-identical to every real scan's f, rather than
%   risking a subtly different bin edge/count from reimplementing
%   pwelch's own frequency vector by hand.
%
%   The shear charge-amp filter file (a network-analysis measurement,
%   'cap1nFres200Meg_5KohmInput.mat', freq/coef_filt) is vendored from
%   MOD_fish_lib/EPSILOMETER/EPSILON/FILTER/ into
%   calibrations_root/SHEAR/ - not yet committed to MOD_fish_calibrations
%   (that repo already has an unrelated in-progress README.md edit and an
%   uncommitted FPO7/ dir from this same branch's earlier work - see
%   docs/workflow/L2_calc_chi.md's "Calibration file" section).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

nfft = metadata.PROCESS.nfft;
Fs_epsi = metadata.PROCESS.Fs_epsi;
[~, f] = pwelch(zeros(nfft, 1), nfft, [], nfft, Fs_epsi, 'psd');
f = f(:);

for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    if ~isfield(metadata.AFE, ch)
        continue
    end

    ADCfilter = 'sinc4';
    if isfield(metadata.AFE.(ch), 'ADCfilter')
        ADCfilter = metadata.AFE.(ch).ADCfilter;
    end
    H_adc = adc_filter(f, ADCfilter);
    if isempty(H_adc)
        warning('MODsetup_define_filters:unknownADCfilter', ...
            'Channel %s has unrecognized ADCfilter "%s" - electronics_filter not set.', ...
            ch, ADCfilter);
        continue
    end

    switch lower(metadata.AFE.(ch).type)
        case 'fpo7'
            metadata.AFE.(ch).electronics_filter = H_adc.^2;

        case 'shear'
            H_ca = shear_chargeamp_filter(f, metadata.paths.calibrations_root);
            if isempty(H_ca)
                warning('MODsetup_define_filters:noChargeAmpFile', ...
                    'Shear channel %s: charge-amp filter file not found - electronics_filter not set.', ch);
                continue
            end
            metadata.AFE.(ch).electronics_filter = (H_ca(:) .* H_adc(:)).^2;

        case {'acc', 'accel'}
            metadata.AFE.(ch).electronics_filter = H_adc.^2;

        otherwise
            % Not a channel type this repo's chi/shear/accel chains use
            % (e.g. an unrecognized manifest type) - nothing to resolve.
    end
end

end %end function

%% ADC anti-alias filter response, amplitude (not yet squared). Only
% 'sinc4' is implemented - the only ADCfilter type any real setup.yml or
% legacy metadata this repo has seen actually uses (get_filters_SOM.m's
% only case too). Returns [] for anything else, so the caller can warn
% and skip rather than silently produce a wrong filter.
function H = adc_filter(f, ADCfilter)
switch lower(ADCfilter)
    case 'sinc4'
        H = (sinc(f ./ (2 * f(end)))).^4;
    otherwise
        H = [];
end
end

%% Shear probe charge-amp electronics filter, from a network-analysis
% measurement (freq/coef_filt), interpolated onto f. Gain is 1 - matches
% get_filters_SOM.m's current gain_ca value (its own comments note this
% was previously tuned to a dB target and simplified to 1 as "a first
% approx"; ported as-is rather than re-deriving a different gain with no
% new calibration data to justify one). Returns [] if the file isn't
% found at calibrations_root/SHEAR/ (not vendored/committed for this
% deployment's calibrations_root yet - see NOTES above).
function H_ca = shear_chargeamp_filter(f, calibrations_root)
ca_file = fullfile(calibrations_root, 'SHEAR', 'cap1nFres200Meg_5KohmInput.mat');
if ~isfile(ca_file)
    H_ca = [];
    return
end
ca = load(ca_file, 'freq', 'coef_filt');
H_ca = interp1(ca.freq, ca.coef_filt, f);
end
