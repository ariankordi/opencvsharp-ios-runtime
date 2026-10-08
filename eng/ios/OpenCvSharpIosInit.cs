// Runtime glue for using stock (unmodified) OpenCvSharp4 on iOS with a statically linked
// OpenCvSharpExtern. Compiled into the app by OpenCvSharpIosRuntime.targets, never into the
// managed OpenCvSharp assembly.
//
// Resolver approach follows dotnet/macios#25008 (ONNX Runtime on iOS):
// https://github.com/dotnet/macios/issues/25008
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using OpenCvSharp;
using OpenCvSharp.Internal;

namespace OpenCvSharpIosRuntime;

internal static class OpenCvSharpIosInit
{
    /// <summary>
    /// Runs when the app assembly loads, which is before any OpenCvSharp P/Invoke can execute.
    /// </summary>
    [ModuleInitializer]
    internal static void Initialize()
    {
        // Static linking means there is no OpenCvSharpExtern dylib to load, so resolve the module name
        // to the main program, where the xcframework's symbols live (kept alive by ReferenceNativeSymbol).
        NativeLibrary.SetDllImportResolver(typeof(Mat).Assembly, ResolveOpenCvSharpExtern);

        // Upstream treats iOS as "not Unix", so NativeMethods' static constructor registers
        // ErrorHandlerThrowException, which throws a managed exception through C++ frames. That only works
        // on Windows. Touching RegisterExceptionCallback runs the static constructor first, then replaces the
        // throwing handler with the storing handler that OpenCvSharp uses on Linux and macOS.
        ExceptionHandler.RegisterExceptionCallback();
    }

    private static IntPtr ResolveOpenCvSharpExtern(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        return libraryName == NativeMethods.DllExtern ? NativeLibrary.GetMainProgramHandle() : IntPtr.Zero;
    }
}
