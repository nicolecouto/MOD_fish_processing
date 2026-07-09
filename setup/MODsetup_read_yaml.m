function metadata = MODsetup_read_yaml(setup_yml)
% MODsetup_read_yaml        Part of MOD_fish_processing
%
% metadata = MODsetup_read_yaml(setup_yml)
%
% DESCRIPTION
%   Reads a deployment's setup.yml and returns a metadata struct with
%   paths derived fresh from setup.yml's data_root (never saved), the AFE
%   channel manifest, CTD calibration coefficients, and altimeter
%   geometry. Only resolves what the L0->L1 step currently uses - grows
%   as later pipeline steps need more (see PLAN.md Section 2).
%
%   Saves metadata.mat into meta/ alongside setup.yml, with metadata.paths
%   stripped out first - metadata.mat is a portable deployment record;
%   paths are machine-specific and always re-derived from setup.yml's
%   data_root on the next call.
%
% INPUTS
%   setup_yml - full path to a deployment's setup.yml
%
% OUTPUTS
%   metadata  - struct with fields:
%     paths.data_root, .raw, .L0, .L1, .meta, .calibrations_root
%     fish_flag                    - 'FCTD' or 'EPSI', from setup.yml
%     PROCESS.latitude             - for ctd.z when no GPS fix
%     PROCESS.channels             - AFE channel names in ADC slot order,
%                                     e.g. {'t1','t2','s1','s2','a1','a2','a3'}
%     AFE.(channel).full_range     - volts, for counts->volts conversion
%     AFE.(channel).ADCconf        - 'Bipolar' or 'Unipolar'
%     AFE.(channel).type           - 'shear', 'fpo7', 'acc', etc., from setup.yml
%     CTD.name                     - e.g. 'S49'
%     CTD.SN                       - serial number string
%     CTD.sample_per_record
%     CTD.cal                      - SBE calibration coefficients, read
%                                     from calibrations_root/SBECAL/<SN>.CAL
%                                     ([] if sn.ctd is empty)
%     GEOMETRY.alt_angle_deg, .alt_dist_from_crashguard_ft,
%              .alt_probe_dist_from_crashguard_in
%                                   - altimeter.fctd or altimeter.epsi
%                                     block, selected by fish_flag
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   toolbox/YAMLMatlab_0.4.3/ReadYaml.m
%   (local subfunction: read_sbe_cal)
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

%% Deployment info
metadata.fish_flag = yml.fish_flag;
metadata.PROCESS.latitude = yml.latitude;

%% AFE channel manifest - fieldnames() preserves the yaml's declared order,
% which is the ADC slot order the SOM firmware samples in.
channel_names = fieldnames(yml.afe.channels);
metadata.PROCESS.channels = channel_names;
for iC = 1:numel(channel_names)
    ch = channel_names{iC};
    metadata.AFE.(ch).full_range = yml.afe.channels.(ch).full_range;
    metadata.AFE.(ch).ADCconf    = yml.afe.channels.(ch).ADCconf;
    metadata.AFE.(ch).type       = yml.afe.channels.(ch).type;
end

%% CTD
metadata.CTD.name = yml.ctd.type;
metadata.CTD.sample_per_record = yml.ctd.sample_per_record;
metadata.CTD.SN = yml.sn.ctd;
if isempty(yml.sn.ctd)
    metadata.CTD.cal = [];
else
    cal_file = fullfile(yml.calibrations_root, 'SBECAL', [yml.sn.ctd '.CAL']);
    metadata.CTD.cal = read_sbe_cal(cal_file);
end

%% Altimeter geometry - fish_flag picks which yaml block applies
switch lower(yml.fish_flag)
    case 'fctd'
        alt_geom = yml.altimeter.fctd;
    case 'epsi'
        alt_geom = yml.altimeter.epsi;
    otherwise
        error('MODsetup_read_yaml:unknownFishFlag', ...
            'fish_flag "%s" is neither FCTD nor EPSI - cannot pick an altimeter geometry block.', yml.fish_flag);
end
metadata.GEOMETRY.alt_angle_deg                    = alt_geom.angle_deg;
metadata.GEOMETRY.alt_dist_from_crashguard_ft       = alt_geom.dist_from_crashguard_ft;
metadata.GEOMETRY.alt_probe_dist_from_crashguard_in = alt_geom.probe_dist_from_crashguard_in;

%% Save metadata.mat (portable - no paths)
metadata_to_save = rmfield(metadata, 'paths');
save(fullfile(meta_dir, 'metadata.mat'), '-struct', 'metadata_to_save');

end %end function

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
