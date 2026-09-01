{{flutter_js}}
{{flutter_build_config}}

// The debug session serves mutable mounted files through a relay, so a cached
// service worker adds a startup delay and can retain stale video configuration.
_flutter.loader.load({serviceWorkerSettings: null});
