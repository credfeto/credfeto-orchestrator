<!-- markdownlint-disable-file -->
To continue the rebase after fixing conflicts: git -C {{repo_path}} add <files>, then git -C {{repo_path}} rebase --continue as its own command. It needs no editor override: do not set GIT_EDITOR or -c core.editor (both are blocked), and do not chain it with &&. Edit conflicted files with the file tools or one sed -i per file, not a heredoc script.
