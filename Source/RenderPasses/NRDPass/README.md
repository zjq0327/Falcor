# NRD radiance units

`RTPTNRD.py` and `RTPTSHARCNRD.py` use the selected V-door-scene scheme:

- Pack diffuse RGB at `1/256` and specular RGB at `1/512`, before the intensity clamp.
- Keep NRD's texture pools, moments and filtered outputs in FP16.
- Set RELAX `specularVarianceBoost` to `1/(512*512)` in these scaled units.
- Restore diffuse RGB by `256` and specular RGB by `512` in `ModulateIllumination`, before material modulation into the existing FP32 final image.

Hit distance, depth, normal, motion, reflectance, emission and residual radiance
keep their original units. The separate delta-reflection denoiser is unchanged.
The clamp remains `250` in NRD units, equivalent to original BT.601 luminance
limits of `64000` for diffuse and `128000` for specular. It is still a finite
limit; this scheme is not a guarantee against clipping in every scene.

`diffuseRadianceScale` and `specularRadianceScale` are multipliers local to each
pass. Use reciprocal pairs for NRD and ModulateIllumination. NRD's disabled
path applies the input scales before writing FP16, so toggling denoising does
not change the units or require changing the downstream reconstruction.
Both passes default to multipliers of `1` for existing graphs.

Only the V-scene input range and selected quality tradeoff have been measured.
No logarithmic transform, FP32 NRD pools or additional filter tuning is included.
The optional NRD property `timeDeltaBetweenFrames` is in milliseconds. It
defaults to `0` (SDK wall-clock timing). The experiment's fixed 15 fps replay
sets it to `1000/15` for validation; neither RTPT graph overrides this default.
