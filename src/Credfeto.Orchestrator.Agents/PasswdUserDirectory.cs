using System;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

// Looks a user name up in a passwd file (name:password:uid:...), first entry first, as glibc's files source does. A
// name it does not find there may still resolve for pkill through another name service, so the stop is refused then.
// A name holding a comma is never looked up: pkill -u reads a comma-separated list.
public sealed class PasswdUserDirectory : IUserDirectory
{
    private readonly string _path;

    public PasswdUserDirectory(string path)
    {
        this._path = path;
    }

    public async ValueTask<uint?> UidAsync(string name, CancellationToken cancellationToken)
    {
        if (name.Length == 0 || name.AsSpan().ContainsAny(",:\n"))
        {
            return null;
        }

        string[] lines;

        try
        {
            lines = await File.ReadAllLinesAsync(path: this._path, cancellationToken: cancellationToken);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        foreach (string line in lines)
        {
            string[] fields = line.Split(':');

            if (fields.Length > 2 && StringComparer.Ordinal.Equals(x: fields[0], y: name))
            {
                return uint.TryParse(fields[2], NumberStyles.None, CultureInfo.InvariantCulture, out uint uid)
                    ? uid
                    : null;
            }
        }

        return null;
    }
}
