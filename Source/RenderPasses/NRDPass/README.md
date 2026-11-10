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

# Sparse diffuse history

The two RTPT graphs use a diffuse regular-history cap of 16 and retain the
fast-history cap of 2. Their `diffuseHistoryClampingSigmaScale=4` widens only
the diffuse color box, reducing repeated clipping of rare positive samples.
Specular continues to use the SDK's shared clamping sigma. Spatial luminance,
normal, depth and material weights keep their existing settings.

`diffuseHistoryClampingDarkThreshold=0.0002` is in unscaled, demodulated BT.601
diffuse radiance units. The adapter converts it with `diffuseRadianceScale`
and uses the existing 5x5 fast-history mean. From the threshold to four times
the threshold, it smoothly changes from the SDK's shared sigma to the diffuse
override. Near black this restores tighter clamping and avoids extending the
weak residual after illumination disappears. It does not classify one noisy
zero-valued sample as a lighting change.

Both properties default to zero. A zero sigma override keeps the original SDK
shader; a zero dark threshold disables the transition. The transition is active
only with a positive sigma override. The adapter applies to NRD 3.1
`RelaxDiffuseSpecular`; other methods keep their original pipeline. Changing
either UI value rebuilds the denoiser and resets history. The local shader
preserves the SDK's constants, resource bindings, history layout and FP16 pools.

The Veach door-scene investigation and same-input validation are retained in
[`build/relax-sparse-fix/`](../../../build/relax-sparse-fix/). The profile was
selected with 1 spp and unchanged materials; static bias, temporal variation
and dynamic residuals are measured separately.
