# Android 16 Cuttlefish Artifacts

Build from AOSP source (no pre-built GSI available):

```bash
repo init -u https://android.googlesource.com/platform/manifest -b <branch>
repo sync

source build/envsetup.sh
lunch aosp_cf_x86_64_only_phone-bp2a-userdebug
m
m hosttar        # produces cvd-host_package.tar.gz
m updatepackage  # produces aosp_cf_x86_64_only_phone-img.zip
```

After building, the artifacts can be found at:
- `out/host/linux-x86/cvd-host_package.tar.gz`
- `out/target/product/vsoc_x86_64_only/aosp_cf_x86_64_only_phone-img.zip`

Copy both files into this directory.
