# Contributing to NexusOps

Welcome to NexusOps. We welcome contributions that maintain our high standards of reliability, security, and cleanliness.

---

## 1. Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/nexusops.git
   cd nexusops
   ```
2. Copy the sample environment file:
   ```bash
   cp .env.example .env
   ```
3. Install pre-commit hooks:
   ```bash
   pip install pre-commit
   pre-commit install
   ```

---

## 2. Branch Naming Strategy

Branches should follow the format: `<type>/<short-description>`

Allowed prefixes:
- `feat/`: New feature or capability
- `fix/`: Bug fix or reliability patch
- `docs/`: Documentation updates
- `chore/`: Tooling, dependency, or repository maintenance
- `refactor/`: Code reorganization without functional changes
- `test/`: Adding or modifying tests

*Examples:*
- `feat/traefik-ingress`
- `fix/redis-auth`
- `chore/pre-commit-hooks`

---

## 3. Conventional Commits

We strictly follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification:

```text
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types
- `feat`: A new feature
- `fix`: A bug fix
- `docs`: Documentation only changes
- `style`: Changes that do not affect the meaning of the code
- `refactor`: A code change that neither fixes a bug nor adds a feature
- `perf`: A code change that improves performance
- `test`: Adding missing tests or correcting existing tests
- `chore`: Changes to build process, tooling, or auxiliary files

---

## 4. Running Quality Checks

Before submitting changes, run:
```bash
# Display help and verify targets
make help

# Run linting checks
make lint

# Run pre-commit checks across all files
pre-commit run --all-files
```
