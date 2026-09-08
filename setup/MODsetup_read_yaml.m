function metadata = MODsetup_read_yaml(setup_yml)
% MODsetup_read_yaml        Part of MOD_fish_processing
%
% metadata = MODsetup_read_yaml(setup_yml)
%
% DESCRIPTION
%   Reads a deployment's setup.yml and returns a metadata struct with
%   paths derived fresh from setup.yml's data_root (never saved), the AFE
%   channel manifest, CTD calibration coefficients, and altimeter
%   geometry. Resolves what the L0->L1 step actually uses for computation
%   (metadata.PROCESS.*, metadata.AFE.*, metadata.CTD.cal,
%   metadata.GEOMETRY.*) plus a few identifying CTD fields
%   (metadata.CTD.name/.SN/.sample_per_record) kept for the deployment
%   record even though L0->L1 doesn't read them - grows as later pipeline
%   steps need more (see PLAN.md Section 2).
%
%   setup.yml's instrument_manifest block is the single place that says
%   what's physically on the vehicle (which AFE channel holds which probe
%   type/SN, plus presence flags for vnav/isap/alt/gps/fluor) - see
%   PLAN.md Section 5. Electrical/sampling specifics (full_range,
%   ADCconf, sample_per_record, ...) live in separate detail sections
%   (afe.channels, ctd, altimeter), keyed by the same names the manifest
%   declares. An instrument entirely absent from instrument_manifest is
%   treated as not on the deployment - nothing errors on a missing key.
%
%   Saves metadata.mat into meta/ alongside setup.yml, with metadata.paths
%   stripped out first - metadata.mat is a portable deployment record;
%   paths are machine-specific and always re-derived from setup.yml's
%   data_root on the next call. The save goes through
%   MODsetup_save_metadata.m, which no-ops if nothing has changed since
%   the last call (the common case - a deployment script re-reads the
%   same setup.yml many times an hour during a cruise), and otherwise
%   archives the previous metadata.mat before writing the new one. See
%   PLAN.md Section 2, "Metadata provenance and archiving."
%
% INPUTS
%   setup_yml - full path to a deployment's setup.yml
%
% OUTPUTS
%   metadata  - struct with fields:
%     paths.data_root, .raw, .L0, .L1, .L2, .profiles, .profiles_raw, .meta,
%     .calibrations_root, .ctd, .setup_yml
%                                   - .ctd is only meaningful for vehicles
%                                     with an independent CTD file (see
%                                     vehicle_name below) - defined
%                                     unconditionally like the other paths,
%                                     whether or not data_root/ctd/ exists.
%                                     .profiles is where
%                                     MODprocess_all_L1_to_L2_profiles.m
%                                     saves the converted (spectra/chi/
%                                     epsilon) Profile####.mat, deliberately
%                                     a sibling of .L2 (not inside it) so
%                                     the per-file realtime output and the
%                                     per-cast final output never share a
%                                     directory. .profiles_raw is where
%                                     MODprocess_all_extract_profiles.m
%                                     saves the stitched-but-not-yet-
%                                     converted raw epsi/ctd record for each
%                                     profile - a separate directory from
%                                     .profiles so the two pipeline stages
%                                     (extraction, conversion) never
%                                     collide on the same Profile####.mat
%                                     filename (PLAN.md Phase A refactor).
%                                     .setup_yml is this call's
%                                     own input argument, carried along so
%                                     MODsetup_validate_metadata.m (called
%                                     from deep inside mod_scan_*.m) can
%                                     find its way back to the yaml file
%                                     without every function needing its
%                                     own yaml_file argument.
%     header.yaml_hash             - hash of setup_yml's contents
%     header.history               - struct array (.timestamp, .computer,
%                                     .event, .filepath) appended to by
%                                     MODsetup_save_metadata
%     fish_flag                    - 'FCTD' or 'EPSI', from setup.yml
%     vehicle_name                 - e.g. 'DeepSolo', 'Wirewalker', from
%                                     setup.yml. '' if not declared
%                                     (older setup.yml files predate this
%                                     field). DeepSolo/Wirewalker get
%                                     their CTD data from an independent
%                                     file (paths.ctd) rather than
%                                     $SB49/$SB41 blocks in the raw stream
%                                     - see MODprocess_read_external_ctd.m
%     manifest.has_vnav/.has_isap/.has_alt/.has_gps/.has_fluor
%                                   - presence flags from setup.yml's
%                                     instrument_manifest block. false when
%                                     the key is missing entirely, same as
%                                     when it's explicitly false. Not
%                                     consumed by L0->L1 today (vnav etc.
%                                     just pass through unchanged) - a
%                                     record of what's on the vehicle for
%                                     later steps.
%     manifest.has_epsi             - true only when setup.yml's
%                                     instrument_manifest.afe block is
%                                     present and declares at least one
%                                     channel. A CTD-only vehicle (no AFE
%                                     board at all - e.g. a bare FastCTD or
%                                     Wirewalker cast) has no afe: block,
%                                     so this comes back false rather than
%                                     erroring - see PROCESS.channels/AFE.*
%                                     below. Consumed by
%                                     MODprocess_all_L1_to_L2.m (skips
%                                     spectra processing entirely when
%                                     false) and
%                                     MODprocess_single_L1_to_L2_profile.m
%                                     (still builds a profile - CTD data is
%                                     saved regardless - but never computes
%                                     spectra when false).
%     PROCESS.latitude             - for ctd.z when no GPS fix
%     PROCESS.channels             - AFE sensor names in ADC slot order,
%                                     e.g. {'t1','t2','s1','s2','a1','a2','a3'}
%                                     - order comes from setup.yml's
%                                     instrument_manifest.afe.channel_N
%                                     keys, sorted numerically by N (not
%                                     from yaml field order). {} (empty)
%                                     when manifest.has_epsi is false.
%     PROCESS.Fs_epsi               - Hz, nominal EFE board sample rate,
%                                     from setup.yml's afe.sample_rate.
%                                     NOT set at all if the key is absent -
%                                     see NOTES below on why this function
%                                     never silently defaults anything.
%     PROCESS.fft_length,
%              .fft_segments_per_scan, .scan_overlap
%                                   - spectral/scan-windowing parameters for
%                                     mod_scan_get_spectra.m/mod_L2_tile_scans.m,
%                                     from setup.yml's spectral.fft_length/
%                                     .fft_segments_per_scan/.scan_overlap.
%                                     scan_length is derived from the first
%                                     two (toolbox/mod_scan_length_from_segments.m),
%                                     dof from fft_segments_per_scan alone
%                                     (toolbox/mod_scan_dof.m) - neither is a
%                                     yaml-configurable field of its own -
%                                     see mod_scan_calc_chi_mle.m. NOT set
%                                     if the spectral: block or the
%                                     specific key is absent.
%     PROCESS.epsi_gap_factor       - scan-window gap threshold for the
%                                     epsi record (modProcess_extract_profile.m,
%                                     mod_L2_tile_scans.m), from setup.yml's
%                                     spectral.epsi_gap_factor. NOT set if
%                                     absent.
%     PROFILES.lowpass_factor,
%              .ctd_gap_factor,
%              .buffer_bins          - profiling-direction detection
%                                     parameters for
%                                     mod_L1_detect_profiling_direction.m,
%                                     from setup.yml's profile_detection:
%                                     block. NOT set if the block or the
%                                     specific key is absent - see that
%                                     function's header for what each one
%                                     controls. ctd_gap_factor was named
%                                     gap_factor before branch
%                                     chi_processing - renamed to pair with
%                                     PROCESS.epsi_gap_factor above.
%     PROFILES.speedLim_down_start_m_s, .speedLim_down_end_m_s,
%              .speedLim_up_start_m_s, .speedLim_up_end_m_s,
%              .minLength_m, .profile_dir
%                                   - full profile-picker parameters for
%                                     modProcess_detect_profiles.m, from
%                                     setup.yml's profile_detection: block.
%                                     NOT set if the block or the specific
%                                     key is absent.
%     PROCESS.CHI.time_constant_s  - FP07 time-constant coefficient tau0
%                                     [s] (mod_scan_fpo7_transfer_function.m:
%                                     tau = tau0*abs(w)^exponent), from
%                                     setup.yml's chi.time_constant_s. NOT
%                                     set if absent.
%     PROCESS.CHI.fall_speed_exponent
%                                   - fall-speed exponent in the same tau
%                                     formula (mod_scan_fpo7_transfer_function.m),
%                                     from setup.yml's chi.fall_speed_exponent.
%                                     NOT set if absent.
%     PROCESS.CHI.noise_adjusted_to_f
%                                   - fraction of f(end) (Nyquist) above
%                                     which mod_scan_fpo7_cutoff.m
%                                     normalizes the observed spectrum onto
%                                     the bench noise floor's scale, from
%                                     setup.yml's chi.noise_adjusted_to_f.
%                                     NOT set if absent.
%     PROCESS.CHI.n_smooth_f_spectrum
%                                   - movmean smoothing window [bins] applied
%                                     to the observed spectrum before the
%                                     noise-floor search
%                                     (mod_scan_fpo7_cutoff.m), from
%                                     setup.yml's chi.n_smooth_f_spectrum.
%                                     NOT set if absent.
%     PROCESS.CHI.sn_min           - signal-to-noise multiplier
%                                     (mod_scan_fpo7_cutoff.m: cutoff is
%                                     where the smoothed spectrum drops
%                                     below sn_min x the bench noise
%                                     floor), from setup.yml's chi.sn_min.
%                                     NOT set if absent.
%     PROCESS.CHI.n_skip           - number of lowest-frequency bins
%                                     excluded from the noise-floor search
%                                     (mod_scan_fpo7_cutoff.m), from
%                                     setup.yml's chi.n_skip. NOT set if
%                                     absent.
%     PROCESS.CHI.kmin_obs         - low-wavenumber integration bound [cpm]
%                                     for chi_obs/chi_mle
%                                     (mod_scan_calc_chi_obs.m,
%                                     mod_scan_calc_chi_mle.m), from
%                                     setup.yml's chi.kmin_obs. NOT set if
%                                     absent.
%     PROCESS.CHI.chi_mle_start_search,
%                 .chi_mle_end_search
%                                   - chi_mle's grid-search range, as
%                                     multipliers on the chi_obs-seeded
%                                     starting value (mod_scan_calc_chi_mle.m:
%                                     search_lo = chi_seed*chi_mle_start_search,
%                                     search_hi = chi_seed*chi_mle_end_search),
%                                     from setup.yml's chi.chi_mle_start_search/
%                                     .chi_mle_end_search. NOT set if absent.
%     AFE.(channel).full_range     - volts, for counts->volts conversion,
%                                     from setup.yml's afe.channels.(channel)
%     AFE.(channel).ADCconf        - 'Bipolar' or 'Unipolar', from
%                                     setup.yml's afe.channels.(channel)
%     AFE.(channel).type           - 'shear', 'fpo7', 'acc', etc., from
%                                     setup.yml's instrument_manifest.afe
%     AFE.(channel).ADCfilter      - ADC anti-alias filter type, e.g.
%                                     'sinc4', from setup.yml's
%                                     afe.channels.(channel).ADCfilter.
%                                     Defaults to 'sinc4' if absent (the
%                                     standard EFE board filter - see
%                                     MODsetup_define_filters.m)
%     AFE.(channel).SN             - only set when the manifest's
%                                     channel_N.sn is present and non-empty
%     AFE.(channel).cal            - only set for 'shear' type channels
%                                     with an SN (above). Sv, the most
%                                     recent (last) row of
%                                     calibrations_root/SHEAR_PROBES/<SN>/
%                                     Calibration_<SN>.txt. [] if that file
%                                     doesn't exist yet (e.g. a newly-
%                                     assigned probe with no calibration
%                                     measured yet). Not set at all for
%                                     'fpo7' - dTdV isn't a fixed,
%                                     lookupable property of the probe;
%                                     it's fit in-situ per deployment
%                                     against real CTD temperature data,
%                                     which is a later L1 step's job.
%     CTD.name, .sample_per_record - only set when setup.yml has a ctd:
%                                     block (deployments with no CTD don't
%                                     need one)
%     CTD.SN, .cal                 - only set when setup.yml's
%                                     instrument_manifest.ctd.sn is
%                                     present and non-empty. SN is always
%                                     reformatted to 4 digits, zero-padded
%                                     (537 -> '0537') to match SBE .CAL
%                                     naming, regardless of how setup.yml
%                                     wrote it (537, '537', or '0537' all
%                                     work). .cal is SBE calibration
%                                     coefficients, read from
%                                     calibrations_root/SBE/<SN>.CAL
%     GEOMETRY.alt_angle_deg, .alt_dist_from_crashguard_ft,
%              .alt_probe_dist_from_crashguard_in
%                                   - from setup.yml's altimeter.fctd or
%                                     altimeter.epsi block matching
%                                     fish_flag, if present; otherwise
%                                     looked up from the repo-committed
%                                     setup/platform_instrument_geometry.yml
%                                     table by fish_flag (and vehicle_name,
%                                     where the table needs it) - see that
%                                     file's header. Left unset if neither
%                                     source has a matching entry
%                                     (deployments with no alt/isap
%                                     hardware don't need one)
%
% CALLED BY
%   (top-level scripts / notebooks) - called once per session, before
%   MODprocess_all_L0_to_L1.m or MODprocess_single_L0_to_L1.m, not by them
%
% CALLS
%   toolbox/YAMLMatlab_0.4.3/ReadYaml.m
%   MODsetup_save_metadata.m
%   (local subfunctions: read_sbe_cal, read_probe_cal, probe_cal_subdir,
%    lookup_altimeter_geometry, hash_file)
%
% NOTES
%   MATLAB has no built-in YAML reader (checked in R2024b: no yaml.*
%   namespace, readstruct doesn't accept 'yaml' as a FileType), so this
%   vendors the same third-party YAMLMatlab_0.4.3 toolbox the old
%   MOD_fish_lib codebase used (MODsetup_make_metadata_from_yaml.m).
%
%   This function never silently fills a default for any field it doesn't
%   find in setup.yml - not every deployment needs every value (a FastCTD
%   deployment needs zero chi variables), so unconditionally populating
%   e.g. metadata.PROCESS.CHI.* for every deployment would be wrong, not
%   just undocumented. Filling a genuinely-needed missing value is
%   MODsetup_validate_metadata.m's job instead: called by a consuming
%   function (mod_scan_calc_chi_obs.m, etc.) with the exact list of values
%   it needs, it prompts the operator once, offers to save the answer into
%   this setup.yml (MODsetup_write_yaml_value.m), and signals the caller
%   to reload metadata via this function again. See
%   MODsetup_metadata_field_registry.m for the full list of yaml-drivable
%   values and where each lives in metadata.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

toolbox_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3');
addpath(toolbox_dir);
yml = ReadYaml(setup_yml);

%% Paths - derived fresh from data_root, never saved
meta_dir = fileparts(setup_yml);
metadata.paths.data_root         = yml.data_root;
metadata.paths.raw               = fullfile(yml.data_root, 'raw');
metadata.paths.L0                = fullfile(yml.data_root, 'L0');
metadata.paths.L1                = fullfile(yml.data_root, 'L1');
metadata.paths.L2                = fullfile(yml.data_root, 'L2');
metadata.paths.profiles          = fullfile(yml.data_root, 'profiles');
metadata.paths.profiles_raw      = fullfile(yml.data_root, 'profiles_raw');
metadata.paths.meta              = meta_dir;
metadata.paths.calibrations_root = yml.calibrations_root;
% ctd/ only exists for vehicles whose CTD arrives as an independent file
% rather than embedded $SB49/$SB41 blocks (DeepSolo, Wirewalker) - defined
% unconditionally like the other path fields, whether or not it exists on
% disk for this deployment.
metadata.paths.ctd               = fullfile(yml.data_root, 'ctd');
% Full path to setup_yml itself - how MODsetup_validate_metadata.m (called
% from deep inside mod_scan_*.m) finds its way back to the yaml file to
% write a newly-prompted value into, without every function needing its
% own yaml_file argument. Same "derived fresh every call, stripped before
% saving metadata.mat" convention as the rest of paths.*.
metadata.paths.setup_yml         = setup_yml;

%% Deployment info
metadata.fish_flag = yml.fish_flag;
metadata.PROCESS.latitude = yml.latitude;
% vehicle_name is optional (older setup.yml files predate it) - '' means
% "not declared", not "no vehicle".
metadata.vehicle_name = '';
if isfield(yml, 'vehicle_name')
    metadata.vehicle_name = yml.vehicle_name;
end

%% EFE sample rate - only set if setup.yml declares it. See
% MODsetup_metadata_field_registry.m/MODsetup_validate_metadata.m for how
% a consuming function asks for (and, if missing, prompts for and
% persists) this and every other field below - never silently defaulted
% here, since not every deployment needs every value.
if isfield(yml, 'afe') && isfield(yml.afe, 'sample_rate')
    metadata.PROCESS.Fs_epsi = yml.afe.sample_rate;
end

%% Spectral processing parameters (mod_scan_get_spectra.m, mod_L2_tile_scans.m)
if isfield(yml, 'spectral')
    spectral_fields = {'fft_length', 'fft_segments_per_scan', 'scan_overlap', 'epsi_gap_factor'};
    for iF = 1:numel(spectral_fields)
        field = spectral_fields{iF};
        if isfield(yml.spectral, field)
            metadata.PROCESS.(field) = yml.spectral.(field);
        end
    end
end

%% Profiling-direction detection parameters
% (mod_L1_detect_profiling_direction.m). Namespaced under PROFILES (not
% PROCESS) to match the old Meta_Data.PROFILES.* convention from
% epsiProcess_get_profiles_from_PressureTimeseries.m, so a future full
% profile-picker port can extend this same setup.yml section.
if isfield(yml, 'profile_detection')
    if isfield(yml.profile_detection, 'lowpass_factor')
        metadata.PROFILES.lowpass_factor = yml.profile_detection.lowpass_factor;
    end
    if isfield(yml.profile_detection, 'ctd_gap_factor')
        metadata.PROFILES.ctd_gap_factor = yml.profile_detection.ctd_gap_factor;
    end
    if isfield(yml.profile_detection, 'buffer_bins')
        metadata.PROFILES.buffer_bins = yml.profile_detection.buffer_bins;
    end
    % Full profile-picker parameters (modProcess_detect_profiles.m) - not
    % every deployment needs these yet (only picking discrete profiles
    % does, not the realtime per-file L1->L2 path), so - same rule as
    % everything else in this function - only set when setup.yml actually
    % declares them.
    profile_picker_fields = {'speedLim_down_start_m_s', 'speedLim_down_end_m_s', ...
        'speedLim_up_start_m_s', 'speedLim_up_end_m_s', 'minLength_m', 'profile_dir'};
    for iF = 1:numel(profile_picker_fields)
        field = profile_picker_fields{iF};
        if isfield(yml.profile_detection, field)
            metadata.PROFILES.(field) = yml.profile_detection.(field);
        end
    end
end

%% Chi processing parameters (mod_scan_fpo7_cutoff.m, mod_scan_get_spectra.m,
% mod_scan_calc_chi_obs.m, mod_scan_calc_chi_mle.m)
if isfield(yml, 'chi')
    chi_fields = {'time_constant_s', 'fall_speed_exponent', 'noise_adjusted_to_f', ...
        'n_smooth_f_spectrum', 'sn_min', 'n_skip', ...
        'kmin_obs', 'chi_mle_start_search', 'chi_mle_end_search'};
    for iF = 1:numel(chi_fields)
        field = chi_fields{iF};
        if isfield(yml.chi, field)
            metadata.PROCESS.CHI.(field) = yml.chi.(field);
        end
    end
end

%% Instrument manifest - what's physically on this vehicle. See setup.yml's
% instrument_manifest block: presence-only flags today (nothing in L0->L1
% reads them yet), []/false when the key is missing entirely, same as an
% explicit false - a later step can start reading these without every
% existing setup.yml needing an edit first.
manifest_flags = {'vnav', 'isap', 'alt', 'gps', 'fluor'};
has_manifest = isfield(yml, 'instrument_manifest');
for iF = 1:numel(manifest_flags)
    flag = manifest_flags{iF};
    present = has_manifest && isfield(yml.instrument_manifest, flag) && logical(yml.instrument_manifest.(flag));
    metadata.manifest.(['has_' flag]) = present;
end

% has_epsi: true only when instrument_manifest.afe is present and declares
% at least one channel slot. Unlike the presence-only flags above, afe is
% not a boolean key - it's a whole sub-struct of channel_N slots - so this
% is computed separately rather than folded into manifest_flags. A
% CTD-only vehicle (no AFE board) simply omits instrument_manifest.afe
% entirely, same "absent key means not on the vehicle" rule as vnav/isap/
% alt/gps/fluor.
has_epsi = has_manifest && isfield(yml.instrument_manifest, 'afe') ...
    && ~isempty(fieldnames(yml.instrument_manifest.afe));
metadata.manifest.has_epsi = has_epsi;

%% AFE channel manifest - slot order comes explicitly from
% instrument_manifest.afe.channel_N keys, sorted numerically by N, rather
% than from yaml field order (which the old schema relied on and which
% YAML does not guarantee to preserve past single digits). Skipped
% entirely when has_epsi is false (no afe: block to read) - channels stays
% {} and metadata.AFE is never populated, rather than erroring on a
% missing instrument_manifest.afe.
channel_names = {};
if has_epsi
    afe_manifest = yml.instrument_manifest.afe;
    slot_fields = fieldnames(afe_manifest);
    slot_numbers = cellfun(@(f) sscanf(f, 'channel_%d'), slot_fields);
    [~, slot_order] = sort(slot_numbers);
    slot_fields = slot_fields(slot_order);

    channel_names = cell(numel(slot_fields), 1);
    for iC = 1:numel(slot_fields)
        slot = afe_manifest.(slot_fields{iC});
        ch = slot.name;
        channel_names{iC} = ch;

        % Electrical details (full_range, ADCconf) live in the separate
        % afe.channels detail section, keyed by sensor name.
        metadata.AFE.(ch).full_range = yml.afe.channels.(ch).full_range;
        metadata.AFE.(ch).ADCconf    = yml.afe.channels.(ch).ADCconf;
        metadata.AFE.(ch).type       = slot.type;

        % ADC anti-alias filter type - optional, defaults to 'sinc4' (every
        % deployment's EFE board uses a sinc^4 decimation filter today, same
        % as the legacy MOD_fish_lib metadata this was ported from - see
        % MODsetup_define_filters.m, the only consumer). Exposed as a real
        % yaml field rather than hardcoded downstream in case a future board
        % ever differs.
        metadata.AFE.(ch).ADCfilter = 'sinc4';
        if isfield(yml.afe.channels.(ch), 'ADCfilter')
            metadata.AFE.(ch).ADCfilter = yml.afe.channels.(ch).ADCfilter;
        end

        % Probe serial number - identifies which physical probe is on this
        % channel, whether or not its calibration comes from a lookup file.
        % Optional: channels with no probe (e.g. acc) or no sn field in this
        % manifest entry are left without an SN field.
        if isfield(slot, 'sn') && ~isempty(slot.sn)
            SN = slot.sn;
            if isnumeric(SN)
                SN = num2str(SN);
            end
            metadata.AFE.(ch).SN = SN;

            % Shear probes: Sv is a fixed property of the probe, measured on
            % a calibration rig and logged to a per-SN file - a real lookup.
            % FPO7 probes: dTdV is NOT a fixed, lookupable property - it's
            % fit in-situ per deployment (sometimes per profile) against real
            % CTD temperature data (mod_epsi_linear_calibration_FP07.m:
            % polyfit(volts, T, 1)), so there is no calibration file to read
            % here. That fit needs time-aligned ctd.T and is a later L1 step's
            % job, not something a static per-SN file can answer.
            cal_subdir = probe_cal_subdir(metadata.AFE.(ch).type);
            if ~isempty(cal_subdir)
                cal_file = fullfile(yml.calibrations_root, cal_subdir, SN, sprintf('Calibration_%s.txt', SN));
                metadata.AFE.(ch).cal = read_probe_cal(cal_file);
            end
        end
    end
end
metadata.PROCESS.channels = channel_names;

%% CTD - optional: not every deployment carries a CTD
if isfield(yml, 'ctd')
    metadata.CTD.name = yml.ctd.type;
    metadata.CTD.sample_per_record = yml.ctd.sample_per_record;
end
if has_manifest && isfield(yml.instrument_manifest, 'ctd') && isfield(yml.instrument_manifest.ctd, 'sn') && ~isempty(yml.instrument_manifest.ctd.sn)
    % SBE .CAL filenames are always 4-digit zero-padded (e.g. 0537.CAL),
    % unlike shear/fpo7 probe folders which use the bare number - so
    % unconditionally reformat to 4 digits here, regardless of whether
    % setup.yml wrote sn as 537, '537', or '0537'.
    SN = yml.instrument_manifest.ctd.sn;
    if ischar(SN)
        SN = str2double(SN);
    end
    metadata.CTD.SN = sprintf('%04d', SN);
    cal_file = fullfile(yml.calibrations_root, 'SBE', [metadata.CTD.SN '.CAL']);
    metadata.CTD.cal = read_sbe_cal(cal_file);
else
    metadata.CTD.cal = [];
end

%% Altimeter geometry - optional: only deployments with alt/isap hardware
% need one. fish_flag still has to be a recognized value either way, since
% it also picks other things (e.g. downstream steps may branch on it).
switch lower(yml.fish_flag)
    case 'fctd'
        fish_flag_key = 'fctd';
    case 'epsi'
        fish_flag_key = 'epsi';
    otherwise
        error('MODsetup_read_yaml:unknownFishFlag', ...
            'fish_flag "%s" is neither FCTD nor EPSI - cannot pick an altimeter geometry block.', yml.fish_flag);
end
if isfield(yml, 'altimeter') && isfield(yml.altimeter, fish_flag_key)
    % Deployment-specific override - one unit's own setup.yml wins over the
    % shared table below.
    alt_geom = yml.altimeter.(fish_flag_key);
else
    alt_geom = lookup_altimeter_geometry(metadata.fish_flag, metadata.vehicle_name);
end
if ~isempty(alt_geom)
    metadata.GEOMETRY.alt_angle_deg                    = alt_geom.angle_deg;
    metadata.GEOMETRY.alt_dist_from_crashguard_ft       = alt_geom.dist_from_crashguard_ft;
    metadata.GEOMETRY.alt_probe_dist_from_crashguard_in = alt_geom.probe_dist_from_crashguard_in;
end

%% Save metadata.mat (portable - no paths)
metadata_to_save = rmfield(metadata, 'paths');
metadata_to_save.header.yaml_hash = hash_file(setup_yml);
metadata_to_save = MODsetup_save_metadata(metadata_to_save, meta_dir, ...
    'created_from_yaml', setup_yml);

metadata.header = metadata_to_save.header;

end %end function

%% Hash a file's contents (SHA-256, hex string)
function h = hash_file(filename)
fid = fopen(filename, 'rb');
if fid < 0
    error('MODsetup_read_yaml:fileNotFound', 'File not found: %s', filename);
end
bytes = fread(fid, Inf, '*uint8');
fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
md.update(bytes);
h = sprintf('%02x', typecast(md.digest(), 'uint8'));
end

%% Read an SBE .CAL file into a calibration coefficient struct
function SBEcal = read_sbe_cal(filename)
fid = fopen(filename);
if fid < 0
    error('MODsetup_read_yaml:calFileNotFound', 'CTD calibration file not found: %s', filename);
end

line = fgetl(fid);
SBEcal.SN = line(strfind(line,'=')+1:end);

line = fgetl(fid); SBEcal.TempCal_date = line(strfind(line,'=')+1:end);
line = fgetl(fid); SBEcal.ta0 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ta1 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ta2 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ta3 = str2double(line(strfind(line,'=')+1:end));

line = fgetl(fid); SBEcal.CondCal_date = line(strfind(line,'=')+1:end);
line = fgetl(fid); SBEcal.g = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.h = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.i = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.j = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.tcor = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.pcor = str2double(line(strfind(line,'=')+1:end));

line = fgetl(fid); SBEcal.PresCal_date = line(strfind(line,'=')+1:end);
line = fgetl(fid); SBEcal.pa0 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.pa1 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.pa2 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptca0 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptca1 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptca2 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptcb0 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptcb1 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptcb2 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptempa0 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptempa1 = str2double(line(strfind(line,'=')+1:end));
line = fgetl(fid); SBEcal.ptempa2 = str2double(line(strfind(line,'=')+1:end));

fclose(fid);
end

%% Look up shared altimeter geometry by platform (fish_flag, vehicle_name)
% from setup/platform_instrument_geometry.yml's altimeter: block -
% repo-committed, not a per-deployment path. A fish_flag entry is either a
% geometry block directly (one mount shared by every vehicle with that
% fish_flag, e.g. FCTD) or a struct of per-vehicle_name geometry blocks
% (e.g. EPSI) - isfield(entry,'angle_deg') tells the two apart. Returns []
% if fish_flag has no entry, or (per-vehicle case) vehicle_name has no
% entry - same "absent means not set, never guessed" rule as the rest of
% this function.
function alt_geom = lookup_altimeter_geometry(fish_flag, vehicle_name)
alt_geom = [];
table_file = fullfile(fileparts(mfilename('fullpath')), 'platform_instrument_geometry.yml');
table = ReadYaml(table_file);
if ~isfield(table, 'altimeter') || ~isfield(table.altimeter, fish_flag)
    return
end
entry = table.altimeter.(fish_flag);
if isfield(entry, 'angle_deg')
    alt_geom = entry;
elseif ~isempty(vehicle_name) && isfield(entry, vehicle_name)
    alt_geom = entry.(vehicle_name);
end
end

%% Map an AFE channel's declared type to its calibration folder name.
% Only 'shear' has a per-SN file to look up (Sv, from a calibration rig).
% 'fpo7' deliberately returns '' - dTdV is fit in-situ per deployment
% against real CTD temperature, not read from a file (see the AFE loop
% above). 'acc' and anything else also return '' - no probe calibration
% file applies.
function subdir = probe_cal_subdir(afe_type)
switch lower(afe_type)
    case 'shear'
        subdir = 'SHEAR_PROBES';
    otherwise
        subdir = '';
end
end

%% Read a per-probe calibration file (shear Sv or FPO7 dTdV format): a
% header line followed by one row per calibration event, "date,
% coefficient, C". Returns the most recent (last) row's coefficient -
% matches mod_som_get_shear_probe_calibration_v2.m /
% mod_som_get_temp_probe_calibration.m's "latest calibration wins"
% convention. Returns [] if the file doesn't exist (e.g. a probe with no
% calibration measured yet) rather than erroring, since that's the normal
% state for a newly-assigned probe.
function cal = read_probe_cal(filename)
cal = [];
fid = fopen(filename);
if fid < 0
    return
end
raw = textscan(fid, '%s %f %f', 'Delimiter', ',', 'HeaderLines', 1);
fclose(fid);
if ~isempty(raw{2}) && ~all(isnan(raw{2}))
    cal = raw{2}(end);
end
end
