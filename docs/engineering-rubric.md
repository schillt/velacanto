# Engineering rubric and clean-code guardrails

Carried forward from the 0.3.5 planning contract at
`738923411414826996701ed9a991238b766079e0`; publication of this rubric does not
assign a grade to the release candidate.

## Reusable grading and clean-code guardrails

Historical 0.3 grade: **78/100, C+**, a previously recorded baseline assessment with
limited physical/distribution evidence. It is not a newly recomputed grade and
must not be assigned to 0.3.5. Preserve original per-category audit evidence when
publishing historical documents; do not fabricate missing subscores.

**Prospective rubric v1 (0.3.5 planning, 2026-09-23):** the six categories below
replace the historical eight-category assessment for future candidate reviews.
The rationale is to give explicit weight to playback correctness, async/network
reliability and ownership while retaining maintainability, verification/distribution
and accessibility as separate dimensions. This is a new evaluation model, not a
recalculation or renaming of the historical rubric. Its scores are **not directly
comparable** to the historical 78/100, C+; do not infer improvement from the totals
or reconstruct missing historical subscores. A comparison would require separately
scoring both exact candidates under this same version with adequate evidence.
Record the rubric version alongside every future grade.

For rubric v1 candidates score each category 0–100, attach evidence and uncertainty,
then apply these weights: correctness 30%; async/network reliability 25%; architecture
and ownership 20%; maintainability 10%; tests/build/distribution 10%; accessibility 5%.
Bands: A 90–100, B 80–89, C 70–79, D 60–69, F below60; plus for top three points and
minus for bottom three points within B/C/D. Any unverified gate stays pending even
if the score is high. Use this rubric consistently for future candidates; changing
weights requires an explicit versioned rationale, not retroactive grade inflation.

Require abstractions justified by current responsibilities, complete async
outcomes, explicit lifetime/teardown, and tests that catch behavior failures.
Avoid speculative extension points, generic managers, duplicate state machines,
warning suppression and comments that narrate obvious syntax. Function docs should
be concise multiline blocks describing contract and nonobvious ownership or
cancellation behavior. Keep P3 formatting/proven-unused-code removal separate from
runtime fixes; flag structural concerns instead of folding them into polish.

