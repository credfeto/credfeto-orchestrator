using System;
using System.Buffers;
using System.Text.Unicode;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman;

// Each query runs the podman command its lib/podman function runs and returns what the function prints and its status.
// A query refuses (PodmanRefusedException) where bash's answer would depend on something it does not reproduce: an
// argument that is not UTF-8 (it reaches .NET with the bad bytes replaced, so podman would be asked about another
// name), and podman output that is not UTF-8 or holds a NUL byte (bash drops a NUL from a command substitution, with
// a warning)
public sealed class PodmanQueries : IPodmanQueries
{
    private const string IMAGE_ENVIRONMENT_FORMAT = "{{range .Config.Env}}{{println .}}{{end}}";
    private const string RUNNING_FORMAT = "{{.State.Running}}";
    private const byte NEWLINE = (byte)'\n';

    private readonly IPodmanRunner _podman;

    public PodmanQueries(IPodmanRunner podman)
    {
        this._podman = podman;
    }

    private static ReadOnlySpan<byte> ShaVariable => "IMAGE_SHA_DEVELOPMENT_AGENT="u8;

    private static ReadOnlySpan<byte> True => "true"u8;

    // The value of every IMAGE_SHA_DEVELOPMENT_AGENT=<value> line of the image's environment, one a line, as sed -n
    // s/^IMAGE_SHA_DEVELOPMENT_AGENT=//p prints them, with the trailing newlines the command substitution drops
    // dropped; status 1 and nothing printed when that leaves nothing. podman's own status is not looked at, as bash
    // does not look at it.
    public async ValueTask<PodmanResult> ImageShaAsync(string image, CancellationToken cancellationToken)
    {
        RefuseArgument(argument: image, option: "image");
        PodmanResult inspect = await this._podman.RunAsync(
            arguments: ["inspect", "--format", IMAGE_ENVIRONMENT_FORMAT, image],
            cancellationToken: cancellationToken
        );
        RefuseOutput(inspect.Output.Span);

        byte[] sha = ShaValues(inspect.Output.Span);

        return sha.Length == 0 ? new(ExitCode: 1, Output: ReadOnlyMemory<byte>.Empty) : new(ExitCode: 0, Output: sha);
    }

    // podman inspect <name> with its output thrown away: 0 when podman succeeds and 1 otherwise
    public async ValueTask<PodmanResult> ContainerExistsAsync(string name, CancellationToken cancellationToken)
    {
        RefuseArgument(argument: name, option: "name");
        PodmanResult inspect = await this._podman.RunAsync(
            arguments: ["inspect", name],
            cancellationToken: cancellationToken
        );

        return new(ExitCode: inspect.ExitCode == 0 ? 0 : 1, Output: ReadOnlyMemory<byte>.Empty);
    }

    // 0 when podman inspect --format {{.State.Running}} <name> prints exactly true, once its trailing newlines are
    // dropped, whatever podman's status, and 1 otherwise
    public async ValueTask<PodmanResult> ContainerRunningAsync(string name, CancellationToken cancellationToken)
    {
        RefuseArgument(argument: name, option: "name");
        PodmanResult inspect = await this._podman.RunAsync(
            arguments: ["inspect", "--format", RUNNING_FORMAT, name],
            cancellationToken: cancellationToken
        );

        if (inspect.Output.Span.Contains((byte)0))
        {
            throw new PodmanRefusedException("podman printed a NUL byte, which bash drops from what it compares");
        }

        bool running = inspect.Output.Span.TrimEnd(NEWLINE).SequenceEqual(True);

        return new(ExitCode: running ? 0 : 1, Output: ReadOnlyMemory<byte>.Empty);
    }

    // podman image exists <image>: what it prints, and 0 when it succeeds and 1 otherwise
    public async ValueTask<PodmanResult> ImageExistsAsync(string image, CancellationToken cancellationToken)
    {
        RefuseArgument(argument: image, option: "image");
        PodmanResult exists = await this._podman.RunAsync(
            arguments: ["image", "exists", image],
            cancellationToken: cancellationToken
        );
        RefuseOutput(exists.Output.Span);

        return new(ExitCode: exists.ExitCode == 0 ? 0 : 1, Output: exists.Output);
    }

    private static byte[] ShaValues(ReadOnlySpan<byte> environment)
    {
        ArrayBufferWriter<byte> values = new();
        ReadOnlySpan<byte> rest = environment;

        while (!rest.IsEmpty)
        {
            int end = rest.IndexOf(NEWLINE);
            ReadOnlySpan<byte> line = end < 0 ? rest : rest[..end];
            rest = end < 0 ? [] : rest[(end + 1)..];

            if (line.StartsWith(ShaVariable))
            {
                values.Write(line[ShaVariable.Length..]);
                values.Write([NEWLINE]);
            }
        }

        return values.WrittenSpan.TrimEnd(NEWLINE).ToArray();
    }

    private static void RefuseArgument(string argument, string option)
    {
        if (argument.Contains('�', StringComparison.Ordinal) || argument.Contains('\0', StringComparison.Ordinal))
        {
            throw new PodmanRefusedException(
                $"the {option} is not valid UTF-8, so podman cannot be given the bytes bash would give it"
            );
        }
    }

    private static void RefuseOutput(ReadOnlySpan<byte> output)
    {
        if (output.Contains((byte)0))
        {
            throw new PodmanRefusedException("podman printed a NUL byte, which bash drops from its output");
        }

        if (!Utf8.IsValid(output))
        {
            throw new PodmanRefusedException("podman printed bytes that are not UTF-8");
        }
    }
}
