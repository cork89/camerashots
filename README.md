# CameraShots

Point your phone at your monitor, press the shutter, and get a real screenshot of the area in view instead of a photo of a screen.

While the phone page is open, a Windows tray app shows small markers on your monitors. The phone uses them to work out where it is pointing, and the PC takes the actual screenshot. The markers are hidden from screenshots. The shot appears on your phone and, by default, on the PC clipboard.

The phone and PC talk through a Cloudflare Worker that you deploy to your own account. The phone needs no app.

## Requirements

- Windows 10 version 2004 or newer
- [Odin](https://odin-lang.org/docs/install/) and the Microsoft C++ Build Tools
- [Node.js](https://nodejs.org/) 22.12 or newer, with npm
- A Cloudflare account
- A phone with a camera and a modern browser

## Setup

Run these from the project folder in PowerShell.

1. Deploy the Worker and note the `https://...workers.dev` address it prints:

   ```powershell
   npm ci
   npx wrangler login
   npm run deploy
   ```

2. Build the app and give it that address:

   ```powershell
   .\build.bat
   .\camerashots.exe --relay https://camerashots.YOUR-NAME.workers.dev
   ```

   The address is saved, so next time just run `.\camerashots.exe`. A pairing page opens in your browser.

3. Allow your PC on the Worker. Run this and paste the hash from the pairing page:

   ```powershell
   npx wrangler secret put TOKEN_SHA256
   ```

4. Scan the QR code with your phone and allow camera access.

A Worker accepts one PC. You can pair several phones by scanning the same code.

## Use

Point the phone at a monitor. When the yellow border appears, press the shutter. The PC shows a notification for each capture.

Click the tray icon for:

- **Pair phone...** shows the QR code and token hash.
- **Reset pairing** creates a new token. Repeat setup steps 3 and 4 afterwards.
- **Copy shots to clipboard** turns clipboard copying on or off until you quit.
- **Quit** stops the app.

## Security

- **The QR code is a password.** Anyone with it can capture any part of your screen while the app is running. It does not expire. If it leaks, use **Reset pairing**.
- Each phone shares the same token, so you cannot revoke just one.
- The Worker rejects all tokens until `TOKEN_SHA256` is set, then accepts only the matching one.
- Connections use HTTPS, but screenshots are not end-to-end encrypted. Your Worker and Cloudflare can technically see them. The Worker code does not store them.
- Camera frames are processed on the phone and are not uploaded.
- The token is stored unencrypted in `%LOCALAPPDATA%\CameraShots`, in both `token` and `pair.html`.
- Capture notifications can be hidden by Do Not Disturb.

## Troubleshooting

| Message | Fix |
|---|---|
| Set the TOKEN_SHA256 secret on the Worker. | Do setup step 3. |
| Not paired. Scan the QR code from the PC tray menu. | Scan the current code. If that fails, repeat step 3 with the current hash. |
| CameraShots is not running on the PC. | Start the app, check its connection, and check that the Worker address is right. If you just changed the hash, wait a few seconds. |
| display layout changed, try again | Point at the monitor again. |
| Camera unavailable | Allow camera access for the site in your phone's browser. |

To change the Worker address, quit the app and run it again with `--relay`.

## Development

Run the Worker locally with `npm run dev`. Put the hash in `.dev.vars` (ignored by Git):

```
TOKEN_SHA256=your-hash
```

Then quit the app and run `.\camerashots.exe --relay http://127.0.0.1:8787`. This replaces the saved address. A phone cannot reach this local address, so use the deployed Worker to test with one.

- `src/`: Windows app (Odin)
- `worker/`: Cloudflare Worker and Durable Object relay
- `web/`: phone page, plus the pairing page embedded in the exe

`web/aruco.js`, `web/cv.js` and `web/qrcode.js` are third-party code. See their headers for licenses.
