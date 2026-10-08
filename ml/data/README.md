# Data

Generated and raw data live here and are not committed (see `.gitignore`).

| File | Made by | What it is |
|---|---|---|
| `selfplay.csv` | `npm run selfplay` in `game/` | Simulated rallies in the model's feature format. Bootstraps the model. |
| `tracks.csv` | `dink-ml track` | Per-frame player and ball positions from footage. |
| `rallies.csv` | You (hand-labelled) | `rally_id,start_frame,end_frame,winner` with winner `near` or `far`. |
| `shots.csv` | `dink-ml shots` | Real shots in the model's feature format, labelled by rally outcome. |

Train on real shots as soon as you have them, optionally mixed with self-play:
`dink-ml train data/shots.csv data/selfplay.csv --out ../game/public/models --source "PPA 2026 + self-play"`
