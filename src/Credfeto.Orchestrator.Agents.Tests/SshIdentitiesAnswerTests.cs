using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class SshIdentitiesAnswerTests : TestBase
{
    [Theory]
    [InlineData("one ed25519 key")]
    [InlineData("an empty comment")]
    [InlineData("a comment ending in a NUL byte")]
    [InlineData("bytes after the last key")]
    [InlineData("a count of 1 with two keys")]
    [InlineData("an RSA 1024 key")]
    [InlineData("an RSA 16384 key")]
    [InlineData("an RSA key with exponent 3")]
    [InlineData("an RSA key with a four-byte exponent")]
    [InlineData("an RSA key and an ed25519 key")]
    public static void AnAnswerWithAKeySshAddReadsHasKeys(string reply)
    {
        Assert.Equal(expected: SshKeyState.KEYS, actual: SshIdentitiesAnswer.Judge(Reply(reply)));
    }

    [Theory]
    [InlineData("an empty reply")]
    [InlineData("FAILURE 5")]
    [InlineData("FAILURE 30")]
    [InlineData("FAILURE 102")]
    [InlineData("the request type")]
    [InlineData("no count")]
    [InlineData("a short count")]
    [InlineData("a count of 0")]
    [InlineData("a count of 2049")]
    [InlineData("a count of 2048 and no keys")]
    [InlineData("no comment")]
    [InlineData("a truncated comment")]
    [InlineData("a comment with a NUL byte inside")]
    [InlineData("a comment that is only two NUL bytes")]
    [InlineData("an empty blob")]
    [InlineData("a cut-short type")]
    [InlineData("an ed25519 key of 31 bytes")]
    [InlineData("an ed25519 key of 33 bytes")]
    [InlineData("an ed25519 key with no key")]
    [InlineData("an ed25519 key with a byte after it")]
    [InlineData("a count of 2 with one key")]
    [InlineData("a good key, then a bad one")]
    [InlineData("an RSA key with a byte after the modulus")]
    [InlineData("an RSA key with no modulus")]
    [InlineData("an RSA key with no numbers")]
    [InlineData("a bad key, then an ECDSA key")]
    public static void AnyOtherReplyHasNoKeys(string reply)
    {
        Assert.Equal(expected: SshKeyState.NO_KEYS, actual: SshIdentitiesAnswer.Judge(Reply(reply)));
    }

    [Theory]
    [InlineData("an ECDSA key")]
    [InlineData("an unknown type")]
    [InlineData("a type ending in a NUL byte")]
    [InlineData("an RSA key of 1023 bits")]
    [InlineData("an RSA key of 16385 bits")]
    [InlineData("an RSA key with an even exponent")]
    [InlineData("an RSA key with exponent 1")]
    [InlineData("an RSA key with a five-byte exponent")]
    [InlineData("an RSA key with an empty exponent")]
    [InlineData("an RSA key with a needless leading zero")]
    [InlineData("an RSA key with a lone zero byte")]
    [InlineData("an RSA key with a negative modulus")]
    [InlineData("an RSA key with an even modulus")]
    [InlineData("an ECDSA key, then a bad key")]
    public static void AKeyItCannotJudgeIsRefused(string reply)
    {
        byte[] bytes = Reply(reply);

        Assert.Throws<AgentRefusedException>(() => SshIdentitiesAnswer.Judge(bytes));
    }

    private static byte[] Reply(string name)
    {
        return Accepted(name)
            ?? FramingFailures(name)
            ?? KeyFailures(name)
            ?? Refused(name)
            ?? RefusedRsa(name)
            ?? throw new ArgumentOutOfRangeException(
                paramName: nameof(name),
                actualValue: name,
                message: "No such reply"
            );
    }

    private static byte[]? Accepted(string name)
    {
        byte[] ed25519 = SshWire.Ed25519();

        return name switch
        {
            "one ed25519 key" => SshWire.Answer(1, SshWire.Entry(ed25519)),
            "an empty comment" => SshWire.Answer(1, SshWire.Entry(blob: ed25519, comment: [])),
            "a comment ending in a NUL byte" => SshWire.Answer(1, SshWire.Entry(blob: ed25519, comment: [0x61, 0])),
            "bytes after the last key" => [.. SshWire.Answer(1, SshWire.Entry(ed25519)), 0x6a, 0x75, 0x6e, 0x6b],
            "a count of 1 with two keys" => SshWire.Answer(1, SshWire.Entry(ed25519), SshWire.Entry(ed25519)),
            "an RSA 1024 key" => SshWire.Answer(1, SshWire.Entry(SshWire.Rsa(exponent: 65537, modulusBits: 1024))),
            "an RSA 16384 key" => SshWire.Answer(1, SshWire.Entry(SshWire.Rsa(exponent: 65537, modulusBits: 16384))),
            "an RSA key with exponent 3" => SshWire.Answer(
                1,
                SshWire.Entry(SshWire.Rsa(exponent: 3, modulusBits: 2048))
            ),
            "an RSA key with a four-byte exponent" => SshWire.Answer(
                1,
                SshWire.Entry(SshWire.Rsa(exponent: 0x7fffffff, modulusBits: 2048))
            ),
            "an RSA key and an ed25519 key" => SshWire.Answer(
                2,
                SshWire.Entry(SshWire.Rsa(exponent: 65537, modulusBits: 2048)),
                SshWire.Entry(ed25519)
            ),
            _ => null,
        };
    }

    private static byte[]? FramingFailures(string name)
    {
        byte[] ed25519 = SshWire.Ed25519();

        return name switch
        {
            "an empty reply" => [],
            "FAILURE 5" => [5],
            "FAILURE 30" => [30],
            "FAILURE 102" => [102],
            "the request type" => [11, 0, 0, 0, 0],
            "no count" => [SshWire.IdentitiesAnswer],
            "a short count" => [SshWire.IdentitiesAnswer, 0, 0, 0],
            "a count of 0" => SshWire.Answer(0),
            "a count of 2049" => SshWire.Answer(2049),
            "a count of 2048 and no keys" => SshWire.Answer(2048),
            "no comment" => SshWire.Answer(1, SshWire.Str(ed25519)),
            "a truncated comment" => SshWire.Answer(1, [.. SshWire.Str(ed25519), 0, 0, 0, 2, 0x61]),
            _ => null,
        };
    }

    private static byte[]? KeyFailures(string name)
    {
        byte[] ed25519 = SshWire.Ed25519();
        byte[] ecdsa = Ecdsa();

        return name switch
        {
            "a comment with a NUL byte inside" => SshWire.Answer(
                1,
                SshWire.Entry(blob: ed25519, comment: [0x61, 0, 0x62])
            ),
            "a comment that is only two NUL bytes" => SshWire.Answer(1, SshWire.Entry(blob: ed25519, comment: [0, 0])),
            "an empty blob" => SshWire.Answer(1, SshWire.Entry([])),
            "a cut-short type" => SshWire.Answer(1, SshWire.Entry([0, 0, 0, 11, 0x73, 0x73, 0x68])),
            "an ed25519 key of 31 bytes" => SshWire.Answer(1, SshWire.Entry(SshWire.Ed25519(keyBytes: 31))),
            "an ed25519 key of 33 bytes" => SshWire.Answer(1, SshWire.Entry(SshWire.Ed25519(keyBytes: 33))),
            "an ed25519 key with no key" => SshWire.Answer(1, SshWire.Entry(SshWire.Str("ssh-ed25519"))),
            "an ed25519 key with a byte after it" => SshWire.Answer(1, SshWire.Entry([.. ed25519, 0x78])),
            "a count of 2 with one key" => SshWire.Answer(2, SshWire.Entry(ed25519)),
            "a good key, then a bad one" => SshWire.Answer(
                2,
                SshWire.Entry(ed25519),
                SshWire.Entry(SshWire.Ed25519(keyBytes: 31))
            ),
            "an RSA key with a byte after the modulus" => SshWire.Answer(
                1,
                SshWire.Entry([.. SshWire.Rsa(exponent: 65537, modulusBits: 2048), 0x78])
            ),
            "an RSA key with no modulus" => SshWire.Answer(
                1,
                SshWire.Entry([.. SshWire.Str("ssh-rsa"), .. SshWire.Mpint(SshWire.Number(65537))])
            ),
            "an RSA key with no numbers" => SshWire.Answer(1, SshWire.Entry(SshWire.Str("ssh-rsa"))),
            "a bad key, then an ECDSA key" => SshWire.Answer(
                2,
                SshWire.Entry(SshWire.Ed25519(keyBytes: 0)),
                SshWire.Entry(ecdsa)
            ),
            _ => null,
        };
    }

    private static byte[]? Refused(string name)
    {
        byte[] ecdsa = Ecdsa();

        return name switch
        {
            "an ECDSA key" => SshWire.Answer(1, SshWire.Entry(ecdsa)),
            "an unknown type" => SshWire.Answer(1, SshWire.Entry(SshWire.Ed25519(type: "unknown@example.com"))),
            "a type ending in a NUL byte" => SshWire.Answer(1, SshWire.Entry(SshWire.Ed25519(type: "ssh-ed25519\0"))),
            "an ECDSA key, then a bad key" => SshWire.Answer(
                2,
                SshWire.Entry(ecdsa),
                SshWire.Entry(SshWire.Ed25519(keyBytes: 0))
            ),
            _ => null,
        };
    }

    private static byte[]? RefusedRsa(string name)
    {
        byte[] modulus = SshWire.Mpint(SshWire.Modulus(2048));

        return name switch
        {
            "an RSA key of 1023 bits" => SshWire.Answer(
                1,
                SshWire.Entry(SshWire.Rsa(exponent: 65537, modulusBits: 1023))
            ),
            "an RSA key of 16385 bits" => SshWire.Answer(
                1,
                SshWire.Entry(SshWire.Rsa(exponent: 65537, modulusBits: 16385))
            ),
            "an RSA key with an even exponent" => SshWire.Answer(
                1,
                SshWire.Entry(SshWire.Rsa(exponent: 65536, modulusBits: 2048))
            ),
            "an RSA key with exponent 1" => SshWire.Answer(
                1,
                SshWire.Entry(SshWire.Rsa(exponent: 1, modulusBits: 2048))
            ),
            "an RSA key with a five-byte exponent" => SshWire.Answer(
                1,
                SshWire.Entry([.. SshWire.Str("ssh-rsa"), .. SshWire.Str([1, 0, 0, 0, 1]), .. modulus])
            ),
            "an RSA key with an empty exponent" => SshWire.Answer(
                1,
                SshWire.Entry([.. SshWire.Str("ssh-rsa"), .. SshWire.Str([]), .. modulus])
            ),
            "an RSA key with a needless leading zero" => SshWire.Answer(
                1,
                SshWire.Entry([.. SshWire.Str("ssh-rsa"), .. SshWire.Str([0, 1, 0, 1]), .. modulus])
            ),
            "an RSA key with a lone zero byte" => SshWire.Answer(
                1,
                SshWire.Entry([.. SshWire.Str("ssh-rsa"), .. SshWire.Str([0]), .. modulus])
            ),
            "an RSA key with a negative modulus" => SshWire.Answer(
                1,
                SshWire.Entry([
                    .. SshWire.Str("ssh-rsa"),
                    .. SshWire.Mpint([1, 0, 1]),
                    .. SshWire.Str(SshWire.Modulus(2048)),
                ])
            ),
            "an RSA key with an even modulus" => SshWire.Answer(
                1,
                SshWire.Entry([.. SshWire.Str("ssh-rsa"), .. SshWire.Mpint([1, 0, 1]), .. SshWire.Mpint(EvenModulus())])
            ),
            _ => null,
        };
    }

    private static byte[] Ecdsa()
    {
        return [.. SshWire.Str("ecdsa-sha2-nistp256"), .. SshWire.Str("nistp256"), .. SshWire.Str([4, 1, 2])];
    }

    private static byte[] EvenModulus()
    {
        byte[] modulus = SshWire.Modulus(2048);
        modulus[^1] = 0;

        return modulus;
    }
}
