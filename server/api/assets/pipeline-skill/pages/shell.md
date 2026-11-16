# Shell [rules 39–40]
- `ffmpeg -nostdin … </dev/null` always.
- Write multi-step builds to a file and run with `bash` (zsh does not split words; arrays start at 1). One build per command; long renders in the background.
- Work files in the project folder (`<project>/work/`), not /tmp.
- Every build script ends with a self-check.
