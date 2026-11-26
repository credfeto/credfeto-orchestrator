namespace Credfeto.Orchestrator.State;

// How the lib/state function puts its file in place, which decides what the file looks like afterwards
public enum StateReplacement
{
    // printf ... > file: an existing file keeps its mode, owner and group (and every other hard link to it)
    IN_PLACE,

    // printf ... > file.tmp && mv -f file.tmp file: always a new file, with the mode the umask gives
    MOVED,
}
