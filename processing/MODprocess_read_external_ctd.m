function ctd = MODprocess_read_external_ctd(metadata)
% MODprocess_read_external_ctd        Part of MOD_fish_processing
%
% ctd = MODprocess_read_external_ctd(metadata)
%
% DESCRIPTION
%   Reads and normalizes a deployment's independent CTD file, for vehicles
%   whose CTD data doesn't arrive as $SB49/$SB41 blocks in the .modraw/L0
%   stream (DeepSolo, Wirewalker - see MODsetup_read_yaml.m's vehicle_name
%   field). Returns the CTD data for the whole deployment as one struct;
%   MODprocess_all_L0_to_L1.m slices it into per-L0-file chunks by dnum
%   before handing each chunk to MODprocess_single_L0_to_L1.m.
%
%   DeepSolo: implemented, against ctd/DeepSoloFallrise.mat - a sparse
%   (~60-120 s spacing), P-only fall/rise pressure timeseries (the float's
%   own pressure sensor, sampled continuously through the whole dive/climb
%   cycle - NOT the pressure-binned up/down CTD profiles DeepSolo also
%   reports, which carry T/S but aren't time-aligned to this timebase and
%   aren't read here). No T/C/S in this file at all - see OUTPUTS.
%
%   Wirewalker: NOT YET IMPLEMENTED - no sample file has been available to
%   build/test a real reader against (see docs/workflow/L0_to_L1_conversion.md).
%
% INPUTS
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses
%              metadata.paths.ctd (data_root/ctd/) and metadata.vehicle_name
%              (to pick which vendor's file format to expect)
%
% OUTPUTS
%   ctd - struct with fields dnum and P always; T, C, (S) only when the
%         source vehicle's file actually reports them:
%           dnum - MATLAB datenum (the master clock; time_s and any other
%                  derived timing is computed from this, not read from
%                  the file)
%           P    - pressure [dbar]
%           T    - temperature [degC, IPTS-68] - NOT present for DeepSolo
%                  (see DESCRIPTION); MODprocess_single_L0_to_L1.m's
%                  process_ctd_fields tolerates this and skips S/th/sgth
%                  derivation when T/C are absent
%           C    - conductivity [S/m] - NOT mS/cm; see process_ctd_fields's
%                  ctd.C*10./c3515 ratio in MODprocess_single_L0_to_L1.m,
%                  which requires C in S/m to match the c3515 = 42.914
%                  mS/cm standard (1 S/m = 10 mS/cm). NOT present for
%                  DeepSolo.
%           S    - salinity [psu, PSS-78] - optional even when T/C are
%                  present; if the source file doesn't report it,
%                  MODprocess_single_L0_to_L1.m derives it the same way the
%                  SBE49 path does (sw_salt on the C/T/P above)
%         DeepSolo's fallrise file has no fixed sample rate (irregular,
%         ~60-120 s) - chunking works off dnum spacing directly rather than
%         an assumed rate.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m - only when metadata.vehicle_name is a
%   vehicle with an independent CTD file AND metadata.paths.ctd exists on
%   disk. Absence of the folder is treated as "no CTD for this deployment
%   yet" (not an error) one level up - this function is only reached once
%   there's actually a folder to read.
%
% CALLS
%   (none yet for DeepSolo - direct load() of a .mat file. Wirewalker will
%   call a vendor-specific parser, e.g. an RBR .rsk reader, once a real
%   file is available to build one against)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

switch lower(metadata.vehicle_name)
    case 'deepsolo'
        ctd = read_deepsolo_fallrise(metadata.paths.ctd);
    otherwise
        error('MODprocess_read_external_ctd:notImplemented', ...
            ['No external CTD reader implemented yet for vehicle "%s". ' ...
             'metadata.paths.ctd (%s) exists, but nothing here knows how to ' ...
             'parse its contents into the dnum/P(/T/C/S) struct this pipeline expects.'], ...
            metadata.vehicle_name, metadata.paths.ctd);
end

end %end function

%% DeepSolo fallrise pressure timeseries: ctd/DeepSoloFallrise.mat, a
% struct (top-level variable named DeepSoloFallrise) with only dnum/P - the
% float's continuous pressure record through each dive/climb, not the
% separate pressure-binned CTD profiles. No T/C/S to read.
function ctd = read_deepsolo_fallrise(ctd_dir)
fallrise_file = fullfile(ctd_dir, 'DeepSoloFallrise.mat');
if ~exist(fallrise_file, 'file')
    error('MODprocess_read_external_ctd:fileNotFound', ...
        'Expected DeepSolo fallrise pressure file not found: %s', fallrise_file);
end
s = load(fallrise_file);
raw = s.DeepSoloFallrise;

ctd.dnum = raw.dnum(:);
ctd.P    = raw.P(:);
end
