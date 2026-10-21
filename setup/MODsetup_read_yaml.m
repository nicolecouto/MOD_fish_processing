function metadata = MODsetup_read_yaml(setup_yml)
% MODsetup_read_yaml        Part of MOD_fish_processing
%
% metadata = MODsetup_read_yaml(setup_yml)
%
% DESCRIPTION
%   Reads a deployment's yml and returns a metadata struct with paths
%   derived fresh on every call (never saved - see paths below), the AFE
%   channel manifest and altimeter geometry. Resolves what the L0->L1 step
%   actually uses for computation (metadata.PROCESS.*, metadata.AFE.*,
%   metadata.GEOMETRY.*) plus a few identifying CTD fields
%   (metadata.CTD.name/.SN/.sample_per_record) kept for the deployment
%   record even though L0->L1 doesn't read them - grows as later pipeline
%   steps need more (see PLAN.md Section 2).
%
%   setup.yml's instrument_manifest block is the single place that says
%   what's physically on the vehicle (which AFE channel holds which probe
%   type/SN, plus presence flags for isap/alt/gps/fluor) - see
%   PLAN.md Section 5. Electrical/sampling specifics (full_range,
%   ADCconf, sample_per_record, ...) live in separate detail sections
%   (afe.channels, ctd, altimeter), keyed by the same names the manifest
%   declares. An instrument entirely absent from instrument_manifest is
%   treated as not on the deployment - nothing errors on a missing key.
%
%   Saves metadata.mat into paths.meta, with metadata.paths stripped out
%   first - metadata.mat is a portable deployment record; paths are
%   machine-specific and always re-derived on the next call. The save goes through
%   MODsetup_save_metadata.m, which no-ops if nothing has changed since
%   the last call (the common case - a deployment script re-reads the
%   same setup.yml many times an hour during a cruise), and otherwise
%   archives the previous metadata.mat before writing the new one. See
%   PLAN.md Section 2, "Metadata provenance and archiving."
%
% INPUTS
%   setup_yml - full path to the yml. Two kinds:
%     - a processing run's yml, <survey>/meta/meta_data_<run>.yml (built by
%       MODsetup_build_yaml.m): every path comes from where the file is,
%       so a copied survey folder works anywhere - its data_root line is
%       not used. raw/ and L0/ are the survey's (shared by every run);
%       the run's own output is in <survey>/processed/<run>/; L1 is the
%       run's own, or another run's when the yml has run.L1_from.
%     - any other yml (a hand-written setup.yml, dev1_setup.yml): paths
%       from its data_root, with raw/L0/L1/L2/... under it and meta/ the
%       yml's own folder.
%
% OUTPUTS
%   metadata  - struct with fields:
%     run.name, run.L1_from        - this run ('' for a non-run yml), and
%                                     the run whose L1 it uses ('' = its own)
%     paths.data_root, .raw, .L0, .L1, .L2, .profiles_L2, .profiles_L1, .gridded, .meta,
%     .L1_meta, .run, .survey_meta, .calibrations_root, .ctd, .setup_yml
%                                   - for a run yml: .data_root is the
%                                     survey folder, .run is
%                                     processed/<run>/, .meta its meta/
%                                     (casts.mat, metadata.mat, logs),
%                                     .L1/.L1_meta the L1 folder and meta/
%                                     of the run that made the L1 (itself,
%                                     or run.L1_from) - the files built
%                                     from L1 (time_index, pressure and
%                                     twist time series, l1_file_cache,
%                                     fpo7_calibration) go with that L1;
%                                     .survey_meta is <survey>/meta/. For
%                                     any other yml, .run is data_root and
%                                     .meta/.L1_meta/.survey_meta are all
%                                     the yml's folder.
%                                   - .ctd is only meaningful for vehicles
%                                     with an independent CTD file (see
%                                     vehicle_name below) - defined
%                                     unconditionally like the other paths,
%                                     whether or not data_root/ctd/ exists.
%                                     .profiles_L2 is where
%                                     MODprocess_all_L1_to_L2.m saves the
%                                     converted (spectra/chi/epsilon)
%                                     Profile####.mat when pointed at
%                                     .profiles_L1 (post-processing mode),
%                                     deliberately a sibling of .L2 (not
%                                     inside it) so the per-file realtime
%                                     output and the per-cast final output
%                                     never share a directory. .profiles_L1 is where
%                                     MODprocess_all_extract_profiles.m
%                                     saves the stitched-but-not-yet-
%                                     converted raw epsi/ctd record for each
%                                     profile - a separate directory from
%                                     .profiles_L2 so the two pipeline stages
%                                     (extraction, conversion) never
%                                     collide on the same Profile####.mat
%                                     filename (PLAN.md Phase A refactor).
%                                     Naming mirrors .L1/.L2: profiles_L1 is
%                                     the profile-cut analog of an L1 file
%                                     (physical units, not yet windowed),
%                                     profiles_L2 the analog of an L2 file
%                                     (per-scan spectra/chi/epsilon).
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
%     platform                     - how the vehicle is deployed, lower
%                                     case: 'ship' (Start New Deployment
%                                     always writes it), or typed into the
%                                     yml for a postprocessed one, e.g.
%                                     'wirewalker', 'deepsolo', 'uuv',
%                                     'apex'. A yml without it: 'deepsolo'
%                                     or 'wirewalker' when vehicle_name is
%                                     one, else 'ship'. MODprocess_grid.m
%                                     uses it for each cast's position.
%     winch_spool                  - the spool on the winch, from setup.yml
%                                     (Start New Deployment writes it to
%                                     dev1_setup.yml). One winch and one
%                                     spool serve every vehicle; the cruise
%                                     twist count restarts where it changes.
%                                     '' if not declared.
%     manifest.has_isap/.has_alt/.has_gps/.has_fluor
%                                   - presence flags from setup.yml's
%                                     instrument_manifest block. false when
%                                     the key is missing entirely, same as
%                                     when it's explicitly false. Not
%                                     consumed by L0->L1 today (vnav etc.
%                                     just pass through unchanged) - a
%                                     record of what's on the vehicle for
%                                     later steps. (No has_vnav: twist is
%                                     made whenever the raw files have VNAV.)
%     manifest.has_epsi             - true only when setup.yml's
%                                     instrument_manifest.afe block is
%                                     present and declares at least one
%                                     channel. A CTD-only vehicle (no AFE
%                                     board at all - e.g. a bare FastCTD or
%                                     Wirewalker cast) has no afe: block,
%                                     so this comes back false rather than
%                                     erroring - see PROCESS.channels/AFE.*
%                                     below. Consumed by
%                                     MODprocess_single_L1_to_L2.m (skips
%                                     epsi tiling entirely when false - CTD
%                                     data is still returned regardless,
%                                     spectra/chi/epsilon just never get
%                                     computed).
%     PROCESS.latitude             - for ctd.z when no GPS fix
%     PROCESS.channels             - AFE sensor names in ADC slot order,
%                                     e.g. {'t1','t2','s1','s2','a1','a2','a3'}
%                                     - order comes from setup.yml's
%                                     instrument_manifest.afe.channel_N
%                                     keys, sorted numerically by N (not
%                                     from yaml field order). {} (empty)
%                                     when manifest.has_epsi is false.
%     PROCESS.fs_afe                - Hz, nominal AFE (EFE board) sample rate,
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
%                                     two (processing/scans/mod_scan_length_from_segments.m),
%                                     dof from fft_segments_per_scan alone
%                                     (processing/scans/mod_scan_dof.m) - neither is a
%                                     yaml-configurable field of its own -
%                                     see mod_scan_calc_chi_mle.m. NOT set
%                                     if the spectral: block or the
%                                     specific key is absent.
%     PROCESS.epsi_gap_factor       - scan-window gap threshold for the
%                                     epsi record (modProcess_extract_profile.m,
%                                     mod_L2_tile_scans.m), from setup.yml's
%                                     spectral.epsi_gap_factor. NOT set if
%                                     absent.
%     PROFILES.lowpass_sec,
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
%              .minLength_m, .profile_dir, .speedLim_scan_m_s
%                                   - profile-picker parameters for
%                                     modProcess_detect_profiles.m, and
%                                     the scan direction gate for
%                                     mod_L2_tile_scans.m, from
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
%     PROCESS.EPSILON.epsilon_final_source, .kmin_obs, .contam_freq_hz,
%              .oakey_lc_m, .coherence_fmin_hz, .coherence_fmax_hz,
%              .kmin_mle, .mle_start_search, .mle_end_search,
%              .qc_accel_method, .qc_accel_threshold, .qc_accel_nstd
%                                   - epsilon processing parameters
%                                     (mod_scan_shear_volts_to_shear_spectrum.m,
%                                     mod_scan_shear_accel_coherence.m,
%                                     mod_scan_calc_epsilon_obs.m,
%                                     mod_scan_calc_epsilon_mle.m,
%                                     mod_L2_tile_scans.m's epsilon_final_source
%                                     selection - qc_accel_* registered for a
%                                     future modProcess_L2_qc.m, not consumed
%                                     yet), from setup.yml's epsilon: block,
%                                     same key names. NOT set if the block or
%                                     the specific key is absent - see
%                                     docs/workflow/L2_calc_eps.md.
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
%     CTD.name, .sample_per_record - only set when setup.yml's ctd: block
%                                     declares .type/.sample_per_record
%                                     respectively (independent of each
%                                     other)
%     CTD.SN                       - only set when setup.yml's
%                                     instrument_manifest.ctd.sn is
%                                     present and non-empty. Always
%                                     reformatted to 4 digits, zero-padded
%                                     (537 -> '0537') to match SBE .CAL
%                                     naming, regardless of how setup.yml
%                                     wrote it (537, '537', or '0537' all
%                                     work). No calibration is read here:
%                                     L0 takes each raw file's $DCAL (what
%                                     the SBE reports), else
%                                     calibrations_root/SBE/<SN>.CAL - see
%                                     MODprocess_all_modraw_to_L0.m
%     manifest.ctd_som_integrated  - only set when setup.yml's
%                                     instrument_manifest.ctd.som_integrated
%                                     is present. True when this
%                                     deployment's CTD arrives in the same
%                                     modraw stream as EFE/VNAV (embedded
%                                     $SB49/$SB41 blocks); false when it's
%                                     a separate file (e.g. DeepSolo's
%                                     ctd/DeepSoloFallrise.mat via
%                                     MODprocess_read_external_ctd.m).
%                                     Recorded here as manifest metadata
%                                     only - not yet consumed anywhere;
%                                     MODprocess_read_external_ctd.m/
%                                     MODprocess_all_L0_to_L1.m still
%                                     dispatch on vehicle_name.
%     GEOMETRY.alt_angle_deg, .alt_dist_from_crashguard_ft,
%              .alt_probe_dist_from_crashguard_in
%                                   - from setup.yml's altimeter.fctd or
%                                     altimeter.epsi block matching
%                                     fish_flag, if present; otherwise
%                                     looked up from the repo-committed
%                                     setup/platform_instrument_geometry.yml
%                                     table by fish_flag (and vehicle_name,
%                                     where the table needs it; matched
%                                     ignoring case, MAKO1 falling back to
%                                     Mako) - see that file's header. Left unset if neither
%                                     source has a matching entry
%                                     (deployments with no alt/isap
%                                     hardware don't need one)
%
% CALLED BY
%   (top-level scripts / notebooks) - called once per session, before
%   MODprocess_all_L0_to_L1.m or MODprocess_single_L0_to_L1.m, not by them.
%   Also called by MODsetup_preflight.m and MODsetup_add_derived_metadata.m,
%   and directly by MODprocess_all_L0_to_L1.m, MODprocess_all_L1_to_L2.m and
%   MODprocess_all_extract_profiles.m, but only inside their
%   MODsetup_validate_metadata.m:yamlUpdated retry loop, to reload metadata
%   fresh after a prompted value gets saved to setup.yml mid-run - see that
%   function's own DESCRIPTION for why a stale in-memory metadata can't
%   just be patched in place there.
%
% CALLS
%   toolbox/YAMLMatlab_0.4.3/ReadYaml.m
%   MODsetup_save_metadata.m, MODsetup_metadata_field_registry.m
%   (local subfunctions: read_probe_cal, probe_cal_subdir,
%    lookup_altimeter_geometry, field_ignoring_case, hash_file)
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

%% Paths - derived fresh every call, never saved
% A run yml (<survey>/meta/meta_data_<run>.yml) takes every path from where
% it is, so a copied survey folder works anywhere; its data_root (the
% ship's path, from dev1_setup.yml) is not used. Any other yml (a
% hand-written setup.yml, dev1_setup.yml) uses its data_root, with
% L1/L2/meta directly under it.
[yml_dir, yml_name] = fileparts(setup_yml);
run_name = regexp(yml_name, '^meta_data_(.+)$', 'tokens', 'once');
if ~isempty(run_name)
    run_name = run_name{1};
    survey_dir = fileparts(yml_dir);
    L1_from = '';
    if isfield(yml, 'run') && isstruct(yml.run) && isfield(yml.run, 'L1_from') && ~isempty(yml.run.L1_from)
        L1_from = char(string(yml.run.L1_from));
    end
    L1_run = run_name;
    if ~isempty(L1_from)
        L1_run = L1_from;
    end
    run_dir = fullfile(survey_dir, 'processed', run_name);
    meta_dir = fullfile(run_dir, 'meta');
    metadata.run = struct('name', run_name, 'L1_from', L1_from);
    metadata.paths.data_root     = survey_dir;
    metadata.paths.run           = run_dir;
    metadata.paths.survey_meta   = yml_dir;
    metadata.paths.L1            = fullfile(survey_dir, 'processed', L1_run, 'L1');
    metadata.paths.L1_meta       = fullfile(survey_dir, 'processed', L1_run, 'meta');
else
    survey_dir = yml.data_root;
    run_dir = survey_dir;
    meta_dir = yml_dir;
    metadata.run = struct('name', '', 'L1_from', '');
    metadata.paths.data_root     = survey_dir;
    metadata.paths.run           = run_dir;
    metadata.paths.survey_meta   = meta_dir;
    metadata.paths.L1            = fullfile(survey_dir, 'L1');
    metadata.paths.L1_meta       = meta_dir;
end
metadata.paths.raw               = fullfile(survey_dir, 'raw');
metadata.paths.L0                = fullfile(survey_dir, 'L0');
metadata.paths.L2                = fullfile(run_dir, 'L2');
metadata.paths.profiles_L2       = fullfile(run_dir, 'profiles_L2');
metadata.paths.profiles_L1       = fullfile(run_dir, 'profiles_L1');
metadata.paths.gridded           = fullfile(run_dir, 'gridded');
metadata.paths.meta              = meta_dir;
metadata.paths.calibrations_root = yml.calibrations_root;
% ctd/ only exists for vehicles whose CTD arrives as an independent file
% rather than embedded $SB49/$SB41 blocks (DeepSolo, Wirewalker) - defined
% unconditionally like the other path fields, whether or not it exists on
% disk for this deployment.
metadata.paths.ctd               = fullfile(survey_dir, 'ctd');
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
% platform: typed for postprocessed platforms; an older yml without it was
% the ship unless its vehicle_name says it was a profiler
if isfield(yml, 'platform') && ~isempty(yml.platform)
    metadata.platform = lower(char(string(yml.platform)));
elseif any(strcmpi(metadata.vehicle_name, {'deepsolo', 'wirewalker'}))
    metadata.platform = lower(metadata.vehicle_name);
else
    metadata.platform = 'ship';
end
metadata.winch_spool = '';
if isfield(yml, 'winch_spool')
    metadata.winch_spool = char(string(yml.winch_spool));
end

%% Processing parameters - every value MODsetup_metadata_field_registry.m
% knows about (spectral, profile_detection, chi, ucond, epsilon, grid, plus
% afe.sample_rate), copied from its
% yaml_section.yaml_key to its metadata_path only when setup.yml declares
% it. One loop over the registry, so a parameter added there is read here
% with no second list to keep in step. Never defaulted here - a missing
% value is filled by MODsetup_validate_metadata.m when a consumer needs it.
registry = MODsetup_metadata_field_registry();
for iR = 1:numel(registry)
    spec = registry(iR);
    if isfield(yml, spec.yaml_section) && isstruct(yml.(spec.yaml_section)) ...
            && isfield(yml.(spec.yaml_section), spec.yaml_key)
        metadata = setfield(metadata, spec.metadata_path{:}, yml.(spec.yaml_section).(spec.yaml_key));
    end
end

%% Instrument manifest - what's physically on this vehicle. See setup.yml's
% instrument_manifest block: presence-only flags today (nothing in L0->L1
% reads them yet), []/false when the key is missing entirely, same as an
% explicit false - a later step can start reading these without every
% existing setup.yml needing an edit first.
manifest_flags = {'isap', 'alt', 'gps', 'fluor'};
has_manifest = isfield(yml, 'instrument_manifest');
for iF = 1:numel(manifest_flags)
    flag = manifest_flags{iF};
    % true, or {sn: ...} (Start New Deployment writes the serial number when given)
    present = has_manifest && isfield(yml.instrument_manifest, flag) && ...
        (isstruct(yml.instrument_manifest.(flag)) || logical(yml.instrument_manifest.(flag)));
    metadata.manifest.(['has_' flag]) = present;
end

% has_epsi: true only when instrument_manifest.afe is present and declares
% at least one channel slot. Unlike the presence-only flags above, afe is
% not a boolean key - it's a whole sub-struct of channel_N slots - so this
% is computed separately rather than folded into manifest_flags. A
% CTD-only vehicle (no AFE board) simply omits instrument_manifest.afe
% entirely, same "absent key means not on the vehicle" rule as isap/alt/
% gps/fluor.
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

%% CTD - optional: not every deployment carries a CTD, and type and
% sample_per_record are each read independently.
if isfield(yml, 'ctd') && isfield(yml.ctd, 'type')
    metadata.CTD.name = yml.ctd.type;
end
if isfield(yml, 'ctd') && isfield(yml.ctd, 'sample_per_record')
    metadata.CTD.sample_per_record = yml.ctd.sample_per_record;
end

%% Instrument manifest ctd sub-block - whether this deployment's CTD
% arrives in the same modraw stream as EFE/VNAV (SOM-integrated, embedded
% $SB49/$SB41 blocks) or via a separate file (e.g. DeepSolo's
% ctd/DeepSoloFallrise.mat, MODprocess_read_external_ctd.m). Recorded here
% as manifest metadata only - MODprocess_read_external_ctd.m/
% MODprocess_all_L0_to_L1.m still dispatch on vehicle_name, not this flag.
if has_manifest && isfield(yml.instrument_manifest, 'ctd') && isfield(yml.instrument_manifest.ctd, 'som_integrated')
    metadata.manifest.ctd_som_integrated = logical(yml.instrument_manifest.ctd.som_integrated);
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
elseif ~isfield(metadata, 'CTD')
    metadata.CTD = struct();
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
if ~isfolder(meta_dir)
    mkdir(meta_dir); % a run's processed/<run>/meta/, the first time it's read
end
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

%% Look up shared altimeter geometry by platform (fish_flag, vehicle_name)
% from setup/platform_instrument_geometry.yml's altimeter: block -
% repo-committed, not a per-deployment path. A fish_flag entry is either a
% geometry block directly (one mount shared by every vehicle with that
% fish_flag, e.g. FCTD) or a struct of per-vehicle_name geometry blocks
% (e.g. EPSI) - isfield(entry,'angle_deg') tells the two apart. Keys match
% case-insensitively, and a numbered unit with no entry of its own falls
% back to its family (MAKO1 -> Mako; Start New Deployment writes the unit).
% Returns [] if fish_flag has no entry, or (per-vehicle case) neither the
% vehicle_name nor its family has one - same "absent means not set, never
% guessed" rule as the rest of this function.
function alt_geom = lookup_altimeter_geometry(fish_flag, vehicle_name)
alt_geom = [];
table_file = fullfile(fileparts(mfilename('fullpath')), 'platform_instrument_geometry.yml');
table = ReadYaml(table_file);
if ~isfield(table, 'altimeter')
    return
end
entry = field_ignoring_case(table.altimeter, fish_flag);
if isempty(entry)
    return
end
if isfield(entry, 'angle_deg')
    alt_geom = entry;
elseif ~isempty(vehicle_name)
    alt_geom = field_ignoring_case(entry, vehicle_name);
    if isempty(alt_geom)
        % Numbered unit (MAKO1, MAKO2, ...) falls back to its family (Mako)
        alt_geom = field_ignoring_case(entry, regexprep(vehicle_name, '\d+$', ''));
    end
end
end

%% s.(name) with name matched case-insensitively; [] if there's no match
function val = field_ignoring_case(s, name)
val = [];
names = fieldnames(s);
iMatch = find(strcmpi(names, name), 1);
if ~isempty(iMatch)
    val = s.(names{iMatch});
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
