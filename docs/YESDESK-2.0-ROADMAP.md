# YES Desk 2.0 — engineering roadmap

Status: proposed; implementation and runtime compatibility not yet verified.
Baseline: `67289830ea4a1a08fc6023360d0ab5cdf3d73796` (master). The historical manually dispatched Windows workflow succeeded at this commit (run 23889510149). Do not assume a fresh build or every artifact is healthy until tested.

## 1. Audit findings
- Fork of rustdesk/rustdesk; Cargo package rustdesk, library librustdesk, version 1.4.6.
- Comparison to upstream commit cca6a5fe12570d7a65f1b8eb7485a1c865dcd859: 31 commits ahead, 53 changed paths reported by GitHub. Many changes are vendoring hbb_common; do not treat all as original features.
- Branding changes are largely assets, metadata, and seven changed lines in flutter/lib/common.dart; desktop_home_page.dart and remote_toolbar.dart are not listed as changed in this comparison.
- libs/hbb_common is vendored rather than a git submodule. Preserve its content, check provenance against upstream's pinned gitlink before attempting updates; never run the destructive nuke_link workflow.
- flutter/windows/CMakeLists.txt still produces rustdesk; CI copies the executable to YES_Desk.exe, patches MSI source at build time and packs the portable variant. Preserve that temporary convention until an installer upgrade/migration design is tested.
- flutter-build.yml was heavily reduced relative to upstream; it still uses external engine/driver downloads and has release upload steps. Audit provenance, pinning and release guards. Never publish/overwrite the nightly tag from a feature branch.
- No working local build, device test, complete source review or deployed SCTGDesk audit has been performed as part of this document.

## 2. Product direction
Windows x64 first; preserve other supported platforms and existing functionality. A distinct remote support workspace, not a disguised upstream fork. Keep AGPL-3.0 notices and corresponding source obligations. Track upstream security fixes.
Design direction (proposal): graphite surfaces, restrained lime accent, accessible light/dark theme, compact typography, keyboard-first navigation. Prefer native-feeling desktop layout over generic web-style cards. Use real data; no fabricated online counts or session metrics.

## 3. Architecture
Keep Rust networking, FFI, IPC, capture, encryption, permission checks, session lifecycle and OS service contracts stable during UI changes.
SCTGDesk is the existing backend (deployment variant/version unknown). Public references:
- https://github.com/sctg-development/sctgdesk-server
- https://sctg-development.github.io/sctgdesk-server/
- https://github.com/sctg-development/sctgdesk-api-server
The integrated variant has ID/rendezvous, relay and API/web console capabilities; address books, users/groups and OIDC are documented in current upstream. Verify the actual installed version and supported endpoints before creating integrations. Reuse existing authentication, address book and group semantics rather than duplicate them. Never silently fall back to public servers in corporate-managed mode; do not change existing server settings in the redesign sprint. Treat private deployment config as out-of-repo data.

## 4. Sequenced implementation
P0 — reproducibility and safety: inventory build tools, dependencies, release artifacts, branding/config locations, workflows and public-server defaults; baseline analysis/tests; add feature-branch artifact-only CI or safely guard existing release steps. Never run release on a feature branch. Record command results, known failures and rollback procedure.
P1 — original desktop UI: introduce a scoped design system under flutter/lib/yesdesk/ (tokens, reusable widgets, semantic styles); refactor the main shell, using existing models and state rather than mocking connections. Target flutter/lib/desktop/pages/desktop_home_page.dart, connection_page.dart, and common/widgets/peer_tab_page.dart. Keep ID, temporary password regeneration, copy, accept/reject, address book, recent peers, online state, install/upgrade prompts, settings and connection actions functional. Start with a working shell; keep changes reviewable.
P2 — session UX: existing remote_page.dart, remote_tab_page.dart, desktop_remote_screen.dart and remote_toolbar.dart; improve toolbar, monitor selector, tabs, diagnostics and reconnect presentation. Keep existing permissions and controls (files, clipboard, keyboard, view-only, disconnect) intact. No transport changes in this phase.
P3 — consistent branding and packaging: review metadata, startup, tray, service labels, installer/upgrade/uninstall, translations, About page and README. Retain internal identifiers when needed for compatibility; document migrations and preserve users' configuration. Do not erase upstream notices.
P4 — SCTGDesk integration: document API capability matrix based on an explicitly provided sanitized deployment version and test instance; use server-supported auth and real address book/groups. Test session authorization at the receiving endpoint; fail closed where managed policies require it. Add only missing capabilities with separate APIs when necessary.
P5 — optional corporate features: request support, ticket linking, authorized diagnostic readouts, device inventory and audit. AD/OIDC, UNIT, Bitrix24 and n8n only after deployment/service permissions and privacy requirements are established. No unattended access without explicit administrator provisioning, visibility, audit and revocation.

## 5. Acceptance gates
- New files formatted; analyze/test results recorded; no new known failures. Windows x64 builds produce a portable EXE and MSI as non-release test artifacts.
- Manual two-device tests on authorized test machines against SCTGDesk: first start, upgrade/uninstall, preserved settings, login/address book (if supported), direct and relay sessions, accept/reject, temporary password, file transfer, clipboard, monitor switch, keyboard layout, disconnect, reconnect, offline/invalid server and invalid key. Test UAC and service mode explicitly.
- Verify light/dark, ru/en, 100/125/150% DPI, resize/keyboard navigation; no clipping. New visible UI strings localized via existing translation pipeline.
- Verify server identity and encryption remain unchanged, no new public endpoints, no secrets in diff/logs, no weakened permissions/consent and no false success statuses.
- Keep master unchanged until owner review. Use small commits and a draft PR; don't merge, deploy, publish releases or alter repository settings without separate approval.

## 6. First deliverable
A working redesigned home workspace with live existing actions, isolated reusable style primitives and tests, plus the P0 build audit. Session redesign and backend changes belong to subsequent PRs. If baseline build cannot run, report the exact blocker and do not label the build as verified.
