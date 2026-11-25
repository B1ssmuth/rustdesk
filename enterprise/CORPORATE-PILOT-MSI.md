# Sprint 3.8 · Corporate access and unified pilot MSI

## Current remote access boundary

Ordinary remote access by ID retains the existing RustDesk login, passwords and confirmation settings. The corporate workspace displays an inactive Connect control. Management checks the operator's local session, directory role, device-specific grant, recent heartbeat and access policy. An otherwise eligible request returns HTTP 501. An ineligible request returns HTTP 403. The response contains no authorization grant or RustDesk password.

The attended policy defaults to permitted for individually granted operators. The separate unattended policy is off by default. Only an administrator can record a finite unattended policy for an enrolled Windows device. Expiry is limited to 30 days and unattended eligibility requires the administrator role and an individual device grant. Revoking the enrolled agent also deletes its policy. Policy eligibility never enables a session in this release.

The Rust receiver rejects a reserved corporate request before ordinary login. An unencrypted stream gets a transport-required error. An encrypted stream gets an endpoint-unavailable error. A future implementation must bind a short-lived, one-use grant to the authenticated peer keys, operator and exact channel, enforce local consent or unattended policy at the service, and terminate on revocation or expiry. Corporate mode must abort instead of using the ordinary handshake's compatibility fallback. The current receiver has no verified service-mediated Windows consent or session-wide capability enforcement. UAC and local protection remain under the existing Windows and RustDesk rules.

## Management update

Take and test a PostgreSQL backup. Apply migration `009_corporate_access_policy.sql` on a copy and run the regression suite. For an approved test deployment from the separate Management Compose directory:

```bash
docker compose build api migrate
docker compose run --rm --no-deps migrate
docker compose up -d --no-deps api
curl -fsS http://127.0.0.1:18083/health/ready
```

Existing migrations, client accounts, enrollment and optional AD synchronization remain compatible. The added policy table can be retained if the Management image is rolled back. The current RustDesk Compose and directory infrastructure require no change. To inspect or stage a pilot policy, use authenticated `GET /v2/devices/{id}/connection-options` and administrator-only `PUT /v2/devices/{id}/corporate-policy` with `attended` and optional `unattended_until`. Individual grants continue to use the existing operator CLI. This endpoint does not return a grant.

## Build and clean pilot installation

Create a separate JSON client config whose `YESDESK_MANAGEMENT_URL` points to the approved pilot Management API over TLS. On both pilot VMs, configure the test RustDesk ID server, relay and public key before the first session. Use an isolated test network that cannot reach the client's default production server.

```powershell
pwsh -File .\scripts\build-windows-local.ps1 -Build -Ref HEAD -UnifiedEnterpriseMsi -EnterpriseConfig C:\Pilot\yesdesk-client.json
```

The unified MSI installs the standard YES Desk client and transport service plus YESDeskAgent with one Windows Installer transaction. Its launch guard blocks initial installation over a detected previous product, transport service or standalone agent. Use only a clean pilot VM until a backup, migration and rollback sequence has been verified. Do not substitute an older ordinary MSI for an update to this package. The ordinary build without `-UnifiedEnterpriseMsi` stays available for non-enrolled clients.

On each clean pilot VM, deliver the approved private machine certificate and centrally approved enrollment record through the existing pilot PKI. In an elevated or SYSTEM context use `enterprise/agent/Provision-Agent.ps1` in certificate mode as described in [Unified Workspace](UNIFIED-WORKSPACE.md). This stages configuration and enables enrollment on service startup. Then run one installation:

```powershell
msiexec.exe /i YES_Desk-Enterprise-1.4.6-x86_64.msi /qn /norestart /l*v yesdesk-pilot-install.log
Get-Service 'YES Desk','YESDeskAgent'
```

Gate any domain rollout on signing, approval of the certificate broker, and successful verification on at least two isolated Windows VMs. On fresh VMs verify MSI install, two services, reboot, enrollment, disconnect/recovery and uninstall. On a VM with a previous installation verify that the unified package rejects migration without changing either service or its configuration. Preserve existing install and DPAPI state for approved migration work. Do not make untested changes to production GPO.

## Two-VM acceptance

Use separate Windows VMs and test-only Management/relay/network infrastructure. Verify ordinary ID and password access, an unattended-disabled policy and confirmation behavior. Verify allowed corporate policies still return 501 and produce no native connection. When end-to-end endpoint verification exists, add real consent, deny/cancel, permitted unattended, revocation during the session, device substitution, replay, expiry, reboot, disconnect, locked desktop and UAC tests. A server response or successful MSI extraction does not establish a working corporate session.
