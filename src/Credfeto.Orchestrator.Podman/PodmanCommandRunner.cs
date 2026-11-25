using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman;

// credfeto-orchestrator podman ...: answers a read-only lib/podman query by running the same podman command, printing
// what the shell function prints, byte for byte, and exiting with the status it returns
public sealed class PodmanCommandRunner
{
    public const int Usage = 2;

    // The query cannot be answered exactly as bash would answer it, so lib/podman answers it in bash
    public const int Refused = 3;

    // podman could not be run, or the answer could not be written
    public const int Failed = 125;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator podman image-sha|image-exists --image <image>
               credfeto-orchestrator podman container-exists|container-running --name <name>

        Each query runs the podman command its lib/podman function runs, prints what the function prints and exits
        with the status it returns: image-sha current_agent_image_sha (the image's IMAGE_SHA_DEVELOPMENT_AGENT),
        container-exists agent_container_exists, container-running agent_container_running and image-exists
        agent_image_cached. podman's stderr is passed through.

        Exit codes: 0 or 1 the answer; 2 a usage error; 3 the query cannot be answered exactly as bash would (an
        argument or podman output that is not UTF-8, or output holding a NUL byte), so lib/podman answers it; 125
        podman could not be run.
        """;

    private readonly IPodmanQueries _queries;

    public PodmanCommandRunner(IPodmanQueries queries)
    {
        this._queries = queries;
    }

    public static PodmanCommandRunner CreateDefault()
    {
        return new(new PodmanQueries(new PodmanProcessRunner()));
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Stream output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        PodmanCommand? command = PodmanCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
            await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return Usage;
        }

        try
        {
            PodmanResult answer = await this.AnswerAsync(command: command, cancellationToken: cancellationToken);
            await output.WriteAsync(answer.Output, cancellationToken);
            await output.FlushAsync(cancellationToken);

            return answer.ExitCode;
        }
        catch (PodmanRefusedException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Refused, cancellationToken);
        }
        catch (PodmanException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Failed, cancellationToken);
        }
        catch (IOException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Failed, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return Cancelled;
        }
    }

    private ValueTask<PodmanResult> AnswerAsync(PodmanCommand command, CancellationToken cancellationToken)
    {
        return command.Query switch
        {
            PodmanQuery.IMAGE_SHA => this._queries.ImageShaAsync(
                image: command.Argument,
                cancellationToken: cancellationToken
            ),
            PodmanQuery.CONTAINER_EXISTS => this._queries.ContainerExistsAsync(
                name: command.Argument,
                cancellationToken: cancellationToken
            ),
            PodmanQuery.CONTAINER_RUNNING => this._queries.ContainerRunningAsync(
                name: command.Argument,
                cancellationToken: cancellationToken
            ),
            _ => this._queries.ImageExistsAsync(image: command.Argument, cancellationToken: cancellationToken),
        };
    }

    private static async ValueTask<int> FailAsync(
        TextWriter error,
        string message,
        int status,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: podman: {message}".AsMemory(), cancellationToken);

        return status;
    }
}
