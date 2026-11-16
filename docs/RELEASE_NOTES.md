Read-only stem export for Tascam DP-32SD songs. The zip holds **DP32 Export.app**,
the `dp32export` command-line tool, the README and the license. Apple Silicon and Intel, macOS 13 or later.

**First launch:** the app is ad-hoc signed, not notarized by Apple. After unzipping,
open it once, then go to **System Settings → Privacy & Security** and click
**Open Anyway**. Or, in Terminal:

```sh
xattr -dr com.apple.quarantine "DP32 Export.app"
```

See the README for what it does and `docs/FORMAT.md` for how the DP-32SD format
was worked out and what is still unverified.
