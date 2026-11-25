using System.Text;

namespace Credfeto.Orchestrator.Discovery;

public static class UriComponent
{
    private const string HEX = "0123456789ABCDEF";

    private static readonly Encoding Utf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    // jq 1.7+ @uri: the unreserved characters A-Z, a-z, 0-9, "-", "_", "." and "~" are kept, every other UTF-8 byte is
    // written as %XX in upper-case hex
    public static string Encode(string value)
    {
        StringBuilder builder = new();

        foreach (byte octet in Utf8.GetBytes(value))
        {
            if (IsUnreserved(octet))
            {
                builder.Append((char)octet);
            }
            else
            {
                builder.Append('%').Append(HEX[octet >> 4]).Append(HEX[octet & 0x0F]);
            }
        }

        return builder.ToString();
    }

    private static bool IsUnreserved(byte octet)
    {
        return octet
            is >= (byte)'A'
                and <= (byte)'Z'
                or >= (byte)'a'
                and <= (byte)'z'
                or >= (byte)'0'
                and <= (byte)'9'
                or (byte)'-'
                or (byte)'_'
                or (byte)'.'
                or (byte)'~';
    }
}
