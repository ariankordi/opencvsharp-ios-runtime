// Lists the entry points of every P/Invoke in a managed assembly that targets a given native module.
// Usage: dotnet run pinvokes.cs -- <assembly.dll> <moduleName>
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;

if (args.Length != 2)
{
    Console.Error.WriteLine("usage: pinvokes.cs <assembly.dll> <moduleName>");
    return 1;
}

using var peReader = new PEReader(File.OpenRead(args[0]));
var metadata = peReader.GetMetadataReader();
foreach (var handle in metadata.MethodDefinitions)
{
    var import = metadata.GetMethodDefinition(handle).GetImport();
    // Methods without a ModuleRef are not P/Invokes.
    if (import.Module.IsNil)
        continue;
    if (metadata.GetString(metadata.GetModuleReference(import.Module).Name) != args[1])
        continue;
    Console.WriteLine(metadata.GetString(import.Name));
}
return 0;
