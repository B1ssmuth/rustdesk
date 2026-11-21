# YES Desk Native RDP

In the Windows YES Desk connection manager, open **Windows RDP**, create a profile, and select **Connect**. The profile uses a DNS name, IPv4, or IPv6 and a separate port (3389 by default). To use a Windows account, enter an optional username such as `CONTOSO\alice` or `alice@contoso.example`. Windows handles the sign-in prompt, password entry, and any credential saving permitted by policy.

A profile stores the desktop size, smart sizing, initial fullscreen mode, clipboard preference, and optional RD Gateway DNS name. Clipboard sharing is off by default. Fullscreen uses the client's standard controls and shortcuts. Each launch can open a separate MSTSC window, so users can keep several RDP sessions open and switch between them using Windows. Authentication errors, permission denials, network interruptions and retries appear in MSTSC. The workspace reports process launch and failure. Closing an MSTSC window leaves its saved profile available for another connection.

## Architecture decision

| Option | Engineering and maintenance impact |
| --- | --- |
| Microsoft MSTSC | The supported Windows client is patched with the OS and handles the Windows credential prompt, certificate trust, NLA, gateway, display, device redirection, and auto-reconnect. Starting it from the system directory uses the Windows installation in place. |
| Microsoft RDP ActiveX | Embedding the control would require a Windows runner plugin with a COM STA, child HWND and message handling. Flutter and the child HWND would need coordinated focus, input capture, DPI, resizing, clipping, fullscreen, accessibility and teardown for each tab. ActiveX offers richer session events if that integration is built. |
| FreeRDP | Apache-2.0 and suitable for native embedding, including CredSSP and RD Gateway. Embedding requires C ABI bindings, rendering and input integration, TLS/credential policy, Windows dependency distribution, and ongoing security updates for the bundled stack. |
| IronRDP | MIT or Apache-2.0 and a plausible Rust integration. A production adapter would still need Windows trust and authentication integration, rendering, input, session lifecycle, and validation of gateway feature coverage. It should be evaluated in a dedicated prototype if embedding becomes a requirement. |

Use MSTSC for Sprint 2.3. The Windows adapter creates an allowlisted Unicode connection file for each launch, resolves the executable through the Windows system-directory API, and passes the file as a single argument without a shell. The existing RustDesk-ID connection and its RDP-over-tunnel command retain their separate workflows. SSH and SFTP retain their existing navigation and storage.

## Security and deployment

- Target authentication uses `authentication level:i:1`, which makes server authentication failure fatal. Use a DNS name or IP address that matches a certificate trusted by Windows. For an internal CA, distribute the CA through normal Windows administration.
- The adapter enables CredSSP. MSTSC negotiates the connection and can use NLA when the server supports it. For deployments that require NLA on every connection, require NLA on the managed Windows hosts. MSTSC does not report the negotiated mode back to the workspace.
- The optional RD Gateway is a DNS name. A configured gateway is requested for every connection in that profile, including destinations on the local network. MSTSC handles the gateway certificate, gateway authentication and authorization policies. The target and gateway may prompt for credentials separately.
- Profiles contain connection metadata, including the optional username. Passwords are entered in Windows. If the user chooses to save them and Windows policy permits it, Windows Credential Manager stores and scopes them under the signed-in Windows account using its native rules. Profiles sharing a destination can share that Windows credential scope. Editing or deleting a YES Desk profile leaves Windows credentials intact. Manage those entries through Windows Credential Manager.
- Each launch uses a unique temporary directory and removes its connection file on launch failure or client-process exit. If YES Desk exits first, the OS can clear the temporary file. These files contain connection metadata only.
- The workspace has no MSTSC session API. A started process does not establish that authentication succeeded or that a session remains active. MSTSC owns the session windows, errors and reconnect UI. Group Policy, host policy and Windows client availability can limit features such as clipboard redirection, saved credentials, and reconnect.

## Verification

Run `flutter test --no-pub test/yesdesk_rdp` from `flutter/`. It covers validation, config serialization, credential-free persistence, Unicode launch files, concurrent launches, cleanup, and launch errors in the workspace.

On a Windows workstation with the built client, verify:

1. Connect to a test Windows Server and workstation with NLA required and a trusted certificate. Try DNS, IP where the certificate includes an IP SAN, and a custom port. Check domain sign-in in both username formats and wrong-password handling. Confirm a name mismatch and an untrusted certificate are rejected.
2. Save credentials only through Windows when prompted, confirm their Credential Manager entry, reopen the profile, and verify behavior under a policy that forbids saving.
3. Open two profiles simultaneously and disconnect one. Verify the other remains usable. Exercise explicit size, smart sizing, fullscreen, clipboard off and on, and auto-reconnect after a temporary network interruption.
4. Verify a profile routed through a trusted RD Gateway from a network without direct access to the target. Unavailable or untrusted gateways and denied gateway credentials must fail. With direct access also available, confirm a configured but unavailable gateway does not fall back to a direct connection.

## References

- [Microsoft MSTSC command](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/mstsc)
- [Microsoft RDP property reference](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties)
- [Microsoft Remote Desktop ActiveX control](https://learn.microsoft.com/en-us/windows/win32/termserv/remote-desktop-activex-control)
- [FreeRDP license](https://github.com/FreeRDP/FreeRDP/blob/master/LICENSE)
- [IronRDP project and license](https://github.com/Devolutions/IronRDP)
