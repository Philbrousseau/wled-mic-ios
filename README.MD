# 🎶 Feed My WLED — iOS Sound Reactive Mic App

This project is an **iOS companion app** that turns your iPhone into a microphone source for **WLED SoundReactive**, sending **Audio Sync v2 UDP packets** directly to one or more WLED devices on your network.

It’s especially useful for **ESP8266 devices** 🕹️ — since those don’t have official sound-reactive support in the main WLED builds. With this app, your phone does the heavy lifting (FFT, AGC, noise gate) and streams to the ESP, letting you still enjoy sound-reactive effects on hardware that can’t handle onboard DSP.

---

## 🔗 Related Projects

- **WLED SoundReactive (WLED-mm fork):** [https://mm.kno.wled.ge/](https://mm.kno.wled.ge/)  
  This is the modified WLED build that understands Audio Sync packets. You can flash it directly to your ESP8266 or ESP32 devices using the [WLED Web Flasher](https://install.wled.me/).

---

## 🚲 Example Use Case

Perfect for portable setups like:
- A bike with WLED strips (ESP8266/ESP32)
- A hat or costume with LEDs
- A travel router + USB power bank

Run this app on your iPhone, and your lights pulse to the beat of your music 🎵 — no laptop required.

---

## 📱 iOS App Setup (Xcode)

1. **Clone / open project** in Xcode.
2. **Add permissions in Info.plist**:
   - `NSMicrophoneUsageDescription` → “Mic drives WLED sound-reactive effects.”
   - `NSLocalNetworkUsageDescription` → “Discover and send audio sync to WLED devices on the local network.”
   - `NSBonjourServices` (Array) → `_wled._tcp`, `_http._tcp`
   - `NSAppTransportSecurity > NSAllowsArbitraryLoadsInLocalNetworking` = YES
3. **Enable Background Audio**:  
   - Target → Signing & Capabilities → `+ Capability` → **Background Modes**  
   - Check **Audio, AirPlay, and Picture in Picture**
4. **Run on a real iPhone** (discovery doesn’t work in Simulator).
5. **Controls in the app**:
   - Modes: `Single` (direct IP), `Multicast` (239.0.0.1:11988), `Unicast` (fan-out to multiple devices)
   - **Discover**: uses Bonjour to find WLEDs (`_wled._tcp` / `_http._tcp`) — still experimental 🚧
   - **Add IP**: manually add devices if discovery doesn’t work on your network
   - **Noise Gate**: stops sending packets when silence is detected, so LEDs go completely dark
   - **Ping**: checks latency and alive status of devices
   - **Test Packet**: send a synthetic audio frame to verify your WLED reacts

---

## ⚙️ WLED Device Setup

1. Flash WLED-mm (SoundReactive build) using [the flasher](https://install.wled.me/).
2. In WLED:
   - **Settings → Usermods → Audio Reactive** → Enable
   - **Settings → Sync → Port = 11988, Mode = Receive**
   - For “relay” setups: check **Sync audio data with other WLEDs**
3. Choose a **sound-reactive effect** (e.g. Gravcenter, Gravfreq, Juggles).  
   - Effects like GEQ always draw, but with the noise gate enabled in the app, you’ll see true silence.

---

## ⚡ Current Status

- ✅ UDP v2 packet streaming (AGC, FFT, noise gate)
- ✅ Multicast & Unicast modes
- ✅ Bonjour discovery (under development — may not work on all routers yet)
- ✅ Manual IP entry + Ping
- ✅ Background audio (phone can stay locked)
- 🚧 Discovery stability still being improved

---

## 👤 Author

Made by [Alex Volkov](https://x.com/altryne) ([@altryne on X).

---

## 📜 License

MIT