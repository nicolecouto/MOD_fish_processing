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
%     paths.data_root, .raw, .L0, .L1, .meta, .calibrations_root, .ctd
%                                   - .ctd is only meaningful for vehicles
%                                     with an independent CTD file (see
%                                     vehicle_name below) - defined
%                                     unconditionally like the other paths,
%                                     whether or not data_root/ctd/ exists
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
%     PROCESS.latitude             - for ctd.z when no GPS fix
%     PROCESS.channels             - AFE sensor names in ADC slot order,
%                                     e.g. {'t1','t2','s1','s2','a1','a2','a3'}
%                                     - order comes from setup.yml's
%                                     instrument_manifest.afe.channel_N
%                                     keys, sorted numerically by N (not
%                                     from yaml field order)
%     PROCESS.Fs_epsi               - Hz, nominal EFE board sample rate,
%                                     from setup.yml's afe.sample_rate.
%                                     Default 320 (the standard EFE board
%                                     rate) if the key is absent - so older
%                                     setup.yml files don't need an edit.
%     PROCESS.nfft, .dof            - spectral processing parameters for
%                                     mod_scan_get_spectra.m, from
%                                     setup.yml's spectral.nfft/.dof.
%                                     Defaults 1024/3 (same defaults as the
%                                     old MOD_fish_lib Acquisition/setup.yml
%                                     templates) if the spectral: block is
%                                     absent.
%     PROFILES.lowpass_factor,
%              .gap_factor,
%              .buffer_bins          - profiling-direction detection
%                                     parameters for
%                                     mod_L1_detect_profiling_direction.m,
%                                     from setup.yml's profile_detection:
%                                     block. Defaults 3/5/1 if the block is
%                                     absent - see that function's header
%                                     for what each one controls.
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
%                                   - only set when setup.yml has an
%                                     altimeter.fctd or altimeter.epsi
%                                     block matching fish_flag
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
%    hash_file)
%
% NOTES
%   MATLAB has no built-in YAML reader (checked in R2024b: no yaml.*
%   namespace, readstruct doesn't accept 'yaml' as a FileType), so this
%   vendors the same third-party YAMLMatlab_0.4.3 toolbox the old
%   MOD_fish_lib codebase used (MODsetup_make_metadata_from_yaml.m).
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
metadata.paths.meta              = meta_dir;
metadata.paths.calibrations_root = yml.calibrations_root;
% ctd/ only exists for vehicles whose CTD arrives as an independent file
% rather than embedded $SB49/$SB41 blocks (DeepSolo, Wirewalker) - defined
% unconditionally like the other path fields, whether or not it exists on
% disk for this deployment.
metadata.paths.ctd               = fullfile(yml.data_root, 'ctd');

%% Deployment info
metadata.fish_flag = yml.fish_flag;
metadata.PROCESS.latitude = yml.latitude;
% vehicle_name is optional (older setup.yml files predate it) - '' means
% "not declared", not "no vehicle".
metadata.vehicle_name = '';
if isfield(yml, 'vehicle_name')
    metadata.vehicle_name = yml.vehicle_name;
end

%% EFE sample rate - optional, defaults to the standard EFE board rate so
% existing setup.yml files don't need an edit to keep working.
metadata.PROCESS.Fs_epsi = 320;
if isfield(yml, 'afe') && isfield(yml.afe, 'sample_rate')
    metadata.PROCESS.Fs_epsi = yml.afe.sample_rate;
end

%% Spectral processing parameters (mod_scan_get_spectra.m) -
% optional, same defaults MOD_fish_lib's Acquisition/setup.yml templates used.
metadata.PROCESS.nfft = 1024;
metadata.PROCESS.dof = 3;
if isfield(yml, 'spectral')
    if isfield(yml.spectral, 'nfft')
        metadata.PROCESS.nfft = yml.spectral.nfft;
    end
    if isfield(yml.spectral, 'dof')
        metadata.PROCESS.dof = yml.spectral.dof;
    end
end

%% Profiling-direction detection parameters
% (mod_L1_detect_profiling_direction.m) - optional. Defaults sized
% for sparse, irregularly-sampled pressure records (e.g. DeepSolo's
% fallrise data, ~60-120 s between samples) - see that function's header
% for the reasoning behind lowpass_factor=2/gap_factor=5/buffer_bins=1.
% Namespaced under PROFILES (not PROCESS) to match the old
% Meta_Data.PROFILES.* convention from
% epsiProcess_get_profiles_from_PressureTimeseries.m, so a future full
% profile-picker port can extend this same setup.yml section.
metadata.PROFILES.lowpass_factor = 3;
metadata.PROFILES.gap_factor = 5;
metadata.PROFILES.buffer_bins = 1;
if isfield(yml, 'profile_detection')
    if isfield(yml.profile_detection, 'lowpass_factor')
        metadata.PROFILES.lowpass_factor = yml.profile_detection.lowpass_factor;
    end
    if isfield(yml.profile_detection, 'gap_factor')
        metadata.PROFILES.gap_factor = yml.profile_detection.gap_factor;
    end
    if isfield(yml.profile_detection, 'buffer_bins')
        metadata.PROFILES.buffer_bins = yml.profile_detection.buffer_bins;
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

%% AFE channel manifest - slot order comes explicitly from
% instrument_manifest.afe.channel_N keys, sorted numerically by N, rather
% than from yaml field order (which the old schema relied on and which
% YAML does not guarantee to preserve past single digits).
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
    alt_geom = yml.altimeter.(fish_flag_key);
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
