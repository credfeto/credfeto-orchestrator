<!-- markdownlint-disable-file -->
- Scratch/temporary output (redirect targets, intermediate files you don't want committed) should go to $TMPDIR (or $TMP/$TEMP — all three point at the same registered, writable scratch directory) rather than a hardcoded /tmp/... path.
