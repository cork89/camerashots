# CameraShots

Point your phone at your monitor, take the picture, and get a screenshot of the area in view instead of a photo of a screen.

While the phone page is open, a Windows tray app shows small markers on your monitors. The phone uses them to work out where it is pointing, and the PC takes the actual screenshot. The markers are hidden from screenshots. The shot appears on your phone and, by default, on the PC clipboard.

The app runs a small web server on your PC. I use [Tailscale Serve](https://tailscale.com/kb/1312/serve) to give it an HTTPS address that only devices on a Tailscale network can reach. The phone needs Tailscale as well.

## Requirements

- Windows 10 version 2004 or newer
- [Odin](https://odin-lang.org/docs/install/) and the Microsoft C++ Build Tools
- [Tailscale](https://tailscale.com/download) on the PC and phone, signed in to the same network
- A phone with a camera and a modern browser

## Setup

1. Start Tailscale Serve:

   ```powershell
   tailscale serve --bg 47810
   tailscale serve status
   ```

   If asked, follow the link to turn on HTTPS. Note the `https://...ts.net` address.

2. Build the app and give it that address, without a path:

   ```powershell
   .\build.bat
   .\camerashots.exe --url https://YOUR-PC.YOUR-TAILNET.ts.net
   ```

   The address is saved, so next time just run `.\camerashots.exe`. A pairing page opens in your browser.

3. Connect Tailscale on your phone, scan the QR code and allow camera access.

You can pair several phones by scanning the same code.

### Add to the Home Screen

- **iPhone:** open the page in Safari, tap **Share**, then **Add to Home Screen**.
- **Android:** in Chrome, open the menu and choose **Add to Home screen** or **Install app**.

## Use

Point the phone at a monitor. When the yellow border appears, take the pic. The PC shows a notification for each capture.

Click the tray icon for:

- **Pair phone...** shows the QR code.
- **Reset pairing** creates a new token, which unpairs all phones. Scan the new code.
- **Copy shots to clipboard** turns clipboard copying on or off until you quit.
- **Quit** stops the app.

## Security

- **The QR code is a password.** Anyone with it who can reach your PC over Tailscale can capture any part of your screen while the app is running. It does not expire. If it leaks, use **Reset pairing**.
- Each phone shares the same token, so you cannot revoke just one.
- Camera frames are processed on the phone and are not uploaded.
- The token is stored unencrypted in `%LOCALAPPDATA%\CameraShots`, in both `token` and `pair.html`.
- Capture notifications can be hidden by Do Not Disturb.

## Troubleshooting

| Message | Fix |
|---|---|
| Not paired. Scan the QR code from the PC tray menu. | Scan the current code. |
| CameraShots is not running on the PC. | Start the app, then check that `tailscale serve status` points to port 47810. |
| Cannot reach the PC. | Check that Tailscale is connected on both devices and the PC is awake. |
| Could not listen on 127.0.0.1:47810 | Another program is using the port. |
| display layout changed, try again | Point at the monitor again. |
| Camera unavailable | Allow camera access for the site in your phone's browser. |

To change the address, quit the app and run it again with `--url`.

To stop sharing the app, run `tailscale serve --https=443 off`.

## Development

Files in `web/` are embedded when you build, so rebuild and restart after changing them.

To test in a browser on the PC, quit the app and run `.\camerashots.exe --url http://127.0.0.1:47810`. This replaces the saved address.

To use another port, add `-define:PORT=12345` to the command in `build.bat` and give Tailscale Serve the same port.

- `src/`: Windows app and web server
- `web/`: phone page and pairing page

`web/aruco.js`, `web/cv.js` and `web/qrcode.js` are third-party code. See their headers for licenses.
