namespace Credfeto.Orchestrator.Discord;

// How bash's ${#var} counts where the lib/discord function runs: code points in a UTF-8 locale, bytes in C or a
// single-byte locale
public enum LengthUnit
{
    CHARACTERS,
    BYTES,
}
