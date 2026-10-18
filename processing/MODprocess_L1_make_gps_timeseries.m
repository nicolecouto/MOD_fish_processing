function GpsTimeseries = MODprocess_L1_make_gps_timeseries(cache)
% MODprocess_L1_make_gps_timeseries        Part of MOD_fish_processing
%
% GpsTimeseries = MODprocess_L1_make_gps_timeseries(cache)
%
% DESCRIPTION
%   Concatenates every L1 file's GPS fixes (gps.dnum/.latitude/.longitude,
%   kept in the per-file L1 cache, MODprocess_L1_update_file_cache.m) into
%   one deployment-length track, for the realtime monitor's map.
%
%   Pure - no file reading or writing. The caller
%   (MODprocess_all_L0_to_L1.m) saves the result to
%   meta/gps_time_series.mat.
%
% INPUTS
%   cache - from MODprocess_L1_update_file_cache.m (one element per L1
%           file, with .gps_dnum/.gps_lat/.gps_lon). Files with no GPS
%           (empty .gps_dnum) are skipped.
%
% OUTPUTS
%   GpsTimeseries - struct with fields:
%       dnum      - time of each fix [datenum], sorted, each time once
%                   (fixes with no time or no position are left out)
%       latitude  - [decimal degrees N]
%       longitude - [decimal degrees E]
%     Empty (dnum = [], latitude = [], longitude = []) if no L1 file has GPS.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   (none - the cache comes from MODprocess_L1_update_file_cache.m)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

dnum = vertcat(cache.gps_dnum);
lat  = vertcat(cache.gps_lat);
lon  = vertcat(cache.gps_lon);
keep = isfinite(dnum) & isfinite(lat) & isfinite(lon);
% two L1 files can hold the same fix (a raw file copied under another
% name): each time once, in time order
[dnum, first] = unique(dnum(keep), 'first');
lat = lat(keep);
lon = lon(keep);
GpsTimeseries.dnum      = dnum;
GpsTimeseries.latitude  = lat(first);
GpsTimeseries.longitude = lon(first);

end %end function
