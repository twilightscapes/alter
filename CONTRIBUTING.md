# Contributing to Alter

Thank you for helping. Issues and pull requests are welcome.

## Sign your commits

Alter uses the [Developer Certificate of Origin](https://developercertificate.org).
Add a sign-off line to each commit to certify you wrote the change, or have
the right to submit it under the project's license:

```bash
git commit -s
```

This adds `Signed-off-by: Your Name <you@example.com>` to the message.

## Ground rules

- **Never modify an Aperture library.** Alter reads them in place. Anything
  that writes inside an `.aplibrary` package will not be merged.
- New source files carry the MPL-2.0 header used throughout `Core/`.
- Keep the core free of paid features. If a feature needs a hook for an
  extension, add it to `Core/Extensions/AlterExtensions.swift` with a default
  of "add nothing".
- Match Aperture's behaviour and keyboard shortcuts where Aperture had them.
