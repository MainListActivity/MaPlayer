use std::sync::Once;
use tracing::info;
use tracing_subscriber::EnvFilter;

static INIT_TRACING: Once = Once::new();

#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities required by flutter_rust_bridge.
    flutter_rust_bridge::setup_default_user_utils();

    INIT_TRACING.call_once(|| {
        let filter = EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new("info,hyper=warn,reqwest=warn"));

        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_target(true)
            .try_init();

        info!("rust proxy tracing initialized");
    });
}
