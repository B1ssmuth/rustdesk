# YES Desk for Windows x64

## Installation paths

| Entry point | Expected behavior |
| --- | --- |
| Versioned portable EXE | Runs from a per-user cache under `%LOCALAPPDATA%\YES Desk Portable`. The home screen has no installation or update card. |
| Portable **Settings → General → Installation** | Opens the Flutter installer if that build includes its matching MSI and no YES Desk installation is registered. Run portable normally. Windows Installer handles any UAC prompt. |
| MSI | Installs one primary application binary, `%ProgramFiles%\YES Desk\YES_Desk.exe`, in the standard system directory. Removes the app through Windows Installer from **Settings → Apps → Installed apps**. |
| Installed application | Opens via the **YES Desk** Start Menu shortcut or the registered executable. A stale registry path with no executable does not count as installed. |

The x64 build compiles `YES_Desk.exe` directly. WiX consumes the runner and its libraries before the completed MSI is embedded in the portable EXE. Installed files never include the embedded MSI. The archiving code keeps the serialized portable format marker and native interface for compatibility. The x86 Sciter build does not use this MSI.

Portable installation passes the existing Start Menu, desktop and printer choices to the matching MSI. Windows Installer suppresses its own client launch on that path. After a successful return the Flutter installer resolves the registered EXE and starts it as the original user. Cancellation, restart required, a missing package and a failed launch have distinct messages. The standard MSI launches the app after the interactive install. Use `YESDESK_LAUNCH_APP=0` for deployments where app launch is undesired.

The MSI creates the service under the SCM name `YES Desk` and displays it as `YES Desk Service`. Its standard service actions own the quoted image path, automatic start, stop and removal. `YESDESK_SKIP_SERVICE=1` omits service creation for an outgoing-only or deliberately stopped portable client. `YESDESK_DEFER_SERVICE_START=1` creates the automatic service without starting it during setup. Do not reboot a disconnected test runner with that service registered unless the test is intended to exercise networking. The display name in Installed apps is **YES Desk** and the publisher is **YES Apart**. The runtime marker at `HKLM\SOFTWARE\YES Apart\YES Desk\Installer` records the executable, directory and MSI ProductCode separately from the standard Apps entry.

The new package uses the files and components Windows Installer manages. It does not recursively delete the installation directory or kill arbitrary processes by image name. The optional YES Desk print queue has a distinct name and uses the existing signed upstream driver. Removing YES Desk does not remove the shared print driver or the shared virtual display driver.

## Why the legacy installer failed

The pre-stability x64 build copied `rustdesk.exe` to `YES_Desk.exe` and staged both. Native installation copied the input directory. It then registered and tried to launch `YES Desk.exe`, derived by appending the extension to the display name. This file was absent in those payloads. The old installed check used the same guessed path and the old MSI keyed its custom registration under `RustDesk`. The native post-install launch used an unquoted path in a shell command and discarded launch failure. The Flutter installer could exit even when installation failed. The old MSI's technical service name also differed from the name used by the YES Desk service dispatcher.

## Confirmed migration for pre-stability builds

The shipped Sprint 1 and 1.1 packages both report Windows Installer version `1.4.6`. Windows Installer compares the first three version fields, so a fourth-field build number cannot order those releases. The packages used UpgradeCode `{D3DC41E3-3C37-5D52-BB47-F6673705C01B}`, shared with RustDesk packaging, and CI packages included ProductCodes `{92F1307B-738C-4B42-8B2D-84482422672E}` and `{3D33C3AB-051E-4794-841A-D4CBDA298013}`. A rebuild may have a different ProductCode. The new family uses UpgradeCode `{1A8AC87B-B936-5AA9-AE11-219B6D3A8B59}`. Only the new family participates in MSI major upgrades. Same-version replacement within that family is permitted for test builds. Keep the actual build date and a copy of the package for each deployment.

