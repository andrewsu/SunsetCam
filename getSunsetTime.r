#!/usr/bin/Rscript

library(suncalc)
#cat(getSunlightTimes(date = Sys.Date(), lat = 32.896244, lon = -117.242651, tz = "")$sunset)
#cat(format((getSunlightTimes(date = Sys.Date(), lat = 32.896244, lon = -117.242651, tz = "")$sunset),'%Y%m%d%H%M'))
cat(format((getSunlightTimes(date = Sys.Date(), lat = 32.896244, lon = -117.242651, tz = "")$sunset),'%Y-%m-%d %H:%M:%S %Z'))
