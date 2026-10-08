# OpenCvSharp4 iOS Runtime

Runtime package meant to be used for iOS compatibility to use OpenCvSharp in cross-platform .NET MAUI apps.

For other platforms including Android, see [sdcb/opencvsharp-mini-runtime](https://github.com/sdcb/opencvsharp-mini-runtime).

Only "core" modules are included: `core,imgproc,imgcodecs`. See [build-ios.sh](opencvsharp-mini-runtime/eng/ios/build-ios.sh) for details. Feel free to make an issue or PR if you need more.

## Usage

This package can be found on NuGet: [ariankordi.OpenCvSharp4.runtime.ios](https://www.nuget.org/packages/ariankordi.OpenCvSharp4.runtime.ios)

A csproj using OpenCvSharp4 on all major MAUI platforms can be structured like so:

```xml
    <!-- OpenCvSharp4 managed assembly. -->
    <PackageReference Include="OpenCvSharp4" Version="4.13.0.20260627" />
    <!-- Runtime: iOS -->
    <ItemGroup Condition="$(TargetFramework.Contains('-ios'))">
      <PackageReference Include="ariankordi.OpenCvSharp4.iOS" Version="4.13.0.20261008" />
    </ItemGroup>
    <!-- Runtime: Android -->
    <ItemGroup Condition="$(TargetFramework.Contains('-android'))">
      <PackageReference Include="Sdcb.OpenCvSharp4.mini.runtime.android-arm64" Version="4.13.0.45" />
      <PackageReference Include="Sdcb.OpenCvSharp4.mini.runtime.android-x64" Version="4.13.0.45" />
    </ItemGroup>
    <!-- Runtime: Windows -->
    <ItemGroup Condition="$(TargetFramework.Contains('-windows'))">
      <PackageReference Include="OpenCvSharp4.runtime.win" Version="4.13.0.20260627" />
    </ItemGroup>
```

**NOTE:** Only the arm64 Simulator slice is built, and x64 Simulator is not supported.

If this leads to a failure in your project build, please make an issue or PR.

## Acknowledgements
* This repo is almost entirely made by Claude Code. ~~sorry~~
* [shimat/OpenCvSharp](https://github.com/shimat/opencvsharp/tree/4.13.0.20260627)
* [sdcb/opencvsharp-mini-runtime](https://github.com/sdcb/opencvsharp-mini-runtime) (this repo is a fork of that)