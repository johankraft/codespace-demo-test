# Tracealyzer Codespaces template

Drop these files into your repository:

- `.devcontainer/devcontainer.json`
- `.devcontainer/Dockerfile`
- `scripts/start-tracealyzer-web.sh`

Then commit and push.

## What this gives you

- XFCE, TightVNC, noVNC and related packages are baked into the Codespace image.
- Port 6080 is forwarded automatically.
- Your interactive `start-tracealyzer-web.sh` only needs to do Tracealyzer-specific runtime setup.

## First run

Run:

```bash
scripts/start-tracealyzer-web.sh
```

## Recommended next step

Enable GitHub Codespaces prebuilds for the repository so the devcontainer image is prepared ahead of time.
