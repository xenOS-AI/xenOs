# xenOS documentation

This directory is the human-maintained wiki for xenOS. Start at the
[documentation home](index.md). The pages describe the design and operational
contracts; the Doxygen site complements them with a searchable source browser.

## Generate the API/source reference

Install Doxygen and run the following command from the repository root:

```sh
doxygen Doxyfile
```

Open `build/docs/doxygen/html/index.html` in a browser. Generated output is a
build artifact and must not be committed. `Doxyfile` includes C3, assembly, C,
Python, shell, linker, and Markdown files. C3 is mapped to C for file/source
browsing; consequently, the wiki remains the authoritative explanation of C3
language-specific design decisions.
