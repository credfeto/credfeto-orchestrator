using System;

namespace Credfeto.Orchestrator.Agents;

// The text pkill -f tests its pattern against (procps-ng): the process's command line with the NUL ending each
// argument turned into a space, the last one dropped; a process with an empty command line (a zombie, a kernel
// thread) is tested as its name in brackets, "[comm]"
public static class PkillText
{
    public static byte[] FromProcess(ReadOnlySpan<byte> commandLine, ReadOnlySpan<byte> name)
    {
        if (commandLine.IsEmpty)
        {
            byte[] bracketed = new byte[name.Length + 2];
            bracketed[0] = (byte)'[';
            name.CopyTo(bracketed.AsSpan(1));
            bracketed[^1] = (byte)']';

            return bracketed;
        }

        ReadOnlySpan<byte> arguments = commandLine[^1] == 0 ? commandLine[..^1] : commandLine;
        byte[] text = arguments.ToArray();
        text.AsSpan().Replace(oldValue: (byte)0, newValue: (byte)' ');

        return text;
    }
}
