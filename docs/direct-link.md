# The direct link: install, state, and first run

This fork of [devxoul/nothering](https://github.com/devxoul/nothering) adds three things to it:

- **The direct link.** The Mac uses the iPhone's connection with no Personal Hotspot, no cable and
  no Wi-Fi network to join: in a car, say, where the iPhone has signal and nothing else does. Wi-Fi
  has to be switched on, on both, because the two talk over the Wi-Fi radio directly, the way
  AirDrop does.
- **The wake.** The Mac starts the iPhone's proxy over Bluetooth, so the iPhone stays in the pocket.
- **Car mode.** A Mac on no network tells its apps they are offline, and nothing even tries to
  connect. While the iPhone is linked, a small helper gives the Mac a network to believe in.

The [README](../README.md#direct-link-no-hotspot-no-cable) says how the link works.

## Install

Neither way needs a paid Apple developer account, and neither has to be redone every week.

| | iPhone app | Cable | What keeps it installed |
|---|---|---|---|
| **A. Cable** | Nothering from the App Store | yes | nothing to keep: it is an App Store app |
| **B. Direct** | this fork's build, through SideStore | no | SideStore signs it again by itself |

### A. With a cable

Everything is the original project's, as released. This fork only adds car mode.

1. **iPhone**: install [Nothering from the App Store](https://apps.apple.com/app/nothering/id6817766239).
2. **Mac**: download **Nothering** from the [original project's releases](https://github.com/devxoul/nothering/releases/latest),
   open it, and approve its extension when it asks.
3. **Mac**, once, for when the Mac has no network of its own. It asks for your password:

   ```sh
   curl -fsSL https://github.com/calebynhan/nothering/releases/latest/download/install-car-mode.sh | sh
   ```

4. Plug the iPhone in, open Nothering on it and tap **Start Proxy**, and switch Nothering on in the
   Mac's menu bar. **Turn on and off with iPhone proxy** in its panel does that last part by
   itself from then on.

Where the Mac has no network, car mode gives it a stand-in one while the iPhone's proxy answers,
with the system's proxy setting pointed at the app's link to the iPhone. Browsers and most apps
follow that setting, also if the app's extension doesn't start on a Mac that is offline.

### B. Without a cable

Apple lets an app that isn't from the App Store run for 7 days on a free Apple ID.
[SideStore](https://sidestore.io) is an app on the iPhone that signs such apps again before that,
by itself. Setting it up takes a cable and about ten minutes, once.

1. **SideStore**, following [its own guide](https://docs.sidestore.io/docs/installation/prerequisites),
   which is kept current. In short: install **LocalDevVPN** from the App Store on the iPhone and
   connect it, install **iloader** on the Mac, plug the iPhone in, sign in to iloader with your
   Apple ID and choose **Install SideStore**. On the iPhone, trust yourself under Settings > General >
   VPN & Device Management, turn on Settings > Privacy & Security > Developer Mode, then open
   SideStore and sign in.
2. **iPhone**: add this fork's releases to SideStore as a source, and install **Nothering Direct**
   from it. Typing this into Safari's address bar on the iPhone opens it in SideStore:

   ```
   sidestore://source?url=https://github.com/calebynhan/nothering/releases/latest/download/source.json
   ```

   Or add the address after `url=` by hand under SideStore's sources. SideStore then also offers
   each new release as an update.

3. **Mac**, once. It fetches the `nothering` tool, installs the car mode helper, which asks for
   your password, and leaves **Nothering Direct** on the Desktop:

   ```sh
   curl -fsSL https://github.com/calebynhan/nothering/releases/latest/download/install-mac.sh | sh
   ```

4. **Pair**, once. Open Nothering Direct on the iPhone and leave it open. Allow local network
   access and Bluetooth when it asks. On the Mac, double-click **Nothering Direct** on the Desktop.
   The Mac prints a number, the iPhone asks "Allow this Mac?" with the same number: tap **Allow**,
   then answer **y** on the Mac. macOS asks whether Terminal may use Bluetooth: allow it. A
   terminal app other than Apple's may also be asked about devices on the local network: allow
   that too.

After that it is one double-click on the Mac. The iPhone's app is started over Bluetooth, the Mac
connects, and the Mac's apps go through the iPhone until the window is closed.

What to know:

- SideStore signs the app again in the background while **LocalDevVPN is connected and the iPhone
  is on Wi-Fi**. Leave LocalDevVPN connected at home. If the app ever stops opening, open
  SideStore and tap the days counter next to it. No computer is needed for that.
- A free Apple ID runs three such apps at a time. SideStore is one, Nothering Direct the second.
- Nothering Direct sits next to the App Store's Nothering, if that is installed too. They are
  separate apps, and only one can run its proxy at a time.
- The tool points the Mac's apps at the iPhone with the system's proxy setting, which browsers and
  most apps follow. A few don't: some command-line tools, games, other VPNs. To send those through
  as well, also install the original Nothering Mac app (step 2 of A), switch it on once, allow its
  two questions, and quit it from its menu. Its extension keeps running and uses the tool's link.
  After a restart of the Mac, open that app, switch it on and quit it again.
- If the wake stops working after the iPhone restarted or the app was updated, open Nothering
  Direct once.

### C. No sideloading at all

The lasting answer is for the direct link to be part of the original app, which is on the App
Store. This fork is laid out so its changes can be offered there.

## What has and hasn't been run

Nothing here has run on an iPhone yet. What has been checked, and how far that goes:

| | Checked | How |
|---|---|---|
| Stream multiplexer, pairing code, pairing exchange, the wake's challenge and answer, the helper's install commands | tested | 60 tests on Linux. The cryptography ran with swift-crypto, which has CryptoKit's API |
| Car mode's helper, watcher and installers, and the Mac installer with its launcher | tested | 118 checks against stand-ins for `ifconfig`, `scutil`, `sudo` and the rest |
| Everything that uses Network, Security and CoreBluetooth | type-checked | against stand-ins for those frameworks on Linux, and read against Apple's real headers |
| The same, compiled and run on a Mac | run on GitHub's Mac | with Xcode 26.6 on macOS 26 the iPhone app, the tool and the Mac app compile and 139 tests pass. In them the two sides of the link find each other, pair, and connect over loopback, with the encryption that stays safe if the code gets out later. Every push repeats this, see the newest [build](../../../actions) |
| What macOS makes of the stand-in network | run on GitHub's Mac | taken off its network, the Mac says it is offline and apps don't try. With the stand-in it counts as online, apps try, and with the proxy setting a page loads through the forwarder, its name looked up on the far side. Every build repeats this, see the newest build's probe |
| The radio link between a Mac and an iPhone | **never** | needs the two devices |
| The wake over Bluetooth | **never** | needs the two devices |
| The proxy extension on the stand-in network | **never** | needs a Mac with the extension approved |

Each build's results are also kept on the `ci-logs-build` and `ci-logs-probe` branches, as text.

## First run, in this order

Stop at the first step that fails and note what it said. Start somewhere with Wi-Fi, so a failure
doesn't leave you without a way to look things up. `nothering` below is `~/.local/bin/nothering`.

1. iPhone: open the app. The proxy starts by itself. Allow local network access and Bluetooth when
   iOS asks. Under Connect from Mac there is a **Pairing code** row, with no warning under it.
2. Mac, Wi-Fi on:

   ```sh
   nothering --via direct
   ```

   The first time it pairs, as in step 4 of the install. It should then print
   `127.0.0.1:11080 -> iPhone via direct`, and the iPhone should say "Mac connected via direct
   Wi-Fi". If pairing fails, note what it printed and go on with the code typed instead: tap
   **Show** next to Pairing code on the iPhone and add `--code <the code>`.
3. Traffic goes out over cellular. The address this prints should be the iPhone's on cellular, not
   your Wi-Fi's:

   ```sh
   curl --socks5-hostname 127.0.0.1:11080 https://ifconfig.me
   ```

4. Speed, compared with a speed test on the iPhone itself:

   ```sh
   curl --socks5-hostname 127.0.0.1:11080 -o /dev/null "https://speed.cloudflare.com/__down?bytes=200000000"
   ```

5. Lock the iPhone and repeat step 3 after five minutes. Then walk the iPhone out of range and
   straight back, and repeat it again. Away for longer than about 45 seconds, the iPhone's proxy
   stops for want of a Mac: the command then says its keepalive failed until the proxy is started
   again, which the wake of step 8 does by itself.
6. Every app. Stop the command with Control-C and start it again with the system's proxy setting,
   which the Desktop launcher also uses:

   ```sh
   nothering --via direct --system-proxy
   ```

   Open a website in Safari. It should load, and the iPhone should show the traffic.
7. The car, at your desk. Leave the command running. Hold Option, click the Wi-Fi icon in the
   Mac's menu bar and choose Disconnect, which leaves the network with Wi-Fi still on. Within ten
   seconds the command should print that the Mac is given a stand-in network. Open a website in
   Safari again, and try one other app. This is the step the car depends on. To get back, pick
   your network in the Wi-Fi menu.
8. The wake. Stop the command, wait until the iPhone says Stopped, go to its Home Screen and lock
   it. Then double-click **Nothering Direct** on the Desktop, or:

   ```sh
   nothering --via direct --wake --system-proxy
   ```

   Without the iPhone being touched it should print that the iPhone is starting its proxy, and
   then connect as in step 2.
9. The wake after the iPhone sat locked for an hour, when iOS has usually ended the app.
10. Tap Stop on the iPhone while the Mac is connected. The Mac's command should end by itself and
    say that the proxy was stopped on the iPhone, and the iPhone should stay stopped.

In the car it is then the double-click of step 8, and nothing on the iPhone.

## Open questions only devices can answer

- With the stand-in network up, do apps try to connect, and do they follow the proxy setting it
  carries? On GitHub's Mac they did both. Yours may have something that one lacks: an older
  macOS, a VPN, a network that is only half gone. If step 7 fails, these show what the Mac
  believes:

  ```sh
  route -n get default
  ```

  ```sh
  scutil --dns | head -20
  ```

  ```sh
  scutil --proxy
  ```

  The helper goes by the network service this names, which should be `NOTHERING-OFFLINE`:

  ```sh
  echo "show State:/Network/Global/IPv4" | scutil
  ```

  ```sh
  sudo /Library/PrivilegedHelperTools/nothering-offline-network status
  ```

- Does the Mac find the iPhone while the iPhone's app is in the background, or only while it is on
  screen? An open connection is expected to survive either way.
- How fast and how steady is this link over minutes, compared with the hotspot?
- The wake has three parts, and each can fail on its own. Does the Mac find the iPhone's Bluetooth
  service while the app is in the background? Does iOS let the woken app start the proxy, whose
  silent audio is what keeps it running? And can the Mac then find the iPhone over Wi-Fi with the
  app never having been on screen? When the last one fails, the iPhone posts "Your Mac is
  waiting" 20 seconds after the Mac asked, if notifications are allowed (**Notify if closed** asks
  for that), and a tap on it finishes the job, also with **Start when opened** off.

Logs from both sides:

```sh
log stream --predicate 'subsystem == "app.nothering"'
```

## Known limits

- The pairing code is kept in the app's preferences on both sides, not in the keychain. **New
  Pairing Code** on the iPhone retires it, and every paired Mac then has to pair again.
- The link's encryption is keyed by the pairing code. The two sides first offer a way of
  encrypting that stays safe if the code gets out later, and fall back to one that doesn't where
  the system lacks the first. Each build's tests say which ones connect on its Mac: on macOS 26
  both do, so the first is the one used. What an iPhone takes isn't known yet. With the fallback,
  someone who records the radio traffic and later gets hold of the code can read what they
  recorded. Most of what crosses the link is HTTPS inside it and stays unreadable. Names looked up
  and plain HTTP don't.
- A Mac can only be paired while Nothering is open on the iPhone's screen, and once one Mac is
  paired, only after **Pair Another Mac** was tapped there.
- Someone in range can keep a Mac from pairing or from connecting for a while, by asking in its
  place again and again. They get nothing by it, and typing the code still works.
- When the iPhone's app is closed by iOS, the Mac notices by the connection dropping, about ten
  seconds later, not by an event.
- On the Mac a stream crosses one more local socket than a USB or hotspot connection does.
- The wake doesn't reach an app that was swiped away in the app switcher, and may not after the
  iPhone restarted until the app was opened once.
- While the Mac wants the iPhone and isn't connected, it scans for it over Bluetooth about every
  20 seconds. Once the iPhone has answered and still no link came of it, each wait is twice the
  one before, up to ten minutes, until the link is there again.
- "Your Mac is waiting" comes once for as long as the Mac keeps asking, not with every request.
  It comes again after the app was opened, after a Mac got through, or after no Mac asked for
  fifteen minutes. A Mac switched off and on again sooner than that doesn't ring the iPhone twice.
- The helper goes by the network the Mac says it is on. One that leads nowhere but has a router,
  like Wi-Fi with no internet behind it, counts as the Mac's own, and no stand-in comes up. With
  `--system-proxy` the Mac's apps go through the iPhone all the same.
- With `--system-proxy` and no extension, apps that ignore the system's proxy setting stay
  offline, and nothing on the Mac can look up a name by itself.

## Building it yourself

GitHub builds what the releases carry, see [`.github/workflows/direct.yml`](../.github/workflows/direct.yml)
and [`scripts/ci/run.sh`](../scripts/ci/run.sh), which runs the same way on a Mac with Xcode and
[Tuist](https://tuist.dev):

```sh
scripts/ci/run.sh
```

It leaves the iPhone app, unsigned, and the Mac tool in `out/release/`. The Mac menu bar app with
its extension needs a paid developer account to sign, as in the original project.

## Taking it out again

```sh
~/.local/bin/nothering --remove-helper
```

Then delete `~/.local/bin/nothering` and **Nothering Direct** from the Desktop. Car mode for the
original Mac app (A) is taken out with:

```sh
curl -fsSL https://github.com/calebynhan/nothering/releases/latest/download/install-car-mode.sh | sh -s -- --remove
```

If the Mac is ever left believing in the stand-in network, which the helper is built to prevent:

```sh
sudo /Library/PrivilegedHelperTools/nothering-offline-network down
```
