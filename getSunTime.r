#!/usr/bin/Rscript

library(suncalc)

args <- commandArgs(trailingOnly = TRUE)
field <- if (length(args) > 0) args[1] else "sunset"

times <- getSunlightTimes(date = Sys.Date(), lat = 32.896244, lon = -117.242651, tz = "")
cat(format(times[[field]], '%Y-%m-%d %H:%M:%S %Z'))
