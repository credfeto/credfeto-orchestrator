using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.State.Tests;

// Sorts names bytewise, as LC_ALL=C sort does
internal sealed class ByteOrder : IComparer<byte[]>
{
    public static readonly ByteOrder Instance = new();

    public int Compare(byte[]? x, byte[]? y)
    {
        return x.AsSpan().SequenceCompareTo(y);
    }
}
