namespace Credfeto.Orchestrator.Podman;

// How bash reads a message in the locale it runs in, from the effective LC_CTYPE and LC_COLLATE names lib/podman
// passes (${LC_ALL:-${LC_CTYPE:-${LANG:-}}} and the same for LC_COLLATE: a shell variable need not be exported, so
// the tool's own environment is not used). Bytes: C or POSIX (or unset) for both, where every byte is one character,
// and 0x80 to 0xFF are no letter, digit or space and are not case-mapped. ASCII: both C, POSIX, unset, C.UTF-8 or an
// en_* UTF-8 locale, where ASCII text gets the same answers as in C (probed with bash 5.3 / glibc 2.44 in C, C.UTF-8
// and en_GB.UTF-8 for every atom the parser accepts). A locale that is not installed falls back to C, which gives
// ASCII the same answers too. Any other locale is refused: Turkish case mapping or another collation order changes
// even ASCII answers.
internal enum SessionTextLocale
{
    BYTES,
    ASCII,
}
