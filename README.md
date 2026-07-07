# Dory Port Forwarder (Dory PF) ⚡

<p align="center">
  <img src="icon.png" width="128" height="128" alt="Dory PF Icon" />
</p>

**Dory Port Forwarder (Dory PF)** is a lightweight, native macOS menu bar application developed in Swift and SwiftUI. It simplifies port forwarding and redirection in macOS environments (highly useful for local development with **Dory**, Docker, or OrbStack) while maintaining **0% idle CPU usage**.

It leverages the native macOS packet filtering engine (**PF - Packet Filter**) using a single secure loopback redirection rule (`rdr pass`), avoiding complex configurations that alter your system's global security.

---

## ✨ Features

*   **⚡ Optimized Performance (Hybrid Model):** The app only performs checks and consumes resources when the menu bar window is open. Once closed, it halts entirely (0% idle CPU usage).
*   **🐳 Automatic Docker (Dory) Integration:** Automatically detects running containers via a direct low-level connection to `/Users/USER/.dory/dory.sock` and suggests port redirections in 1 click.
*   **⚠️ Smart Conflict Detection:** Alerts you instantly if the local entry port is already bound by another application, showing you the occupying process name (e.g., `httpd`, `Ollama`, `Dory`, etc.) in a detailed tooltip.
*   **🟢 Live Target Status:** Visual indicators show in real-time whether the target port (e.g., your Docker container) is active and listening for connections.
*   **📁 Profile Management:** Create, select, and organize your rule sets into different profiles (e.g., Development, Staging, Testing).
*   **🔒 Secure & Automated Installation:** On the first run, the app guides you to register the persistent macOS daemon (`launchd`) with a single secure administrator prompt.
*   **📦 100% Native & Dependency-Free:** Weighs under 1 MB, requiring no Node.js, Electron, or third-party libraries.

---

## 🛠️ Architecture & How It Works

Dory PF uses a decoupled and secure design:
1.  **The GUI (Swift/SwiftUI):** Reads and writes port forwarding rules to a plain text file in your user directory: `~/.dory/port-forwards.conf`.
2.  **The macOS Daemon (`launchd`):** A minimalist script (`dory-pf.sh`) installed in `/usr/local/libexec/` managed by a LaunchDaemon (`local.dory-pf.plist`). This daemon watches the config file for changes, triggers instantly to apply rules to the native `com.dory.rdr` anchor, and goes back to sleep.

---

## 📥 Installation

### Requirements
*   macOS 13.0 (Ventura) or newer.
*   Dory, Docker Desktop, or OrbStack installed and running.

### Option A: Using Pre-built Releases (ZIP)
1. Download **`DoryPortForwarder.zip`** from the latest GitHub Release and extract it.
2. Drag the extracted **`Dory Port Forwarder.app`** to your `/Applications` folder.
3. Open your terminal and run the following command to remove the macOS quarantine flag (Gatekeeper):
   ```bash
   xattr -r -d com.apple.quarantine /Applications/Dory\ Port\ Forwarder.app
   ```

### Option B: Build and Package from Source
To build your native `.app` bundle with its custom icon automatically, clone the repository and run the build script:

```bash
chmod +x build.sh
./build.sh
```

This generates **`DoryPortForwarder.app`** in the root directory. You can drag it to your `/Applications` folder and add it to your macOS login items if desired.

---

## 🚀 Usage

1.  **Initial Setup (Onboarding):** Upon the first launch, the app detects if the background service is missing and prompts you to **Install**. Clicking this will request admin privileges once to configure the secure PF ruleset.
2.  **Adding Rules:**
    *   **Manual:** Input the entry port (e.g., `80`) and the target port (e.g., `8081`) and click **Add**.
    *   **Docker suggestions:** If you have running containers with public port mappings, they will appear under **Suggested Forwards (Docker)**. Just click the `[+]` button to add them instantly.
3.  **Handling Conflicts:** If you see a red triangle `⚠️`, hover over it to identify which local application is occupying the entry port.
4.  **Profiles:** Use the dropdown menu at the top to switch between forwarding environments in seconds.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🤝 Contributing

Suggestions, bug reports, and pull requests are welcome! Feel free to open an issue or submit a PR if you want to extend socket paths or add integrations.
