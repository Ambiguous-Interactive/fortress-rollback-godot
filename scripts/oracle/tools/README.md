# Reviewed TLC build

`tla2tools-94d0c507.jar` preserves the already-reviewed development-only TLC jar
downloaded from the upstream `v1.8.0` prerelease on October 10, 2026.
Its embedded manifest identifies revision
`94d0c5070852b37b801bb8998c436383ab7ee37b`, built October 6, 2026.
SHA256: `7beec0f04818732a62fa193731711a99aa4f11279499b2360a7d156c519ea78d`.
No jar bytes or model-checking contracts changed when preserving this fixture.
It is never included in the shipped Godot addon.

The [upstream workflow at that revision](https://github.com/tlaplus/tlaplus/blob/94d0c5070852b37b801bb8998c436383ab7ee37b/.github/workflows/main.yml)
deletes and replaces the prerelease asset and force-moves the `v1.8.0` tag.
The [October 6 build](https://github.com/tlaplus/tlaplus/actions/runs/37399524063)
establishes build provenance. On October 13 the same download URL instead served
revision `210df3af8aff4f6032bf9be459d5a911d079da6d`, with SHA256
`c0d2f72abc30e92871bb16c56f6878612eccd936bf7ca5fa7e4e324200a0a5c4`.
The fixture avoids upgrading the verifier whenever the upstream asset changes.

The original licenses and notices remain embedded in the unmodified jar:
`License.txt`, `META-INF/LICENSE.md`, `CommonsMath-LICENSE.txt`,
`CommonsMath-NOTICE.txt`, `jline-LICENSE.txt` and the duplicate Commons Math
license/notice under `org/apache/commons/math3/`.
[TLC license](TLC-LICENSE.txt) and [third-party notices](THIRD-PARTY-NOTICES.txt)
are also preserved alongside it.
