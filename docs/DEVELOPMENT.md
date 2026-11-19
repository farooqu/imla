# Developing Imla

## Build

Needs the Xcode Command Line Tools (or Xcode), CMake, Git, and [uv](https://docs.astral.sh/uv/).

```sh
./scripts/build-app.sh   # builds the runtime if needed, then builds, signs, and installs ~/Applications/Imla.app
./scripts/test.sh        # unit tests
uv run --with pillow scripts/make-icon.py   # rebuilds Resources/AppIcon.icns from AppIcon-source.png
```

`scripts/build-runtime.sh` builds a pinned NeMo-Speech.cpp ASR library and libllama from its llama.cpp submodule, so both share one ggml, into `.runtime/lib`; the app carries them in `Contents/Frameworks`. Without Xcode, the scripts use the Command Line Tools.

`build-app.sh` signs with `$IMLA_SIGN_IDENTITY`, else an "Imla Release" or Apple Development certificate in your keychain, else ad hoc. Use a certificate: macOS forgets the Microphone and Accessibility grants of an ad hoc signed app every time it's rebuilt. Local builds never update themselves.

## Releases

Every push to `main` that changes the app is released. `.forgejo/workflows/tag.yml` runs on the upstream Forgejo repository, picks the version from the [Conventional Commits](https://www.conventionalcommits.org) since the last `v*` tag, and tags `main` with release notes written from the commit subjects as the tag message. `feat:` bumps the minor version, `fix:` and anything else the patch, and `feat!:` or a `BREAKING CHANGE:` footer the major (the minor while the version is 0.x). Only commits that change what ships in the app count (`Sources`, `Resources`, the package manifest, and the build scripts), so pushes with only documentation or other housekeeping don't tag anything.

`./scripts/release.sh` does the same from a local checkout, after showing the version and notes and asking to confirm, for a repository without the Forgejo workflow.

The Forgejo push mirror carries the tag to GitHub. There it starts `.github/workflows/release.yml`, which runs the tests, builds and signs the app, and publishes a GitHub release with `Imla.dmg` for new installs, and `Imla.zip` with a signed Sparkle `appcast.xml` for updates. Imla's updater reads the appcast from the latest release. If the tests or build fail, the tag stays without a release, and the next change gets the following version.

Releases are signed twice, without an Apple Developer account:

- a self-signed code signing certificate, which keeps macOS permissions and lets Sparkle accept the update as the same app;
- a Sparkle EdDSA key, which proves the update came from this project. Its public half is `SUPublicEDKey` in `Resources/Info.plist`.

`scripts/new-signing-keys.sh` creates both and stores them in Bitwarden. Create them once: a new certificate resets every user's permissions, and a new Sparkle key can't update apps that trust the old one. The workflow needs these repository secrets:

| Secret | Value |
|---|---|
| `IMLA_SIGNING_P12_BASE64` | The certificate and its private key, as a base64 PKCS#12 |
| `IMLA_SIGNING_P12_PASSWORD` | The PKCS#12 password |
| `SPARKLE_ED_PRIVATE_KEY` | The Sparkle private key, base64 |
