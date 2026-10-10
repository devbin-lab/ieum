# Windows distribution

`package-windows.ps1` creates three artifacts from the same checked Release build:

- `Ieum-Setup-x64.exe`: per-user installer with Korean and English, installation location, Start menu shortcut, and an optional desktop shortcut.
- `Ieum-Windows-x64.exe`: the existing self-contained portable launcher used by app updates.
- `Ieum-Windows-x64.zip`: the unpacked Flutter runtime for portable use.

The installer copies the portable launcher to `%LOCALAPPDATA%\Programs\Ieum\Ieum.exe`. Shortcuts always target that stable path. On startup, the launcher verifies and expands its embedded runtime and follows the existing verified update pointer. New installer builds overwrite the stable launcher even when the app version is unchanged.

Installation never requests elevation. Inno Setup registers the app for the current user so that Windows Settings can uninstall it. Uninstall removes the program files and shortcuts it owns. It does not remove `%LOCALAPPDATA%\Ieum`, project databases, credentials, custom storage directories, or user-created files.

Reinstall and uninstall require the installed launcher to be available for exclusive access. If Ieum is running, the wizard asks the user to close it and retry. It never kills the app or its processes.

## Build

From `flutter_app`:

```powershell
.\build-windows.ps1
.\package-windows.ps1
```

The package script downloads the official, immutable Inno Setup 6.7.3 compiler installer on first use, verifies its SHA256 and publisher signature, and extracts the build tools under the repository's ignored `.local\installer-tools` directory. A pinned standalone unpacker performs extraction. No build tool is installed globally. An existing compiler can be supplied with `-InnoCompiler <path-to-ISCC.exe>`.

The compiler's own license is retained beside the extracted tools. Consult [Inno Setup's license](https://jrsoftware.org/files/is/license.txt) before using the compiler for commercial builds.

## Focused verification

```powershell
.\windows\distribution\test-installer.ps1
.\windows\distribution\test-launcher.ps1
```

The installer test compiles the same installer script in an explicit sandbox mode. Its launcher fixture is never executed, its shortcuts stay inside a unique temporary directory, and uninstall registration is disabled. It checks the default and optional shortcuts, durable shortcut targets, reinstall behavior, uninstall cleanup, and preservation of user files. The temporary fixture directory is removed afterward.

Production packaging never enables sandbox mode. The separate launcher tests exercise runtime extraction, verified updates, and startup recovery without opening the real app.

## References

- [Inno Setup modern and dynamic wizard](https://jrsoftware.org/ishelp/topic_setup_wizardstyle.htm)
- [Per-user installation without elevation](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm)
- [Installer shortcut entries](https://jrsoftware.org/ishelp/topic_iconssection.htm)
- [Official Inno Setup compiler release](https://github.com/jrsoftware/issrc/releases/tag/is-6_7_3)
