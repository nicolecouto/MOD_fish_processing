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
%   NOT YET IMPLEMENTED for any specific instrument - no sample file has
%   been available to build/test a real reader against (see
%   docs/workflow/L0_to_L1_conversion.md). This stub exists so the
%   plumbing in MODprocess_all_L0_to_L1.m / MODprocess_single_L0_to_L1.m
%   can be wired up and tested (with no ctd/ folder present, which is
%   the common case today) ahead of a real parser landing here.
%
% INPUTS
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses
%              metadata.paths.ctd (data_root/ctd/) and metadata.vehicle_name
%              (to pick which vendor's file format to expect, once that
%              exists)
%
% OUTPUTS
%   ctd - struct with (at minimum) fields dnum, P, T, C, and optionally S:
%           dnum - MATLAB datenum (the master clock; time_s and any other
%                  derived timing is computed from this, not read from
%                  the file)
%           P    - pressure [dbar]
%           T    - temperature [degC, IPTS-68]
%           C    - conductivity [S/m] - NOT mS/cm; see calibrate_ctd's
%                  ctd.C*10./c3515 ratio in MODprocess_single_L0_to_L1.m,
%                  which requires C in S/m to match the c3515 = 42.914
%                  mS/cm standard (1 S/m = 10 mS/cm)
%           S    - salinity [psu, PSS-78] - optional; if the source file
%                  doesn't report it, MODprocess_single_L0_to_L1.m derives
%                  it the same way the SBE49 path does (sw_salt on the C/T/P
%                  above)
%         Expected sample rate ~16 Hz, sometimes 8 Hz - not enforced here,
%         since chunking works off dnum spacing directly rather than an
%         assumed rate.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m - only when metadata.vehicle_name is a
%   vehicle with an independent CTD file AND metadata.paths.ctd exists on
%   disk. Absence of the folder is treated as "no CTD for this deployment
%   yet" (not an error) one level up - this function is only reached once
%   there's actually a folder to read.
%
% CALLS
%   (none yet - will call a vendor-specific parser, e.g. an RBR .rsk
%   reader, once a real file is available to build one against)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

error('MODprocess_read_external_ctd:notImplemented', ...
    ['No external CTD reader implemented yet for vehicle "%s". ' ...
     'metadata.paths.ctd (%s) exists, but nothing here knows how to ' ...
     'parse its contents into the dnum/P/T/C/S struct this pipeline expects.'], ...
    metadata.vehicle_name, metadata.paths.ctd);

end %end function
