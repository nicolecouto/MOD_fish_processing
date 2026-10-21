function efe = MODsetup_default_efe()
% MODsetup_default_efe        Part of MOD_fish_processing
%
% efe = MODsetup_default_efe()
%
% DESCRIPTION
%   The standard EFE (epsi AFE) board configuration - the single source of
%   truth for what L0 assumes when no setup.yml is given. EFE boards are
%   standard: the slot order, which slots are accelerometers, and each
%   slot's full-scale range and unipolar/bipolar ADC configuration don't
%   change between deployments. This is the one exception to "don't move
%   forward without metadata" - it's what lets MODprocess_single_modraw_to_L0.m
%   write volts/g with channel names, and MODvis_spectra_L0.m show spectra,
%   before anyone has written a setup.yml.
%
%   Slot | name       | type  | full_range | ADCconf
%   1-2  | t1, t2     | fpo7  | 2.5 V      | Unipolar
%   3-4  | s1, s2     | shear | 2.5 V      | Bipolar
%   5-7  | a1, a2, a3 | acc   | 1.8 V      | Unipolar
%
%   A slot can hold a different sensor (e.g. a microconductivity probe in
%   slot 4 as c1, or a fluorometer as f1) - the electrical config of the
%   slot stays the same, only the name/type change, and that comes from
%   setup.yml's instrument_manifest (see mod_efe_conversion.m).
%
% OUTPUTS
%   efe - metadata-shaped struct, so anything that takes a metadata struct
%         can take it directly:
%           PROCESS.channels        - {'t1','t2','s1','s2','a1','a2','a3'}, slot order
%           PROCESS.f_sample_epsi         - 320 [Hz], nominal EFE sample rate
%           AFE.(ch).type           - 'fpo7' / 'shear' / 'acc'
%           AFE.(ch).full_range     - [V]
%           AFE.(ch).ADCconf        - 'Unipolar' / 'Bipolar'
%           AFE.(ch).ADCfilter      - 'sinc4'
%           EFE.bit_counts          - 24, ADC resolution [bits]
%           EFE.gain                - 1, AFE gain before the ADC
%           EFE.acc_offset_V        - 0.9 [V], accelerometer zero-g output
%                                     (half of its 1.8 V range)
%           EFE.acc_factor_V_per_g  - 0.4 [V/g], accelerometer sensitivity
%                                     (400 mV/g, accelerometer datasheet)
%
% CALLED BY
%   mod_efe_conversion.m, MODvis_spectra_L0.m, MODvis_spectra.m
%
% CALLS
%   (none)
%
% NOTES
%   Values confirmed against every real setup.yml in data_for_reorg and
%   MOD_fish_lib/Acquisition/setup_mako4.yml. The acc offset/factor were
%   previously hard-coded in both MODprocess_single_L0_to_L1.m and
%   MODprocess_single_modraw_to_L0.m.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

efe.PROCESS.channels = {'t1', 't2', 's1', 's2', 'a1', 'a2', 'a3'};
efe.PROCESS.f_sample_epsi = 320;

for ch = {'t1', 't2'}
    efe.AFE.(ch{1}) = struct('type', 'fpo7', 'full_range', 2.5, 'ADCconf', 'Unipolar', 'ADCfilter', 'sinc4');
end
for ch = {'s1', 's2'}
    efe.AFE.(ch{1}) = struct('type', 'shear', 'full_range', 2.5, 'ADCconf', 'Bipolar', 'ADCfilter', 'sinc4');
end
for ch = {'a1', 'a2', 'a3'}
    efe.AFE.(ch{1}) = struct('type', 'acc', 'full_range', 1.8, 'ADCconf', 'Unipolar', 'ADCfilter', 'sinc4');
end

efe.EFE.bit_counts = 24;
efe.EFE.gain = 1;
efe.EFE.acc_offset_V = 0.9;
efe.EFE.acc_factor_V_per_g = 0.4;

end %end function
