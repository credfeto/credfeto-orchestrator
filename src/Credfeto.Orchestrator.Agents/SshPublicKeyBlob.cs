using System;

namespace Credfeto.Orchestrator.Agents;

// Judges one public key blob as OpenSSH's sshkey_from_blob does, for the two key types it judges exactly: true when
// ssh-add would accept the key, false when it would reject it. Any other type, an RSA key whose numbers are not in
// the plain form ssh-keygen writes, or an RSA modulus outside 1024 to 16384 bits throws AgentRefusedException.
internal static class SshPublicKeyBlob
{
    private const int ED25519_PUBLIC_KEY_BYTES = 32;
    private const int RSA_MAX_EXPONENT_BYTES = 4;
    private const int RSA_MIN_MODULUS_BITS = 1024;
    private const int RSA_MAX_MODULUS_BITS = 16384;

    public static bool IsValid(ReadOnlySpan<byte> blob)
    {
        ReadOnlySpan<byte> rest = blob;

        if (!SshWireReader.TryReadString(data: ref rest, value: out ReadOnlySpan<byte> type))
        {
            return false;
        }

        if (type.SequenceEqual("ssh-ed25519"u8))
        {
            // Any 32 bytes are a key, and nothing may follow them
            return SshWireReader.TryReadString(data: ref rest, value: out ReadOnlySpan<byte> key)
                && key.Length == ED25519_PUBLIC_KEY_BYTES
                && rest.IsEmpty;
        }

        if (type.SequenceEqual("ssh-rsa"u8))
        {
            return IsValidRsa(rest);
        }

        throw new AgentRefusedException("the agent holds a key of a type the tool does not judge");
    }

    // The exponent then the modulus, each an mpint; ssh-add rejects a truncated number or anything after the modulus
    // whatever the numbers hold
    private static bool IsValidRsa(ReadOnlySpan<byte> numbers)
    {
        if (
            !SshWireReader.TryReadString(data: ref numbers, value: out ReadOnlySpan<byte> exponent)
            || !SshWireReader.TryReadString(data: ref numbers, value: out ReadOnlySpan<byte> modulus)
            || !numbers.IsEmpty
        )
        {
            return false;
        }

        ReadOnlySpan<byte> e = Magnitude(exponent);
        ReadOnlySpan<byte> n = Magnitude(modulus);
        int bits = BitLength(n);

        if (
            e.Length > RSA_MAX_EXPONENT_BYTES
            || !IsOdd(e)
            || e.Length == 1 && e[0] < 3
            || !IsOdd(n)
            || bits is < RSA_MIN_MODULUS_BITS or > RSA_MAX_MODULUS_BITS
        )
        {
            throw new AgentRefusedException("the agent holds an RSA key the tool does not judge");
        }

        return true;
    }

    // A positive mpint's bytes without the one leading zero byte its top bit needs; anything else (empty, negative,
    // or a leading zero it does not need) is not the form ssh-keygen writes
    private static ReadOnlySpan<byte> Magnitude(ReadOnlySpan<byte> mpint)
    {
        if (mpint.IsEmpty || (mpint[0] & 0x80) != 0)
        {
            throw new AgentRefusedException("the agent holds an RSA key with a number the tool does not judge");
        }

        if (mpint[0] != 0)
        {
            return mpint;
        }

        if (mpint.Length < 2 || (mpint[1] & 0x80) == 0)
        {
            throw new AgentRefusedException("the agent holds an RSA key with a number the tool does not judge");
        }

        return mpint[1..];
    }

    private static bool IsOdd(ReadOnlySpan<byte> magnitude)
    {
        return (magnitude[^1] & 1) == 1;
    }

    private static int BitLength(ReadOnlySpan<byte> magnitude)
    {
        int top = magnitude[0];
        int bits = (magnitude.Length - 1) * 8;

        while (top != 0)
        {
            bits++;
            top >>= 1;
        }

        return bits;
    }
}
