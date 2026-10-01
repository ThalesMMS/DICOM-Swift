# Releasing DICOM-Swift

The public repository is a manually synchronized source mirror. Develop and
review changes in the canonical package with its application consumers. Keep
application path dependencies unchanged. Publication is an explicit maintainer
task; a package commit alone does not authorize it.

1. Select the reviewed canonical commit after dependent changes and proportional
   local validation. Record its package tree, checks, toolchain and limits internally.
2. Export tracked content with `Tools/Scripts/export_dicom_swift.py` from the
   canonical repository. Use a new destination outside that checkout and keep
   the internal `--record` outside the export. Never copy a working directory or
   push application history. See [Distribution](DISTRIBUTION.md).
3. Clone the public mirror independently. Compare the exported tree with its
   tracked files, reviewing additions, changes and removals before replacing
   obsolete sources. Preserve `.git` and the existing public history. Do not
   retain old manifests, duplicate sources or hosted workflows from the old
   mirror as part of the new distribution. All content changes belong in the
   canonical source or declared export adaptations, never mirror-only fixes.
4. Verify the staged mirror with the export tool's `verify` operation and internal
   record. `DistributionContents.json` records hashes and declared adaptations;
   `DistributionProvenance.json` derives component origins and materials from
   the existing inventory. Preserve original LICENSE and component notices.
   Export rejects stale origin destination patterns and incorporation paths;
   update the canonical inventory when sources move rather than remapping
   attribution silently during publication.
5. Validate the isolated export using full Xcode's Swift toolchain. Run the
   target-boundary validator, the existing minimal client consumer in Debug and
   Release, focused client XCTest and builds of affected announced products.
   Reuse canonical results for unchanged scopes. Do not rerun every codec or
   runtime solely because identical sources were exported. Record all failures,
   absent optional runtimes and skipped tests separately from passes.
6. Review breaking changes and choose a new version. Swift 5→6 language changes
   and reorganized products/APIs support a major version after 1.5.0. Tools 6.2
   and Apple-platform 26.0 minimums are already required by 1.5.0. Prefer a prerelease candidate if consumer acceptance is pending.
   Release notes state tools/language/platforms, products, breaks, tested scope
   and optional-runtime limits; no binary asset or XCFramework is required.
7. Commit the reviewed export on top of the public mirror history. Record the
   public commit against the canonical commit/tree internally. Push only this
   public content commit, then create a new immutable version tag at it. Never
   move or overwrite an existing tag. Publish release notes after validation.
   Before pushing, run `verify-tree --repo-root <mirror> --revision <commit>
   --record <internal-record>` to compare the actual committed files and modes,
   independent of dirty or untracked working files. After pushing/tagging, run
   the same check on the remotely fetched commit and tag target.
8. Resolve the tag and commit through public HTTPS without private credentials.
   Verify a fresh checkout and a remote minimal consumer; hand its exact version
   and commit to application integration. Application acceptance uses its own
   lockfile and real remote package, with local overrides removed.

The optional broad `Scripts/test_gates.sh release` performs preflight, Release
build and the complete test suite, with required external codec capabilities.
Use it for broader runtime qualification when that scope is explicitly needed;
missing capabilities fail that gate. `quick`, `fixture` and `runtime` retain
separate scopes. Existing gate coverage summaries under `.build/runtime-coverage`
remain local evidence, never public package inputs. No hosted checks are required.

Publication is complete only when the published tag identifies the validated
content and the remote consumer resolves it. Preparation, push of a canonical
branch and skipped validation do not satisfy this condition.
