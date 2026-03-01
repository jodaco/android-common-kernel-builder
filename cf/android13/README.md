# Android 13 Cuttlefish Artifacts

Download from Google CI:
https://ci.android.com/builds/branches/aosp-android13-gsi/grid

Pick a recent green build and download:
- `aosp_cf_x86_64_phone-img-*.zip`
- `cvd-host_package.tar.gz`

Place them in the appropriate subdirectory:
- `510/` — for android13-5.10 kernel tags
- `515/` — for android13-5.15 kernel tags

It is unclear if each version require different host packages, but we
treated them as requiring separate artifacts per kernel version, since
Google went through the trouble to build a variant with 510 in the name.
