namespace Credfeto.Orchestrator.Prompts;

internal static class BashText
{
    // What $(...) keeps of a command's output: everything but its trailing newlines
    public static string Substitution(string output)
    {
        return output.TrimEnd('\n');
    }

    // A heredoc (cat <<EOF) or printf '...\n' prints its text followed by one newline
    public static string Line(string text)
    {
        return text + "\n";
    }

    public static bool IsTrue(string value)
    {
        return System.StringComparer.Ordinal.Equals(x: value, y: "true");
    }
}
