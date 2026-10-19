# Automatic renewal with Shortcuts

A free Apple ID signs Harbor for seven days. A daily Shortcuts automation
keeps it renewed without opening Harbor. In the app this is Settings ›
Automatic Renewal; this page explains how it works and how to publish a
ready-made shortcut for your build.

## How it works

The shortcut is one action, **Open X-Callback URL**, with this link:

    harbor://x-callback-url/renew

Harbor does the rest:

1. It renews only what expires within two days: Harbor first, then the apps
   it installed. Most days nothing is due and the run ends at once.
2. It retries twice, after 5 and 15 seconds, when the problem is one that
   passes: LocalDevVPN still connecting, the iPhone or a server not
   answering.
3. It checks that each expiry date moved forward. Apple can hand back the
   profile it already issued; that counts as a failure, not a renewal.
4. It reports back to Shortcuts. On success Shortcuts receives `status`
   (`renewed` or `current`), `message` and `expires` (ISO 8601). On failure
   Harbor calls `x-error` with an `errorMessage`, so the automation stops
   and Shortcuts shows why.
5. With **Notify When Renewed** on, Harbor also posts a notification when it
   renewed something.

Harbor only replies to Shortcuts' own reply addresses, of the form
`shortcuts://x-callback-url/ic-success/<id>`, which just resume the shortcut
that is waiting. Any other address, such as `shortcuts://run-shortcut`, is
ignored: Harbor still renews but reports nowhere, so a web page cannot use it
to open an address or run a shortcut of its choosing. Nothing secret is ever
in the reply.

Only runs that come from a shortcut count toward the status shown in
Automatic Renewal. If none has come for two days, it says the automation
isn't running.

`harbor://renew` and `harbor://refresh` renew without reporting back; when
they fail, Harbor posts a notification.

## What iOS allows

- An app can hand over a shortcut but not an automation. The automation
  (Automation › + › Time of Day › Daily › Run Immediately) is created by the
  person, and the app walks them through it.
- Time of Day automations use the iPhone's own time zone.
- Opening Harbor needs the iPhone unlocked, so pick a time it usually is.
- Renewal needs LocalDevVPN connected. Adding **Set VPN** › **Connect** ›
  **LocalDevVPN** before the shortcut takes care of that.

## Publishing a one-tap shortcut

Shortcuts only installs in one tap from an iCloud link. Without one, Add to
Shortcuts copies the renewal link and opens a new shortcut, and the person
adds the action themselves. To give your build a one-tap shortcut:

1. In Shortcuts, make a shortcut named **Renew Harbor** with one action,
   **Open X-Callback URL**, set to `harbor://x-callback-url/renew`. Add
   nothing personal to it.
2. Share it › **Copy iCloud Link**. The link looks like
   `https://www.icloud.com/shortcuts/<ID>`; the ID is 32 hexadecimal
   characters.
3. Put the ID in `CodeSigning.xcconfig`:

       HARBOR_SHORTCUT_ID = 0123456789abcdef0123456789abcdef

4. Build. Add to Shortcuts now opens the link, and Shortcuts asks to add it.

The link is public and is tied to the iCloud account that shared it. Anyone
can read the shortcut before adding it.
