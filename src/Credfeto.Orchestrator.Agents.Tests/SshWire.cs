using System;
using System.Buffers.Binary;
using System.Linq;
using System.Text;

namespace Credfeto.Orchestrator.Agents.Tests;

// Builds ssh-agent replies for the tests: uint32s, strings, mpints and public key blobs in the ssh wire format
internal static class SshWire
{
    public const byte IdentitiesAnswer = 12;

    public static byte[] U32(uint value)
    {
        byte[] bytes = new byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32BigEndian(destination: bytes, value: value);

        return bytes;
    }

    public static byte[] Str(byte[] value)
    {
        return [.. U32((uint)value.Length), .. value];
    }

    public static byte[] Str(string value)
    {
        return Str(Encoding.UTF8.GetBytes(value));
    }

    // The bytes of one key entry: its blob and its comment
    public static byte[] Entry(byte[] blob, byte[] comment)
    {
        return [.. Str(blob), .. Str(comment)];
    }

    public static byte[] Entry(byte[] blob)
    {
        return Entry(blob: blob, comment: "c"u8.ToArray());
    }

    // An identities answer: the type, the count, then the entries as given (so a count can disagree with them)
    public static byte[] Answer(uint count, params byte[][] entries)
    {
        return [IdentitiesAnswer, .. U32(count), .. entries.SelectMany(entry => entry)];
    }

    public static byte[] Ed25519(int keyBytes = 32, string type = "ssh-ed25519")
    {
        return [.. Str(type), .. Str([.. Enumerable.Repeat(element: (byte)1, count: keyBytes)])];
    }

    // An RSA key with the exponent and a modulus of the given bits, top and bottom bits set
    public static byte[] Rsa(uint exponent, int modulusBits)
    {
        return [.. Str("ssh-rsa"), .. Mpint(Number(exponent)), .. Mpint(Modulus(modulusBits))];
    }

    public static byte[] Modulus(int bits)
    {
        byte[] magnitude = new byte[(bits + 7) / 8];
        magnitude[0] = (byte)(1 << ((bits - 1) % 8));
        magnitude[^1] |= 1;

        return magnitude;
    }

    public static byte[] Number(uint value)
    {
        byte[] bytes = U32(value);
        int first = Array.FindIndex(array: bytes, match: b => b != 0);

        return first < 0 ? [] : bytes[first..];
    }

    // A positive mpint: the magnitude, with a zero byte in front when its top bit is set
    public static byte[] Mpint(byte[] magnitude)
    {
        return magnitude.Length > 0 && (magnitude[0] & 0x80) != 0 ? Str([0, .. magnitude]) : Str(magnitude);
    }
}
