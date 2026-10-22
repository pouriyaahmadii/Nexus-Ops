# GitHub Repository Setup Checklist

## Repository Settings

### Basic Information
- [ ] **Repository name**: `nexusops` (or your preferred name)
- [ ] **Description**: "Production-grade self-hosted automation platform built on n8n, Traefik, PostgreSQL, Redis, and Qdrant. Features encrypted backups, LLM cost tracking, human-in-the-loop approvals, and comprehensive observability."
- [ ] **Website**: `https://github.com/nexusops/nexusops` (or your docs URL)
- [ ] **Topics** (add all):
  - `docker`
  - `docker-compose`
  - `n8n`
  - `automation`
  - `self-hosted`
  - `traefik`
  - `postgresql`
  - `redis`
  - `qdrant`
  - `devops`
  - `ai-agents`
  - `mlops`
  - `infrastructure-as-code`
  - `observability`
  - `backup`

### Social Preview
- [ ] **Upload social preview image**: `docs/assets/social-preview.png` (1280×640)
- [ ] Verify preview renders correctly on repo page and shared links

### Features
- [ ] **Issues**: Enabled
- [ ] **Discussions**: Enabled (for community Q&A)
- [ ] **Wiki**: Disabled (docs in `/docs` instead)
- [ ] **Projects**: Enabled (for roadmap tracking)
- [ ] **Security advisories**: Enabled
- [ ] **Dependency graph**: Enabled
- [ ] **Dependabot alerts**: Enabled

## Branch Protection Rules

### Main Branch (`main`)
Configure in Settings → Branches → Branch protection rules → Add rule:

**Branch name pattern**: `main`

**Protect matching branches**:
- [x] **Require a pull request before merging**
  - [x] Required approving reviews: `1`
  - [x] Dismiss stale PR approvals when new commits are pushed
  - [x] Require review from Code Owners
  - [ ] Restrict who can dismiss pull request reviews (optional)
- [x] **Require status checks to pass before merging**
  - [x] Require branches to be up to date before merging
  - Required status checks (exact names from CI):
    - `Lint`
    - `n8n Workflows`
    - `Smoke Test`
    - `SQL Tests`
    - `Gitleaks`
    - `Trivy Filesystem`
    - `Trivy Config`
    - `Trivy Image`
- [x] **Require conversation resolution before merging**
- [x] **Require linear history** (no merge commits)
- [ ] **Require signed commits** (optional — enable if team uses GPG)
- [ ] **Require signed tags** (optional)
- [ ] **Require deployments to succeed before merging** (optional)
- [x] **Do not allow bypassing the above settings**
- [x] **Restrict who can push to matching branches** (admins only)
- [x] **Allow force pushes** → **No** (disabled)
- [x] **Allow deletions** → **No** (disabled)

### Develop Branch (if using)
Same rules as `main`, but can be less strict (e.g., no required reviews).

## Repository Secrets & Variables

### Settings → Secrets and variables → Actions

#### Repository Secrets (Required for CI/CD)
| Secret | Description | Source |
|--------|-------------|--------|
| `GITHUB_TOKEN` | Auto-provided by GitHub | Automatic |
| *(none required for standard CI)* | GHCR push uses `GITHUB_TOKEN` | — |

#### Repository Variables (Optional)
| Variable | Description | Example |
|----------|-------------|---------|
| `DOCKER_REGISTRY` | Override registry (default: ghcr.io) | `ghcr.io` |
| `RELEASE_PLEASE_TOKEN` | For release-please (if not using GITHUB_TOKEN) | `ghp_...` |

#### Environment Secrets (for Production Deploy)
Create environment `production` with:
| Secret | Description |
|--------|-------------|
| `SSH_PRIVATE_KEY` | For server deploy |
| `SERVER_HOST` | Production server IP |
| `SERVER_USER` | SSH user |

## GitHub Pages (Optional Docs Site)

If you want a hosted docs site:

1. Settings → Pages → Build and deployment
2. Source: **GitHub Actions**
3. Create `.github/workflows/docs.yml`:
```yaml
name: Deploy Docs
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node
        uses: actions/setup-node@v4
        with: { node-version: '20' }
      - name: Install dependencies
        run: npm ci
      - name: Build docs
        run: npm run build
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with: { path: ./docs/.vitepress/dist }
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```
4. Settings → Pages → Custom domain (optional): `docs.nexusops.example.com`

