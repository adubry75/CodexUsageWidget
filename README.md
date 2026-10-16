# Codex Usage Widget

Double-click **Start Codex Usage Widget.lnk** (the Windows shortcut). This launch path was tested end to end. The shortcut points to this folder, so recreate it if you move the files. The VBS launcher is also corrected, but Windows Script Host testing was denied in the development environment.

The percentage is **used**, matching the supplied Claude widget. Red means 85% or more used. The five-hour and weekly figures are shared account usage, not this chat's usage.

- Drag the widget to move it between monitors.
- Double-click it to refresh immediately.
- Original reference styling: diagonal background gradient, glossy highlight, soft drop shadow, rounded gradient bars with colored glow, and animated fills.
- Right-click for six skins (Clay, Midnight, Synthwave, Nord, Terminal, Paper), compact mode, always-on-top, poll interval, opacity, corner snapping, optional Windows startup, log, tray, and exit controls.
- Double-click the tray icon to show or hide the widget.
- Usage refreshes every 60 seconds; reset countdowns update each second.
- Windows startup is optional and remains off until you enable it from the menu.

Requires the installed Node.js and Codex CLI, signed into the same ChatGPT account as the desktop app. It uses the documented `account/rateLimits/read` app-server method. It starts no model turn and sends no prompts. It does not read, copy, or log credentials. Existing Claude widget files are untouched.

If the CLI is installed elsewhere, set `CODEX_WIDGET_CODEX_EXE` to the full path of `codex.exe` before launching. For sign-in problems, run `codex login` in a terminal.

Documentation: https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt

`preview.png` was captured from the running WPF widget during an end-to-end shortcut and live account-query test. `verification.json` records the live UI effects, skins, menu, and query result. Settings and logs are saved beside the script.