1. Close remote sessions and obtain a copy of the current installer. In Installed apps check the product name and publisher. Compare the real installed files' **Details**, their directory and the service image path. A `RustDesk` folder, service name, UpgradeCode or filename alone is insufficient evidence of ownership. If ownership cannot be confirmed, stop the migration until the deployment owner identifies the installed build.
2. While the old application and its confirmed service are stopped, back up `%APPDATA%\YES Desk` for each participating user and `%WINDIR%\System32\config\systemprofile\AppData\Roaming\YES Desk` if present. Keep the full directory structure and access permissions. If an older deployment used another configuration path, confirm it belongs to that instance before backing it up. Backups contain sensitive IDs, credentials, trusted server keys, saved devices, address books and permissions. Keep them off GitHub and protect user and service copies separately.
3. Confirm that the backed-up configuration includes the profile used by the service. Use the old product's registered uninstaller for the confirmed YES Desk instance. Close any YES Desk tray process. Check that its previous service and installation registration are gone. If the legacy uninstaller leaves files or a service registered, verify ownership before cleaning up. Do not delete a RustDesk folder or service by name.
4. Install the new MSI. It leaves user and service configuration outside the installation directory. If the owner identified a legacy profile under another product path, validate the migration with that build on an isolated machine before copying profile data. The installer does not merge files from a RustDesk profile into a YES Desk profile.
5. Confirm the original device ID, server trust and configuration, favourites, address book, auth settings and permissions. Test service startup after reboot and remote sessions both ways before continuing rollout.

The MSI guard blocks a legacy native YES Desk registration, an unmanaged `YES Desk` service, and legacy MSI entries identifying YES Desk. An unclassified package in the shared UpgradeCode family also blocks migration. The installer leaves a recognized original RustDesk installation in place. A legacy build with neither a recognizable registration nor a service may require manual identification.

### Rollback

Windows Installer rolls back the new product's files, standard registry entries and service when its own installation transaction fails. Legacy uninstall and new install are separate transactions. If the new install fails after removing the old product, finish or repair the new uninstall as appropriate, reinstall the backed-up old package, and restore the corresponding profiles with both applications and services stopped. Keep the backup until the old client again shows the expected ID and settings. Shared drivers and machine policy changes from optional integration can outlive an MSI transaction.

## Compatibility audit

| Area | Kept for compatibility |
| --- | --- |
| Native library | `librustdesk.dll` and the `rustdesk_core_main_args` export remain fixed. The Flutter runner loads the DLL, Dart FFI opens it, Cargo builds it and the bundlers ship it. Rename and dependency validation require a coordinated ABI and packaging change. |
| Portable | The archive's `rustdesk` marker and `RUSTDESK_APPNAME` environment name are private interfaces. The Windows extraction folder is now separate from the original RustDesk cache. |
| Windows integration | The existing YES Desk playback and launch registry identifiers are retained for installed callers. Out-of-process broker name `RuntimeBroker_rustdesk.exe`, shared driver names and Windows system policies have their own compatibility constraints. Original RustDesk URI associations are left to its own installation. |
| Profiles and IPC | The app name still keys the config directories and IPC pipes. The new process and resource names do not change server, cryptography, login or connection behavior. |
| Licensing | **Settings → About → Open source licenses**, the corresponding source in this repository, and the installer license keep upstream and AGPL-3.0 notices. |

## Verification

The Windows x64 Actions smoke test checks portable extraction and compares the embedded MSI with the standalone artifact. It reads MSI and PE metadata, verifies that an older YES Desk registration blocks installation, installs silently from a path with spaces and checks the installed EXE, product registration and service image path. It checks the real installed state through `YES_Desk.exe --install-state` before and after installation. It removes the product and checks for leftovers. The runner neither launches the app nor starts the service, so the smoke test does not contact the configured infrastructure.

Interactive UAC, automatic launch after portable setup, service start after reboot, real legacy profile migration and rollback, the Windows UI under hardware scaling, and actual remote connections, clipboard and file transfer require separate Windows acceptance tests with test endpoints.

[Windows Installer product version](https://learn.microsoft.com/windows/win32/msi/productversion) · [WiX major upgrade](https://docs.firegiant.com/wix/schema/wxs/majorupgrade/) · [Windows Installer service actions](https://learn.microsoft.com/windows/win32/msi/installservices-action)