## Code Owners

Create `.github/CODEOWNERS`:
```text
# Global owners
* @nexusops/core-team

# Infrastructure
/infra/ @nexusops/infra-team
/compose*.yaml @nexusops/infra-team
/Makefile @nexusops/infra-team

# Workflows
/workflows/ @nexusops/workflow-team
/scripts/check-workflows.sh @nexusops/workflow-team

# Documentation
/docs/ @nexusops/docs-team

# CI/CD
/.github/workflows/ @nexusops/ci-team

# Security
/.github/dependabot.yml @nexusops/security-team
```

## Labels

Create standard labels in Issues → Labels:

| Label | Color | Description |
|-------|-------|-------------|
| `bug` | `#d73a4a` | Something isn't working |
| `enhancement` | `#a2eeef` | New feature or request |
| `documentation` | `#0075ca` | Documentation improvements |
| `good first issue` | `#7057ff` | Good for newcomers |
| `help wanted` | `#008672` | Extra attention needed |
| `security` | `#ee0701` | Security-related |
| `dependencies` | `#0366d6` | Dependency updates |
| `ci/cd` | `#fbca04` | CI/CD pipeline changes |
| `infra` | `#5319e7` | Infrastructure changes |
| `workflows` | `#c5def5` | n8n workflow changes |
| `breaking change` | `#b60205` | Breaking API/behavior change |
| `needs triage` | `#ededed` | Needs initial review |
| `wontfix` | `#ffffff` | This will not be worked on |

## Milestones

Create milestones for releases:
- `v1.0.0` — Initial release
- `v1.1.0` — Monitoring stack, improved demo
- `v1.2.0` — Multi-tenancy, RBAC
- `v2.0.0` — Kubernetes support

## Repository Templates

### Issue Templates (already in `.github/ISSUE_TEMPLATE/`)
- [x] Bug report
- [x] Feature request
- [ ] Security vulnerability (private)

### Pull Request Template (already in `.github/pull_request_template.md`)
- [x] Checklist: tests, docs, breaking changes, security, conventional commits

## Automation

### Dependabot (already in `.github/dependabot.yml`)
- Weekly updates for GitHub Actions, Docker base images, compose tags
- Labels: `dependencies`, `github-actions`, `docker`

### Release Please (in `.github/workflows/release.yml`)
- Conventional Commits → automated release PR
- On release: multi-arch backup image to GHCR + SBOM + release archive

### Scheduled Workflows
- Security scans: Weekly Monday 02:00 UTC
- Restore drills: Weekly Sunday 04:00 UTC

## Security Settings

### Settings → Security & analysis
- [x] Dependency graph
- [x] Dependabot alerts
- [x] Dependabot security updates
- [x] Secret scanning
- [x] Secret scanning push protection
- [x] Code scanning (CodeQL) — optional, enable if desired

### Private vulnerability reporting
- [x] Enable "Private vulnerability reporting"
- Set contact: `security@nexusops.example.com`

## Notifications

### Watching
- Core team: **Watch all** (all notifications)
- Contributors: **Participating and @mentions**

### Webhooks (optional)
- Slack/Discord webhook for release notifications
- PagerDuty/Opsgenie for CI failures

## Final Verification

After setup, verify:

1. [ ] Create a test PR → all status checks run and pass
2. [ ] Merge test PR → release-please creates release PR
3. [ ] Create test issue → labels work, assignees work
4. [ ] Push to main → CI runs, security scans run
5. [ ] Check social preview on repo page
6. [ ] Verify branch protection blocks direct pushes to main
7. [ ] Verify CODEOWNERS triggers reviews
8. [ ] Test Dependabot PR created for action update

## Maintenance

### Monthly
- Review Dependabot PRs
- Update pinned action SHAs in workflows
- Review and merge security advisories
- Check disk usage on runners

### Quarterly
- Review and update topic tags
- Audit repository secrets
- Review branch protection rules
- Update CODEOWNERS for team changes

## Next Steps
- [Contributing Guide](../CONTRIBUTING.md)
- [CI/CD Guide](contributing-ci.md)
- [Operations Guide](operations.md)