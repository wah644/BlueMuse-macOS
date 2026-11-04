// Only the unused GetBits(IBuffer) adapter needs these Windows types. All numeric
// conversions and decoders are compiled unchanged from BlueMuse.App.
namespace Windows.Storage.Streams { public interface IBuffer { uint Length { get; } byte GetByte(uint index); } }
namespace System.Runtime.InteropServices.WindowsRuntime { public static class PortableBufferMarker {} }
