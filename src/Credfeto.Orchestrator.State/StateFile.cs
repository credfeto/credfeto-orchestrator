using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.State;

// How lib/state looks at a state file: [ -f ] and reading it whole
public static class StateFile
{
    // bash [ -f path ]: a regular file, or a link that ends at one
    public static bool IsRegularFile(string path)
    {
        try
        {
            FileInfo info = new(path);

            if (info.LinkTarget is null)
            {
                return info.Exists;
            }

            return info.ResolveLinkTarget(returnFinalTarget: true) is { Exists: true } target
                && (target.Attributes & FileAttributes.Directory) != FileAttributes.Directory;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    // A file bash could not read (or that went away) is refused: bash then gives its own answer and message
    public static async ValueTask<byte[]> ReadAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            return await File.ReadAllBytesAsync(path: path, cancellationToken: cancellationToken);
        }
        catch (IOException exception)
        {
            throw Unreadable(path: path, exception: exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw Unreadable(path: path, exception: exception);
        }
    }

    private static StateRefusedException Unreadable(string path, Exception exception)
    {
        return new(message: "cannot read " + path + ": " + exception.Message, innerException: exception);
    }
}
