using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Credfeto.Orchestrator.State;

// What lstat(2) says of a path: the file type and permission bits, the hard link count, and the owner and group
[StructLayout(LayoutKind.Auto)]
[DebuggerDisplay("Mode={Mode}, Links={Links}, Owner={Owner}, Group={Group}")]
public readonly record struct UnixFileStatus(uint Mode, uint Links, uint Owner, uint Group)
{
    private const uint TYPE_BITS = 0xF000;
    private const uint REGULAR_FILE = 0x8000;
    private const uint DIRECTORY = 0x4000;
    private const uint SYMBOLIC_LINK = 0xA000;
    private const uint PERMISSION_BITS = 0xFFF;

    public bool IsRegularFile => (this.Mode & TYPE_BITS) == REGULAR_FILE;

    public bool IsDirectory => (this.Mode & TYPE_BITS) == DIRECTORY;

    public bool IsSymbolicLink => (this.Mode & TYPE_BITS) == SYMBOLIC_LINK;

    // The permission bits, set-id and sticky bits included
    public uint Permissions => this.Mode & PERMISSION_BITS;
}
