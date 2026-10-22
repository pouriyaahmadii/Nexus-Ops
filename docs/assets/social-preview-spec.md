# Social Preview Image Specification (1280×640)

## Purpose
This image appears when the repository link is shared on Twitter/X, LinkedIn, Slack, Discord, and GitHub itself. It should instantly communicate: **what this project is**, **its key value props**, and **look professional**.

## Design Specifications

### Canvas
- **Dimensions**: 1280 × 640 pixels (2:1 aspect ratio)
- **Format**: PNG (lossless) or JPEG (high quality, 90%+)
- **Safe zone**: Keep critical content within 1120 × 560 centered (10% margin)

### Color Palette
| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#2563eb` | Headers, primary actions, logo |
| Secondary | `#7c3aed` | Accents, gradients |
| Accent | `#06b6d4` | Highlights, flow lines |
| Dark BG | `#0f172a` | Background (dark mode) |
| Light BG | `#f8fafc` | Background (light mode) |
| Text Primary | `#f8fafc` | On dark |
| Text Secondary | `#94a3b8` | Subtitles, descriptions |

### Layout Structure

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   [LOGO]  NexusOps                          [GitHub Stars] │
│           Production-grade automation platform              │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │   🔒        │  │   ⚡        │  │   🤖        │        │
│  │ Encrypted   │  │  Queue      │  │  LLM Cost   │        │
│  │ Backups     │  │  Mode n8n   │  |  Tracking   |        │
│  └─────────────┘  └─────────────┘  └─────────────┘        │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │   🛡️        │  │   📊        │  │   🔄        │        │
│  │  Approvals  │  │ Observability│  │  Restore    │        │
│  │  & Escalate │  │  & Doctor   │  │   Drills    │        │
│  └─────────────┘  └─────────────┘  └─────────────┘        │
│                                                             │
│   docker compose up -d    |    make doctor    |    make demo│
│                                                             │
│   MIT License  •  Self-hosted  •  n8n + Traefik + Postgres  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Visual Elements

1. **Header** (top 80px)
   - Logo (left): Use `docs/assets/logo.svg` rendered at 48×48
   - Title: "NexusOps" — Inter Bold, 32px, Primary color
   - Subtitle: "Production-grade self-hosted automation platform" — Inter Medium, 18px, Text Secondary
   - GitHub stars badge (right): `![Stars](https://img.shields.io/github/stars/nexusops/nexusops?style=social)`

2. **Feature Grid** (middle 360px)
   - 3×2 grid of feature cards
   - Each card: Icon (24px), Title (Inter SemiBold, 16px), Description (Inter Regular, 14px)
   - Cards: Rounded corners (12px), subtle border, hover-like elevation
   - Icons: Use Heroicons or Phosphor (lock, zap, robot, shield, chart-bar, arrow-path)

3. **Command Bar** (bottom 80px)
   - Three pill buttons with commands:
     - `docker compose up -d` (Primary background)
     - `make doctor` (Secondary background)
     - `make demo` (Accent background)
   - Font: JetBrains Mono or Fira Code, 14px

4. **Footer** (bottom 40px)
   - Tags: "MIT License" · "Self-hosted" · "n8n + Traefik + Postgres + Redis + Qdrant"
   - Font: Inter Regular, 12px, Text Secondary

### Typography
- **Font Family**: Inter (fallback: system-ui, -apple-system, sans-serif)
- **Weights**: Regular (400), Medium (500), SemiBold (600), Bold (700)
- **Scale**: 12px / 14px / 16px / 18px / 32px / 48px

### Dark/Light Mode
- Design for **dark background** (`#0f172a`) as primary
- Ensure sufficient contrast for light mode viewing (test on white)
- Use `currentColor` for text that adapts

## Creation Instructions

### Option 1: Figma (Recommended)
1. Create 1280×640 frame
2. Set background to `#0f172a`
3. Build using components above
4. Export as PNG @2x (2560×1280) then downsample to 1280×640 for crispness

### Option 2: HTML + Puppeteer (Programmatic)
```html
<!-- Create social-preview.html, then: -->
<!-- npx puppeteer --screenshot=social-preview.png --viewport=1280,640 social-preview.html -->
```

### Option 3: Canva / Excalidraw
- Use the layout spec above as reference

## Verification Checklist
- [ ] Renders correctly on dark background (GitHub dark mode)
- [ ] Renders correctly on light background (Twitter card, LinkedIn)
- [ ] Text readable at 50% zoom (mobile preview)
- [ ] Logo recognizable at 48×48 (favicon size)
- [ ] Command text readable at 14px
- [ ] No text cut off at edges (10% safe margin)
- [ ] File size < 500 KB (optimize with `oxipng` or `imagemin`)

## File Placement
- Save as: `docs/assets/social-preview.png`
- Reference in repo settings → Social preview upload
- Reference in README: `![NexusOps](docs/assets/social-preview.png)` (optional)

## SVG Source (Alternative)
If you prefer an SVG that scales perfectly, create a 1280×640 SVG version of the above layout using the same gradients and components from `logo.svg`. Save as `docs/assets/social-preview.svg` and GitHub will use it automatically.

## Next Steps
1. Create the image using your preferred tool
2. Upload to `docs/assets/social-preview.png`
3. Upload to GitHub repository settings → Social preview
4. Verify on Twitter Card Validator and LinkedIn Post Inspector