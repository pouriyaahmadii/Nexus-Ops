# Screenshots Placeholders & Capture Instructions

## Required Screenshots

| Filename | Dimensions | Description | Capture Instructions |
|----------|------------|-------------|----------------------|
| `docs/assets/screenshots/01-n8n-dashboard.png` | 1920×1080 | n8n main dashboard with workflows list | 1. Log into n8n UI<br>2. Show 3-4 workflows (core + demo)<br>3. Capture full browser window |
| `docs/assets/screenshots/02-workflow-editor.png` | 1920×1080 | Workflow editor showing triage workflow | 1. Open `showcase_ai_ops` workflow<br>2. Zoom to show all nodes<br>3. Show connections clearly |
| `docs/assets/screenshots/03-execution-log.png` | 1920×1080 | Execution log with retry + cost | 1. Run demo workflow<br>2. Open execution detail<br>4. Show retry attempts + cost |
| `docs/assets/screenshots/04-approval-telegram.png` | 800×1200 | Telegram approval message with buttons | 1. Trigger high-risk request<br>2. Screenshot Telegram on mobile/desktop<br>3. Show ✅/❌ buttons clearly |
| `docs/assets/screenshots/05-doctor-output.png` | 1600×900 | `make doctor` passing output | 1. Run `make doctor`<br>2. Resize terminal to 160×40<br>3. Capture full output |
| `docs/assets/screenshots/06-grafana-dashboard.png` | 1920×1080 | Grafana overview dashboard | 1. Enable monitoring profile<br>2. Import NexusOps dashboard<br>3. Show 1h time range |
| `docs/assets/screenshots/07-backup-list.png` | 1200×800 | `make backup-list` output | 1. Run `make backup`<br>2. Run `make backup-list`<br>3. Capture terminal |
| `docs/assets/screenshots/08-restore-test.png` | 1200×800 | `make restore-test` passing | 1. Run `make restore-test`<br>2. Capture final summary |
| `docs/assets/screenshots/09-traefik-dashboard.png` | 1920×1080 | Traefik dashboard with routers | 1. Access `http://localhost:8080` (base) or `https://traefik.domain` (prod)<br>2. Show HTTP routers tab |
| `docs/assets/screenshots/10-cost-report.png` | 1200×800 | Weekly LLM cost report in Telegram | 1. Wait for weekly report or trigger manually<br>2. Screenshot Telegram message |

## Capture Standards

### General
- **Resolution**: 1920×1080 minimum (downsample for web)
- **Format**: PNG (lossless) for UI, JPEG (90%) for photos
- **Theme**: n8n dark mode (default), system dark mode for OS
- **Browser**: Chrome/Chromium latest, 100% zoom
- **OS**: macOS (preferred) or Ubuntu with GNOME dark theme

### Terminal Screenshots
- **Terminal**: iTerm2 (macOS) or GNOME Terminal / Kitty (Linux)
- **Theme**: Dracula, Nord, or Catppuccin Mocha
- **Font**: JetBrains Mono 14pt or Fira Code 14pt
- **Size**: 160 cols × 40 rows minimum
- **Prompt**: Clean (no long paths), show command + output

### Mobile Screenshots (Telegram)
- **Device**: iPhone 15 Pro / Android 14 (or simulator)
- **Orientation**: Portrait
- **Theme**: System dark mode
- **Crop**: Remove status bar, navigation bar

### Dashboard Screenshots
- **Time range**: Last 1 hour (shows live data)
- **Refresh**: 30s or 1m
- **Panels visible**: All 6 panels in overview

## Capture Workflow

### 1. Prepare Environment
```bash
# Clean start
make clean
make up

# Wait for health
make doctor

# Run demo to populate data
make demo
```

### 2. Capture Sequence
```bash
# 1. Dashboard
open http://n8n.localhost
# → Screenshot 01

# 2. Workflow editor
# Click "showcase_ai_ops" → "Edit"
# → Screenshot 02

# 3. Execution log
# Click last execution → "Show details"
# → Screenshot 03

# 4. Doctor output
make doctor
# → Screenshot 05

# 5. Backup/Restore
make backup
make backup-list
# → Screenshot 07
make restore-test
# → Screenshot 08

# 6. Monitoring (if enabled)
COMPOSE_FILE=compose.yaml:compose.monitoring.yaml make up
open http://localhost:3000
# → Screenshot 06

# 7. Traefik
open http://localhost:8080
# → Screenshot 09
```

### 3. Post-Processing
```bash
# Optimize PNGs
brew install oxipng
oxipng -o 4 docs/assets/screenshots/*.png

# Or use imagemagick for JPEG
brew install imagemagick
magick mogrify -quality 90 docs/assets/screenshots/*.jpg
```

## File Naming Convention
```
docs/assets/screenshots/
├── 01-n8n-dashboard.png
├── 02-workflow-editor.png
├── 03-execution-log.png
├── 04-approval-telegram.png
├── 05-doctor-output.png
├── 06-grafana-dashboard.png
├── 07-backup-list.png
├── 08-restore-test.png
├── 09-traefik-dashboard.png
└── 10-cost-report.png
```

## Placeholder Files (Create Empty for Git)
```bash
touch docs/assets/screenshots/.gitkeep
# Create placeholder README
cat > docs/assets/screenshots/README.md << 'EOF'
# Screenshots

This directory contains UI screenshots for documentation and README.

See `SCREENSHOT_INSTRUCTIONS.md` for capture guidelines.

Files are gitignored (large binary). Placeholders tracked via `.gitkeep`.
Actual screenshots generated during release process.
EOF
```

## .gitignore Entry
```bash
# Add to .gitignore
docs/assets/screenshots/*.png
docs/assets/screenshots/*.jpg
docs/assets/screenshots/*.jpeg
!docs/assets/screenshots/.gitkeep
!docs/assets/screenshots/README.md
```

## Automation (Future)
Consider adding a GitHub Action to auto-capture screenshots on release:
```yaml
# .github/workflows/screenshots.yml
name: Capture Screenshots
on:
  release:
    types: [published]
jobs:
  screenshots:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Start stack
        run: make up
      - name: Wait for health
        run: make doctor
      - name: Run demo
        run: make demo
      - name: Capture screenshots
        run: |
          # Use Playwright/Puppeteer to capture
          npx playwright install
          node scripts/capture-screenshots.js
      - name: Upload to release
        uses: softprops/action-gh-release@v2
        with:
          files: docs/assets/screenshots/*.png
```

## Next Steps
1. Create placeholder directory: `mkdir -p docs/assets/screenshots`
2. Add `.gitkeep` and `README.md` to screenshots folder
3. Add `.gitignore` entries
4. Capture screenshots before v1.0.0 release
2. Update README with actual screenshot references