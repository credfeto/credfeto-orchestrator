using System;
using System.Buffers.Binary;

namespace Credfeto.Orchestrator.Agents;

// Reads the ssh wire format as OpenSSH's sshbuf does: a uint32 is four big-endian bytes, and a string is a uint32
// length then that many bytes. Each read takes what it read off the front of data; a read past the end fails and
// leaves data as it was.
internal static class SshWireReader
{
    public static bool TryReadUInt32(ref ReadOnlySpan<byte> data, out uint value)
    {
        if (!BinaryPrimitives.TryReadUInt32BigEndian(source: data, value: out value))
        {
            return false;
        }

        data = data[sizeof(uint)..];

        return true;
    }

    public static bool TryReadString(ref ReadOnlySpan<byte> data, out ReadOnlySpan<byte> value)
    {
        if (
            !BinaryPrimitives.TryReadUInt32BigEndian(source: data, value: out uint length)
            || length > (uint)(data.Length - sizeof(uint))
        )
        {
            value = default;

            return false;
        }

        value = data.Slice(start: sizeof(uint), length: (int)length);
        data = data[(sizeof(uint) + (int)length)..];

        return true;
    }
}
