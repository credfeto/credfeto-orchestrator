using System;
using System.Collections.Generic;
using System.Linq;

namespace Credfeto.Orchestrator.Podman;

// program_word in claude_result_denied_command_names (lib/podman): the command split into words at runs of what
// Oniguruma's \s matches (splits("\\s+"), empty words dropped), then the first word that is not a NAME=value
// assignment, a word of only ( and {, or a wrapper (env, sudo, command, exec, nohup, time, xargs) or one of the
// wrapper's options. An option known to take a value skips its value too, and one whose value opens a quote that the
// same word does not close leaves no word at all. "--" ends a wrapper's options.
internal static class ShellProgramWord
{
    private static readonly string[] Wrappers = ["env", "sudo", "command", "exec", "nohup", "time", "xargs"];

    private static readonly Dictionary<string, string[]> OptionsWithValue = new(StringComparer.Ordinal)
    {
        ["sudo"] =
        [
            "-u",
            "-g",
            "-C",
            "-D",
            "-h",
            "-p",
            "-r",
            "-t",
            "-U",
            "--user",
            "--group",
            "--close-from",
            "--chdir",
            "--host",
            "--prompt",
            "--role",
            "--type",
            "--other-user",
        ],
        ["env"] = ["-u", "-C", "-S", "--unset", "--chdir", "--split-string"],
        ["xargs"] =
        [
            "-I",
            "-n",
            "-d",
            "-L",
            "-P",
            "-s",
            "-E",
            "-a",
            "--max-args",
            "--delimiter",
            "--max-procs",
            "--max-chars",
            "--arg-file",
        ],
        ["time"] = ["-o", "-f", "--output", "--format"],
    };

    public static string Find(string command)
    {
        IReadOnlyList<string> words = Split(command);
        int index = 0;

        while (index < words.Count)
        {
            string word = words[index];

            if (IsAssignment(word) || IsOnlyOpeners(word))
            {
                index++;
            }
            else if (Wrappers.Contains(value: word, comparer: StringComparer.Ordinal))
            {
                index = SkipWrapperOptions(words: words, index: index + 1, wrapper: word);
            }
            else
            {
                return word;
            }
        }

        return string.Empty;
    }

    // skip_wrapper_options: the index of the first word after the wrapper's options, or past the end for none
    private static int SkipWrapperOptions(IReadOnlyList<string> words, int index, string wrapper)
    {
        string[] withValue = OptionsWithValue.GetValueOrDefault(key: wrapper, defaultValue: []);

        while (index < words.Count)
        {
            string word = words[index];

            if (StringComparer.Ordinal.Equals(x: word, y: "--"))
            {
                return index + 1;
            }

            if (word[0] != '-')
            {
                return index;
            }

            if (!withValue.Contains(value: word, comparer: StringComparer.Ordinal))
            {
                index++;
            }
            else if (index + 1 < words.Count && OpensQuote(words[index + 1]))
            {
                return words.Count;
            }
            else
            {
                index += 2;
            }
        }

        return words.Count;
    }

    // ^[A-Za-z_][A-Za-z0-9_]*=
    private static bool IsAssignment(string word)
    {
        int equals = word.IndexOf('=', StringComparison.Ordinal);

        if (equals <= 0 || !IsNameCharacter(word[0]) || char.IsAsciiDigit(word[0]))
        {
            return false;
        }

        for (int index = 1; index < equals; index++)
        {
            if (!IsNameCharacter(word[index]))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsNameCharacter(char character)
    {
        return char.IsAsciiLetterOrDigit(character) || character == '_';
    }

    // ^[({]+$, a word holding no newline
    private static bool IsOnlyOpeners(string word)
    {
        return !word.AsSpan().ContainsAnyExcept("({");
    }

    // ^["'][^"']*$, a word holding no newline
    private static bool IsOpenQuote(char character)
    {
        return character is '"' or '\'';
    }

    private static bool OpensQuote(string word)
    {
        return IsOpenQuote(word[0]) && !word.AsSpan(1).ContainsAny("\"'");
    }

    // splits("\\s+") | select(length > 0)
    private static IReadOnlyList<string> Split(string command)
    {
        List<string> words = [];
        int start = -1;

        for (int index = 0; index < command.Length; index++)
        {
            if (OnigurumaWhitespace.IsSpace(command[index]))
            {
                if (start >= 0)
                {
                    words.Add(command[start..index]);
                    start = -1;
                }
            }
            else if (start < 0)
            {
                start = index;
            }
        }

        if (start >= 0)
        {
            words.Add(command[start..]);
        }

        return words;
    }
}
