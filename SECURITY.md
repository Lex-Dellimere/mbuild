# security

## reporting a vulnerability

report it privately through github: the repository's **Security** tab, then **Report a vulnerability**. please don't open a public issue for it.

## supported versions

only the latest commit on `main` (and the newest release, once there are releases) gets fixes.

## what mbuild runs

- **your project's `mbuild.mettle`**: compiled and run by every mbuild command in the project, hooks and commands included. building a project you cloned runs its code, as with a makefile.
- **path dependencies** (`mb_dep_path`, path replacements): their `fn project()` and `fn deps()` run to read their settings, and may only declare things: mbuild refuses `extern`, `syscall`, `asm` and imports other than `mbuild/api` and stdlib modules without I/O, and on linux runs them under the same seccomp filter as `init.rules` (no sandbox on windows, the static check alone). their hooks and commands never run.
- **registry packages**: no code runs when they are fetched or resolved; their manifests are data. their code runs only as built into your program (their C sources are compiled, and C flags that would make the compiler load plugins or run other programs are refused).
- **`mbuild new/init --from PKG`**: the package's `init.rules` runs with no I/O: mbuild refuses `extern`, `syscall` and `asm` outside its init API (so no I/O from the stdlib either) and anything embedded from outside the package, and on linux the rules run under a seccomp filter that allows only memory, writing the plan and exiting. it may only write files into the new project, never `.git/`, `.mbuild/`, `build/` or `mbuild.local.mettle`. what it writes into `mbuild.mettle` is your project's code from then on.

## downloads

registries and compiler releases are fetched over https only (plain http only for localhost). every archive is checked against the sha256 in the registry index or the release's github digest before it is used, and archives holding links, devices, absolute or `..` paths are refused. `mbuild publish` never packs dot-files, `mbuild.local.mettle`, `reports/` or key files.
