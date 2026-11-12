# Known issues

## 0.7 development limitations

- **Native HLS downloads:** The system-managed download path does not have a demonstrated app-enforced in-flight byte cap. An oversized download can consume storage before it finishes; normal system storage management still applies. Quality, cancellation, storage-pressure and account/deletion checks remain open under [#214](https://github.com/schillt/velacanto/issues/214).
- **Standalone artists:** Library and Search use album-artist results. Some artists who appear only on standalone tracks may therefore be absent. A reliable bounded distinction between those artists and featured contributors has not been established; [#157](https://github.com/schillt/velacanto/issues/157) remains open.


See the [0.4 development record](0.4-development-record.md#remaining-acceptance-and-known-limits)
for integrated features and outstanding acceptance, and the
[0.3.5 known issues](0.3.5-known-issues.md) for retained release observations.
The [0.3 known issues](0.3-known-issues.md) remain historical evidence, not the current
implementation inventory. An issue carried forward is not necessarily a current
reproduction; each correction and acceptance result must identify its candidate.
