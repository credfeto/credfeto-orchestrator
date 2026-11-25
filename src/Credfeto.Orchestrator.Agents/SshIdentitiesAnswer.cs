using System;

namespace Credfeto.Orchestrator.Agents;

// Judges an agent's reply to the identities request as ssh-add -l does (OpenSSH's ssh_fetch_identitylist, which reads
// every key with sshkey_from_blob): KEYS when ssh-add would list a key, NO_KEYS when it would fail. Any reply type but
// the identities answer is a failure (the agent's FAILURE codes included), as is a count of 0 or over 2048, a
// truncated key or comment, a comment with a NUL byte before its last byte, or a key ssh-add rejects. Bytes after the
// last key are ignored, as ssh-add ignores them. A key it cannot judge exactly as ssh-add would (any type but
// ssh-ed25519 and ssh-rsa, or an RSA key outside the plain shape ssh-keygen writes) throws AgentRefusedException.
public static class SshIdentitiesAnswer
{
    // The request and the most a reply may hold (MAX_AGENT_REPLY_LEN; a longer one fails unread)
    public const byte RequestIdentities = 11;
    public const uint MaxReplyLength = 256 * 1024;

    private const byte IDENTITIES_ANSWER = 12;
    private const uint MAX_IDENTITIES = 2048;

    public static SshKeyState Judge(ReadOnlySpan<byte> reply)
    {
        if (reply.IsEmpty || reply[0] != IDENTITIES_ANSWER)
        {
            return SshKeyState.NO_KEYS;
        }

        ReadOnlySpan<byte> entries = reply[1..];

        if (!SshWireReader.TryReadUInt32(data: ref entries, value: out uint count) || count is 0 or > MAX_IDENTITIES)
        {
            return SshKeyState.NO_KEYS;
        }

        for (uint key = 0; key < count; key++)
        {
            // ssh-add reads the key's blob and comment before it parses the blob
            if (
                !SshWireReader.TryReadString(data: ref entries, value: out ReadOnlySpan<byte> blob)
                || !SshWireReader.TryReadString(data: ref entries, value: out ReadOnlySpan<byte> comment)
                || !IsCString(comment)
                || !SshPublicKeyBlob.IsValid(blob)
            )
            {
                return SshKeyState.NO_KEYS;
            }
        }

        return SshKeyState.KEYS;
    }

    // sshbuf_get_cstring allows a NUL byte only as the string's last byte
    private static bool IsCString(ReadOnlySpan<byte> text)
    {
        int nul = text.IndexOf((byte)0);

        return nul < 0 || nul == text.Length - 1;
    }
}
