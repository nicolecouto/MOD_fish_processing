function dof = mod_scan_dof(fft_segments_per_scan)
% mod_scan_dof        Part of MOD_fish_processing
%
% dof = mod_scan_dof(fft_segments_per_scan)
%
% DESCRIPTION
%   Degrees of freedom of a Welch-averaged spectrum built from
%   fft_segments_per_scan segments overlapping by 50% (the hardcoded
%   overlap - see mod_scan_get_spectra.m's FFT_OVERLAP constant) -
%   Nuttall's (1971) correction for a Hamming-windowed, 50%-overlapped
%   periodogram average:
%     dof = 1.9 * fft_segments_per_scan
%   Matches Rockland ODAS's get_diss_odas.m: dof_spec = 1.9*num_of_ffts
%   (their comment: "This is a constant value based on the diss_length
%   and fft_length").
%
%   dof is a DERIVED quantity, not a free input - fft_segments_per_scan
%   (MODsetup_metadata_field_registry.m) is the one independently-tunable
%   value it depends on; this function is the single place that turns it
%   into a dof number, so mod_L2_tile_scans.m's provenance field and
%   mod_scan_calc_chi_mle.m's MLE weighting can't disagree on what dof
%   actually is. Rockland does the same thing (dof_spec is an output of
%   get_diss_odas.m, not an input field) - see the design discussion in
%   PLAN.md's session log.
%
%   The 1.9 factor is only valid at exactly 50% overlap (Nuttall's
%   derivation) - that's why overlap is hardcoded rather than exposed as
%   a tunable fraction. See docs/concepts/spectral_windowing.md.
%
% INPUTS
%   fft_segments_per_scan - number of Welch segments per scan
%                            (metadata.PROCESS.fft_segments_per_scan)
%
% OUTPUTS
%   dof - degrees of freedom of the resulting Welch-averaged spectrum
%
% CALLED BY
%   mod_L2_tile_scans.m, mod_scan_calc_chi_mle.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

dof = 1.9 * fft_segments_per_scan;

end %end function
