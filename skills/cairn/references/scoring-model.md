# How Cairn's scoring works

The default scorer is a time-decayed Beta-distribution model. **Numbers below describe the default config; deployments can retune the half-life and weight functions, so treat the specifics as approximate.** Three things to keep in mind when deciding when and what to rate:

- **Ratings exponentially decay** with a 3-day half-life. A source rated highly six months ago with no follow-up reads as "no signal," not "still trusted." Reputation has to be maintained — silence is a slow drift back to the prior.
- **Confidence accrues with evidence.** Roughly 5 decayed observations to reach `confidence ≈ 0.5`, ~15 for ~0.75. Submitting ratings continuously matters more than rating once carefully.
- **One rating's effect is bounded.** A single 0.0 against a high-confidence source barely moves the composite; sustained low ratings are what drive a score confidently below 0.5. Use the full range honestly — a calibrated 0.4 today doesn't blackball a source.
