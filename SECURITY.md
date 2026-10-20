# Security Policy

NexusOps is designed with security and least-privilege principles at its foundation. We take vulnerabilities seriously and appreciate the efforts of security researchers and users in keeping our platform safe.

---

## Supported Versions

Only the latest minor release is actively supported with security patches:

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

---

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report security concerns via one of the following methods:
1. **GitHub Private Vulnerability Reporting**: Use the "Report a vulnerability" button under the **Security** tab of the repository.
2. **Email**: Send detailed information to `security@nexusops.local` (or the maintainer's primary contact).

### What to Include in Your Report
- A detailed description of the vulnerability.
- Steps to reproduce or proof-of-concept (PoC) code/configuration.
- Potential impact on the host system or internal networks.
- Suggested mitigations or fixes, if known.

---

## Response Targets & SLA

We commit to the following response timeline:
- **Initial Acknowledgement**: Within 24 hours of receiving the report.
- **Triage & Assessment**: Within 72 hours to confirm severity and reproduction.
- **Fix & Patch Timeline**: Critical vulnerabilities are patched within 7 business days; non-critical within 30 days.
- **Public Disclosure**: Coordinated after the fix is released and users have had sufficient time to upgrade.
