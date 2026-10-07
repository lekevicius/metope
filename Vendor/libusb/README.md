# libusb transport dependency

MetopeEngine implements MTP in Swift. libusb supplies USB discovery, claim/release, and synchronous bulk I/O only. No Go protocol runtime is bundled.

Vendored version: **1.0.30**, Apple Silicon, copied from the installed Homebrew build at `/opt/homebrew/Cellar/libusb/1.0.30`. The unmodified input dylib SHA-256 is `d4d61d9f4e5291e64c09783cb61bd1b4c67e202b514f40989504a5852f7560b9`. Its install name is changed to `@rpath/libusb-1.0.dylib` and it is ad-hoc signed. Dependencies are system frameworks/libraries only. The unmodified public header SHA-256 is `a61260ab145b051b86df2b0575956f01810190abe2c7df6aca831c33bdc8082c`.

License: LGPL 2.1 or later, reproduced in `../libusb-COPYING` and app acknowledgments. The shared library is replaceable; there is no library validation entitlement.

Source: https://github.com/libusb/libusb/tree/v1.0.30

To rebuild from the v1.0.30 release sources on the destination architecture:

```sh
./configure --disable-static --enable-shared
make
```

Copy the produced `libusb/.libs/libusb-1.0.0.dylib` into `Vendor/libusb/$(uname -m)/libusb-1.0.dylib`, set its ID with `install_name_tool -id @rpath/libusb-1.0.dylib`, then ad-hoc sign it. Replace the public header if changing versions. The app packaging script embeds this library and strips the development rpath.

Intel is not currently packaged or tested; provide a matching x86_64 library before attempting that build.
