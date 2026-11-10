# Unique Router Link

A tiny macOS "browser" that imitates Arc's Air Traffic Control: it registers as the default browser, then forwards every link to the right real browser based on rules. Work links go to Helium, everything else to Chrome.

It has no window or Dock icon. macOS launches it on the first link, and it stays running in the background.

## Install

```sh
./install.sh
```

This builds with `swiftc`, installs `~/Applications/Unique Router Link.app`, registers it with Launch Services, and creates `~/.config/unique-router-link/rules.json` from `rules.example.json` if it doesn't exist.

Then pick **Unique Router Link** in System Settings → Desktop & Dock → Default web browser.

## Rules

`~/.config/unique-router-link/rules.json` is re-read for every link, so edits apply immediately.

```json
{
  "defaultBrowser": "com.google.Chrome",
  "rules": [
    {
      "browser": "net.imput.helium",
      "hosts": ["your-company.example"],
      "urlPrefixes": ["github.com/your-org"],
      "sourceApps": ["com.microsoft.Outlook", "Slack"]
    }
  ]
}
```

- `hosts` matches the domain and all its subdomains.
- `urlPrefixes` matches host + path at a path boundary (`github.com/acme` doesn't match `github.com/acme-other`). Use it for shared sites.
- `sourceApps` matches the app the link was clicked in, by bundle ID or name.
- The first matching rule wins; links that match nothing go to `defaultBrowser`.
- If the file is missing or invalid, every link goes to Chrome and the error is logged.

## Debugging

- Log: `~/Library/Logs/UniqueRouterLink.log` records the source app, host, matched rule and target browser (hosts only, never full URLs).
- Dry run without opening anything:

  ```sh
  ~/Applications/Unique\ Router\ Link.app/Contents/MacOS/UniqueRouterLink --explain <url> [--from <bundle-id-or-name>]
  ```

## Uninstall

Set another default browser, run `pkill -x UniqueRouterLink`, and delete `~/Applications/Unique Router Link.app`.
