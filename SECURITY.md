# Security policy

## Reporting a vulnerability

Please report security issues privately through the repository's security advisory feature. Do not include credentials, recordings, screenshots, device identifiers, or other sensitive data in a public issue.

Include the affected version, a concise reproduction, and the security impact. Maintainers will acknowledge a complete report as soon as practical and coordinate disclosure after a fix is available.

## Deployment guidance

- Keep the inference server behind a firewall and expose only the port required by trusted clients.
- Configure a unique, randomly generated `RAT_SERVER_API_KEY` for every deployment.
- Use HTTPS whenever traffic leaves the local machine. Audio, screenshots, commands, and API keys are sensitive in transit.
- Do not publish diagnostic logs. Although release logging avoids content and device identifiers, logs can still reveal usage patterns and system state.
- Build release artifacts from a clean checkout. Generated binaries, code signatures, local configuration, and caches are intentionally excluded from version control.
