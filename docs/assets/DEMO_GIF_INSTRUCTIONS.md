# Demo GIF Recording Instructions

## Target
Create a **60-second GIF** (`docs/assets/demo.gif`) that demonstrates the NexusOps platform value in a single view. Used in README and social media.

## Recording Specifications

| Parameter | Value |
|-----------|-------|
| **Duration** | 60 seconds max |
| **Dimensions** | 1280 × 720 (16:9) or 1280 × 800 |
| **Frame Rate** | 15 FPS (reduces file size) |
| **Format** | GIF (optimized) or MP4 → GIF conversion |
| **File Size** | < 5 MB (target 2-3 MB) |
| **Quality** | Clear text, smooth motion |

## Recording Script (60 Seconds)

| Time | Action | What Viewer Sees | Key Moments |
|------|--------|------------------|-------------|
| **0-5s** | **Intro** | Terminal: `make up` → containers starting | Containers healthy badges |
| **5-10s** | **Health Check** | `make doctor` → all PASS (green) | "All systems green" |
| **10-15s** | **Dashboard** | Browser: n8n dashboard with 4 workflows | Core workflows visible |
| **15-25s** | **Demo Request (Low Risk)** | `curl` POST to `/webhook/triage` → JSON response | `risk_level: "low"`, `approval_status: "not_required"` |
| **25-35s** | **Demo Request (High Risk)** | `curl` POST with `$200` → approval pending | `approval_status: "pending"` |
| **35-45s** | **Approval Flow** | Telegram: inline ✅/❌ buttons → click ✅ → response updates to `approved` | Real-time approval |
| **45-55s** | **Retry & Cost** | Terminal: `make doctor` shows LLM cost > $0, retry count | Cost tracking visible |
| **55-60s** | **Outro** | Terminal: `make demo` summary table | Cost, approval, DLQ all non-zero |

## Recording Tools

### Option 1: asciinema + agg (Terminal-only, smallest)
```bash
# Install
pip install asciinema agg

# Record
asciinema rec demo.cast -c "bash scripts/demo.sh run"

# Convert to GIF
agg demo.cast demo.gif --theme dracula --font-size 14 --cols 120 --rows 35
```

### Option 2: Peek (Linux) / Kap (macOS) - Screen region
```bash
# Peek (Linux)
sudo apt install peek
# Record 1280×720 region covering terminal + browser split

# Kap (macOS)
brew install kap
# Record 1280×720 region
```

### Option 3: OBS Studio (Full control)
```bash
# OBS Studio
# 1. Add "Window Capture" for terminal
# 2. Add "Window Capture" for browser (side-by-side or picture-in-picture)
# 3. Set output: 1280×720, 15 FPS, GIF encoder
# 4. Record following script
```

### Option 4: asciicast2gif (Pure terminal)
```bash
npm install -g asciicast2gif
asciinema rec demo.cast
asciicast2gif demo.cast demo.gif -s 2 -h 35 -w 120
```

## Detailed Recording Steps

### Setup (Before Recording)
```bash
# 1. Clean environment
make clean
cp .env.example .env
# Edit .env with demo values (use mock mode)
# DEMO_MODE=mock
# MOCK_FAILURE_RATE=0.3

# 2. Start clean
make up

# 3. Wait for health (60s)
make doctor

# 4. Position windows
# Terminal: left 60% (1280px wide)
# Browser: right 40% (800px wide) - n8n dashboard
```

### Recording Timeline (with commands)

| Second | Terminal Command | Browser Action |
|--------|------------------|----------------|
| 0-5 | `make up` (already running) | — |
| 5-10 | `make doctor` | — |
| 10-15 | — | Refresh n8n dashboard |
| 15-25 | `curl -X POST http://localhost/webhook/triage -H "Content-Type: application/json" -d '{"text":"General question about API","email":"user1@example.com"}'` | — |
| 25-35 | `curl -X POST http://localhost/webhook/triage -H "Content-Type: application/json" -d '{"text":"I want a refund for my $200 subscription","email":"user2@example.com","amount_usd":200}'` | — |
| 35-45 | — | Open Telegram, click ✅ Approve |
| 45-55 | `make doctor` | — |
| 55-60 | `bash scripts/demo.sh run` | — |

### Pro Tips
- **Pre-type commands** in terminal history (up-arrow to recall)
- **Use a second terminal** for `watch -n 2 'docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.approvals WHERE status='pending';"'` to show real-time approval
- **Slow down** — type at ~60 WPM, pause 1s between commands
- **Highlight output** with `bat` or `jq .` for JSON

## Post-Processing

### Optimize GIF
```bash
# Install gifsicle
brew install gifsicle  # macOS
sudo apt install gifsicle  # Linux

# Optimize
gifsicle -O3 --lossy=80 --colors 256 -o demo-optimized.gif demo.gif

# Check size
ls -lh demo-optimized.gif
# Target: < 5 MB
```

### Alternative: MP4 → GIF (better quality)
```bash
# Record as MP4 first (OBS, Kap, etc.)
ffmpeg -i demo.mp4 -vf "fps=15,scale=1280:-1:flags=lanczos,palettegen" palette.png
ffmpeg -i demo.mp4 -i palette.png -filter_complex "fps=15,scale=1280:-1:flags=lanczos[palette]" demo.gif
```

## File Placement
```
docs/assets/
├── demo.gif           # Final optimized GIF (2-3 MB)
├── demo.mp4           # Source MP4 (optional, for re-encoding)
└── demo.cast          # asciinema source (optional)
```

## README Embedding
```markdown
![NexusOps Demo](docs/assets/demo.gif)
```

## Quality Checklist
- [ ] Duration ≤ 60 seconds
- [ ] Text readable (terminal font ≥ 14px, browser text clear)
- [ ] All 6 key moments visible
- [ ] No sensitive data (real tokens, IPs, emails)
- [ ] File size < 5 MB
- [ ] Loops smoothly (no jarring jump at end)
- [ ] Works on GitHub README (test by opening raw GIF URL)

## Alternative: Static Screenshots + Caption
If GIF proves too large or complex, use 4 static screenshots with captions in README:
```markdown
| `make doctor` | n8n Dashboard | Approval Flow | Cost Summary |
|:---:|:---:|:---:|:---:|
| ![](docs/assets/screenshots/05-doctor-output.png) | ![](docs/assets/screenshots/01-n8n-dashboard.png) | ![](docs/assets/screenshots/04-approval-telegram.png) | ![](docs/assets/screenshots/10-cost-report.png) |
| All PASS | 4 workflows | Telegram ✅/❌ | $0.0045 / req |
```

## Next Steps
1. Choose recording tool
2. Practice script 2-3 times
3. Record 2-3 takes, pick best
4. Optimize with gifsicle
5. Place in `docs/assets/demo.gif`
5. Update README with embed