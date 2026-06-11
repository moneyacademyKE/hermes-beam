# Babashka Workers Import Scanner

## Overview
This project includes a regex scanner that identifies all import statements in the `babashka_workers` directory.

## How it works
- The scanner traverses directories, matches the regex `import\s+\S+`, and stores results in `imports.txt`.

## Learnings
- Details available in `learnings.md`, which documents key takeaways from the implementation.