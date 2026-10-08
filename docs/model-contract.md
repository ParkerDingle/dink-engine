# Model contract: `dink-features-v1`

Input: `features`, float32 `[N, 21]`, one row per candidate shot. Output: `probabilities`, float32
`[N, 2]`; column 1 is the probability that the hitting team wins the rally.

All positions are from the hitter's point of view, in feet. Defined in `game/src/engine/features.ts` and
`ml/dink_ml/features.py`, with a Luau copy in `roblox/src/shared/Features.luau`; `ml/tests/test_features.py`
and `roblox/tests/run.luau` check them against a fixture produced by the game code. Changing a feature means bumping `FEATURE_VERSION` in both and retraining; the game ignores a
model whose card names a different version.

| # | Name | Meaning |
|---|---|---|
| 0 | `hit_x` | Contact point, feet to the hitter's right of the center line |
| 1 | `hit_d` | Contact point distance from the net (ft) |
| 2 | `hit_h` | Contact height (ft) |
| 3 | `in_speed` | Incoming ball speed (ft/s) |
| 4 | `shot_no` | Shot number in the rally (2 = return), capped at 12 |
| 5 | `partner_x` | Partner, feet to the hitter's right |
| 6 | `partner_d` | Partner distance from the net |
| 7 | `oppA_x` | Opponent further to the hitter's left |
| 8 | `oppA_d` | Its distance from the net |
| 9 | `oppB_x` | The other opponent |
| 10 | `oppB_d` | Its distance from the net |
| 11 | `opp_up` | Opponents within 9.5 ft of the net (0–2) |
| 12 | `my_up` | Hitting team within 9.5 ft of the net (0–2) |
| 13 | `t_dink` | 1 if the shot is a dink, else 0 |
| 14 | `t_drop` | 1 if the shot is a drop, else 0 |
| 15 | `t_drive` | 1 if the shot is a drive, else 0 |
| 16 | `t_speedup` | 1 if the shot is a speedup, else 0 |
| 17 | `t_lob` | 1 if the shot is a lob, else 0 |
| 18 | `t_putaway` | 1 if the shot is a putaway, else 0 |
| 19 | `tgt_x` | Target, feet to the hitter's right |
| 20 | `tgt_d` | Target distance from the net on the far side |

Training label: `won` (1 if the hitting team won the rally). Rows also carry `rally_id` so validation
splits keep whole rallies together.

The Roblox game can't run ONNX, so `ml/dink_ml/export_luau.py` also writes the trained trees as Luau
tables (`roblox/src/shared/ShotModel.luau`), with `M.predict(x)` returning the column-1 probability.
The export is checked against LightGBM in Python and again in the Luau tests.
