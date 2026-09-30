# Maintain in repo: cs-template
# Reports list items that start with a literal ordered-list marker (1. text) outside
# fenced code blocks, because CommonMark detaches nested content from such items.

FNR == 1 {
  fence = ""
}

# Per CommonMark a fence closes only on the same character, at least as long, with nothing after it.
fence != "" {
  if ($0 ~ /^[[:space:]]*(```+|~~~+)[[:space:]]*$/) {
    marker = $0
    gsub(/[[:space:]]/, "", marker)
    if (substr(marker, 1, 1) == substr(fence, 1, 1) && length(marker) >= length(fence)) {
      fence = ""
    }
  }
  next
}

match($0, /^[[:space:]]*(```+|~~~+)/) {
  fence = substr($0, RSTART, RLENGTH)
  gsub(/[[:space:]]/, "", fence)
  next
}

/^[[:space:]]*[0-9]+\.[[:space:]]/ {
  printf "::error file=%s,line=%d::Numbered list marker; use a '- **P1.**' style bullet label instead\n", FILENAME, FNR
  failed = 1
}

END {
  exit failed
}
