import UIKit
import Capacitor

/**
 Registers Vibe's own Swift plugins with the Capacitor bridge.

 Capacitor 8 only activates plugins listed in `packageClassList` inside the
 generated `capacitor.config.json` — and that list is rebuilt from the installed
 npm plugin packages on every `cap sync`. Plugins that live in the app target
 (like ours) never appear there, so they compile into the binary but are never
 reachable from JavaScript: `Capacitor.Plugins.PhotoLibrary` comes back
 undefined and the web layer silently falls back to browser behaviour.

 `capacitorDidLoad()` is the supported hook for registering app-target plugins,
 and it survives `cap sync` because it is our code, not a generated file.
 */
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(PhotoLibraryPlugin())
        bridge?.registerPluginInstance(YoutubeConnectPlugin())
    }
}
